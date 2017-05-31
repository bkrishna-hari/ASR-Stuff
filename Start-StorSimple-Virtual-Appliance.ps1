<#
.DESCRIPTION
    This runbook starts the StorSimple Virtual Appliance (SVA) in case it is in a shut down state
     
.ASSETS 
    [You can choose to encrypt these assets ]
    
    AzureCredential [Windows PS Credential]:
        A credential containing an Org Id username / password with access to this Azure subscription
        Multi Factor Authentication must be disabled for this credential

    The following have to be added with the Recovery Plan Name as a prefix, eg - TestPlan-StorSimRegKey [where TestPlan is the name of the recovery plan]
    [All these are String variables]

    'RecoveryPlanName'-AzureSubscriptionName: The name of the Azure Subscription
    'RecoveryPlanName'-StorSimRegKey: The registration key for the StorSimple manager    
    'RecoveryPlanName'-ResourceName: The name of the StorSimple resource
    'RecoveryPlanName'-TargetDeviceName: The Device on which the containers are to be failed over (the one which needs to be switched on)
    
.NOTES
    If the SVA is online, then this script will be skipped
#>
workflow Start-StorSimple-Virtual-Appliance
{
    Param 
    ( 
        [parameter(Mandatory=$true)] 
        [Object]
        $RecoveryPlanContext
    )
    
    $PlanName = $RecoveryPlanContext.RecoveryPlanName
    
    $SubscriptionName = Get-AutomationVariable -Name "$PlanName-AzureSubscriptionName"
    if ($SubscriptionName -eq $null) 
    { 
        throw "The AzureSubscriptionName asset has not been created in the Automation service."  
    }
        
    $RegistrationKey = Get-AutomationVariable -Name "$PlanName-StorSimRegKey"
    if ($RegistrationKey -eq $null) 
    { 
        throw "The StorSimRegKey asset has not been created in the Automation service."  
    }
    
    $ResourceName = Get-AutomationVariable -Name "$PlanName-ResourceName" 
    if ($ResourceName -eq $null) 
    { 
        throw "The ResourceName asset has not been created in the Automation service."  
    }
     
    $TargetDeviceName = Get-AutomationVariable -Name "$PlanName-TargetDeviceName"
    if ($TargetDeviceName -eq $null) 
    { 
        throw "The TargetDeviceName asset has not been created in the Automation service."  
    }
    
    $TargetDeviceDnsName = Get-AutomationVariable -Name "$PlanName-TargetDeviceDnsName"      
    if ($TargetDeviceDnsName -eq $null) 
    { 
        throw "The TargetDeviceDnsName asset has not been created in the Automation service."  
    }
    $TargetDeviceServiceName = $TargetDeviceDnsName.Replace(".cloudapp.net","")
    
    $SLEEPTIMEOUT = 10 #Value in seconds

    Write-Output "Connecting to Azure"
    try
    {
        $connectionName = "AzureRunAsConnection"
        $ConnectionAssetName = "AzureClassicRunAsConnection"
        $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName
        if ($servicePrincipalConnection -eq $null) 
        { 
            throw "The AzureRunAsConnection asset has not been created in the Automation service."  
        }
        $AzureRmAccount = Add-AzureRmAccount `
                            -ServicePrincipal `
                            -TenantId $servicePrincipalConnection.TenantId `
                            -ApplicationId $servicePrincipalConnection.ApplicationId `
                            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
        $AzureRmSubscription = Select-AzureRmSubscription -SubscriptionName $SubscriptionName


        # Get the connection
        $connection = Get-AutomationConnection -Name $connectionAssetName        

        # Authenticate to Azure with certificate
        $Conn = Get-AutomationConnection -Name $ConnectionAssetName
        if ($Conn -eq $null)
        {
            throw "Could not retrieve connection asset: $ConnectionAssetName. Assure that this asset exists in the Automation account."
        }

        $CertificateAssetName = $Conn.CertificateAssetName
        $AzureCert = Get-AutomationCertificate -Name $CertificateAssetName
        if ($AzureCert -eq $null)
        {
            throw "Could not retrieve certificate asset: $CertificateAssetName. Assure that this asset exists in the Automation account."
        }

        $AzureAccount = Set-AzureSubscription -SubscriptionName $Conn.SubscriptionName -SubscriptionId $Conn.SubscriptionID -Certificate $AzureCert 
        $AzureSubscription = Select-AzureSubscription -SubscriptionId $Conn.SubscriptionID
        
        if ($AzureRmAccount -eq $null -or $AzureRmSubscription -eq $null -or $AzureAccount -eq $null -or $AzureSubscription -eq $null)
        {
            throw "Unable to connect to Azure"
        }
    }
    catch {
        if (!$servicePrincipalConnection)
        {
            $ErrorMessage = "Connection $connectionName not found."
            throw $ErrorMessage
        } else{
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
    }
    
    #Connect to the StorSimple Resource
    Write-Output "Connecting to StorSimple Resource $ResourceName"
    $StorSimpleResource = Select-AzureStorSimpleResource -ResourceName $ResourceName -RegistrationKey $RegistrationKey
    if ($StorSimpleResource -eq $null)
    {
        throw "Unable to connect to the StorSimple resource $ResourceName"
    }    
    
    $TargetDevice = Get-AzureStorSimpleDevice -DeviceName $TargetDeviceName
    if ($TargetDevice -eq $null) 
    {
        throw "Target device $TargetDeviceName does not exist"
    }

    #Turning the SVA on
    InlineScript
    {
        $TargetDevice = $Using:TargetDevice
        $TargetDeviceName = $Using:TargetDeviceName
        $TargetDeviceServiceName = $Using:TargetDeviceServiceName
        $SLEEPTIMEOUT = $Using:SLEEPTIMEOUT
    
        if ($TargetDevice.Status -ne "Online")
        {
            Write-Output "Starting the SVA VM"
            $RetryCount = 0
            while ($RetryCount -lt 2)
            {
                $Result = Start-AzureVM -Name $TargetDeviceName -ServiceName $TargetDeviceServiceName 
                if ($Result.OperationStatus -eq "Succeeded")
                {
                    Write-Output "SVA VM succcessfully turned on"   
                    break
                }
                else
                {
                    if ($RetryCount -eq 0)
                    {
                        Write-Output "Retrying turn on of the SVA VM"
                    }
                    else
                    {
                        throw "Unable to start the SVA VM"
                    }
                                
                    # Sleep for 10 seconds before trying again                 
                    Start-Sleep -s $SLEEPTIMEOUT
                    $RetryCount += 1   
                }
            }
            
            $TotalTimeoutPeriod=0
            while($true)
            {
                Start-Sleep -s $SLEEPTIMEOUT
                $SVA =  Get-AzureStorSimpleDevice -DeviceName $TargetDeviceName
                if($SVA.Status -eq "Online")
                {
                    Write-Output "SVA status is online now"
                    break
                }
                $TotalTimeoutPeriod += $SLEEPTIMEOUT
                if ($TotalTimeoutPeriod -gt 540) #9 minutes
                {
                    throw "Unable to bring SVA online"
                }
            }
        }
        else 
        {
            Write-Output "SVA is online"
        }
    }
}