<#
.DESCRIPTION 
    This runbook creates a script and stores it in a storage account. This script  will connect the iSCSI target and mount the volumes on the VM after a failover. 
    It then uses the Custom VM Script Extension to run the script on the VM.

.DEPENDENCIES
    Azure VM agent should be installed in the VM before this script is executed 
    If it is not already installed, install it inside the VM from http://aka.ms/vmagentwin

.ASSETS 
    [You can choose to encrypt these assets ]

    The following have to be added with the Recovery Plan Name as a prefix, eg - TestPlan-StorSimRegKey [where TestPlan is the name of the recovery plan]
    [All these are String variables]
    
    'RecoveryPlanName'-AzureSubscriptionName: The name of the Azure Subscription
    'RecoveryPlanName'-StorSimRegKey: The registration key for the StorSimple manager    
    'RecoveryPlanName'-ResourceName: The name of the StorSimple resource
    'RecoveryPlanName'-DeviceName: The device which has to be failed over
    'RecoveryPlanName'-TargetDeviceName: The device on which the Volume Containers are to be failed over
    'RecoveryPlanName'-TargetDeviceDnsName: The DNS name of the TargetDevice (can be found out from the Virtual MachineÃ¢â‚¬â„¢s section) 
    'RecoveryPlanName'-StorageAccountName: The storage account name in which the script will be stored
    'RecoveryPlanName'-StorageAccountKey: The access key for the storage account
    'RecoveryPlanName'-ScriptContainer: The name of the Storage Container in which the script will be stored 
    'RecoveryPlanName'-AutomationAccountName: The name of the Automation Account in which the various runbooks are stored 
    'RecoveryPlanName'-VMGUIDS: 
        Upon protecting a VM, ASR assigns every VM a unique ID which gives the details of the failed over VM. 
        Copy it from the Protected Item -> Protection Groups -> Machines -> Properties in the Recovery Services tab.
        In case of multiple VMs then add them as a comma separated string
#>

workflow Mount-Volumes-After-Failover
{  
    Param 
    ( 
        [parameter(Mandatory=$true)] 
        [Object]
        $RecoveryPlanContext
    )
     
    $PlanName = $RecoveryPlanContext.RecoveryPlanName
    $ScriptName = "iscsi-VMName.ps1"
    $SLEEPTIMEOUT = 10    # Value in seconds
    $EndpointName = "Remote Desktop"
    $EndpointProtocol = "TCP"
    $EndpointLocalPort = 3389
    $EndpointPublicPort = 3389
    
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
     
    $DeviceName = Get-AutomationVariable -Name "$PlanName-DeviceName"
    if ($DeviceName -eq $null) 
    { 
        throw "The DeviceName asset has not been created in the Automation service."  
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
    
    $StorageAccountName = Get-AutomationVariable -Name "$PlanName-StorageAccountName" 
    if ($StorageAccountName -eq $null) 
    { 
        throw "The StorageAccountName asset has not been created in the Automation service."  
    }
    # Convert to lowercase
    $StorageAccountName = $StorageAccountName.ToLower()

    $StorageAccountKey = Get-AutomationVariable -Name "$PlanName-StorageAccountKey" 
    if ($StorageAccountKey -eq $null) 
    { 
        throw "The StorageAccountKey asset has not been created in the Automation service."  
    }
   
    $VMGUIDString = Get-AutomationVariable -Name "$PlanName-VMGUIDS" 
    if ($VMGUIDString -eq $null) 
    { 
        throw "The VMGUIDS asset has not been created in the Automation service."  
    }
    $VMGUIDS =  @($VMGUIDString.Split(",").Trim())

    $ScriptContainer = Get-AutomationVariable -Name "$PlanName-ScriptContainer"
    if ($ScriptContainer -eq $null) 
    { 
        throw "The ScriptContainer asset has not been created in the Automation service."  
    }  
    
    $AutomationAccountName = Get-AutomationVariable -Name "$PlanName-AutomationAccountName"
    if ($AutomationAccountName -eq $null) 
    { 
        throw "The AutomationAccountName asset has not been created in the Automation service."  
    }

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

    # Connect to the StorSimple Resource
    Write-Output "Connecting to StorSimple Resource $ResourceName"
    $StorSimpleResource = Select-AzureStorSimpleResource -ResourceName $ResourceName -RegistrationKey $RegistrationKey
    if ($StorSimpleResource -eq $null)
    {
        throw "Unable to connect to the StorSimple resource $ResourceName"
    }

    $TargetDevice = Get-AzureStorSimpleDevice -DeviceName $TargetDeviceName
    if (($TargetDevice -eq $null) -or ($TargetDevice.Status -ne "Online"))
    {
        throw "Target device $TargetDeviceName does not exist or is not online"
    }

    $TargetVM = Get-AzureVM -Name $TargetDeviceName -ServiceName $TargetDeviceServiceName 
    if ($TargetVM -eq $null)
    {
        throw "TargetDeviceName or TargetDeviceServiceName asset is incorrect"
    }

    $IPAddress = ($TargetVM).IpAddress
    if ($IPAddress -eq $null)
    {
        throw "IP Address of $TargetDeviceName is null"
    }

    $FailoverType = $RecoveryPlanContext.FailoverType
    foreach ($VMGUID in $VMGUIDS)
    {
        # Fetch VM Details
        $VMContext = $RecoveryPlanContext.VmMap.$VMGUID
        if ($VMContext -eq $null)
        {
            throw "The VM corresponding to the VMGUID - $VMGUID is not included in the Recovery Plan"
        }
        
        $VMRoleName =  $VMContext.RoleName 
        if ($VMRoleName -eq $null)
        {
            throw "Role name is null for VMGUID - $VMGUID"
        }
        
        $VMServiceName = $VMContext.ResourceGroupName
        if ($VMServiceName -eq $null)
        {
            throw "Service name is null for VMGUID - $VMGUID"
        }
        
        Write-Output "`nVM Name: $VMRoleName"   
        InlineScript 
        {
            $ScriptContainer = $Using:ScriptContainer
            $ScriptName = $Using:ScriptName 
            $RecoveryPlanContext= $Using:RecoveryPlanContext
            $VMRoleName = $Using:VMRoleName
            $VMServiceName = $Using:VMServiceName
            $IPAddress = $Using:IPAddress
            $TargetDeviceName = $Using:TargetDeviceName 
            $DeviceName = $Using:DeviceName 
            $StorageAccountName = $Using:StorageAccountName
            $StorageAccountKey = $Using:StorageAccountKey
            $EndpointName = $Using:EndpointName 
            $EndpointProtocol = $Using:EndpointProtocol
            $EndpointLocalPort = $Using:EndpointLocalPort
            $EndpointPublicPort = $Using:EndpointPublicPort
            $FailoverType = $Using:FailoverType
            $SLEEPTIMEOUT = $Using:SLEEPTIMEOUT

            # Replace actual Virtual machine name
            $ScriptName = $ScriptName -Replace "VMName", $VMRoleName

            $TargetDeviceIQN = (Get-AzureStorSimpleDevice -DeviceName $TargetDeviceName).TargetIQN
            if ($TargetDeviceIQN -eq $null)
            {
                 throw "IQN for $TargetDeviceName is null"
            }

            $DeviceIQN = (Get-AzureStorSimpleDevice -DeviceName $DeviceName).TargetIQN
            if ($DeviceIQN -eq $null)
            {
                 throw "IQN for $DeviceName is null"
            }      
       
            $Context = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
            if ($Context -eq $null)
            {
                throw "Invalid StorageAccountName or StorageAccountKey"
            }
       
            # Check if the Container already exists; if not, create it
            $Container =  Get-AzureStorageContainer -Name $ScriptContainer -Context $Context -ErrorAction:SilentlyContinue
            if ($Container -eq $null)
            {
                 Write-Output "Creating container $ScriptContainer"
                try
                {
                     $Container = New-AzureStorageContainer -Name $ScriptContainer -Context $Context
                }
                catch
                {
                    throw "Unable to create container $ScriptContainer"
                }
            }

            $text = "
            If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] `"Administrator`"))
             {   
             `$arguments = `"& '`" + `$myinvocation.mycommand.definition + `"' `"  
             Start-Process `"`$psHome\powershell.exe`" -Verb runAs -ArgumentList '-noexit',`$arguments
             break
             }
             Disconnect-IscsiTarget -NodeAddress $DeviceIQN -Confirm:`$false
             `$portal = Get-IscsiTargetPortal -TargetPortalAddress $IPAddress
             if (`$portal -eq `$null)
             {
                 New-IscsiTargetPortal -TargetPortalAddress $IPAddress
             }
             Connect-IscsiTarget -NodeAddress $TargetDeviceIQN -IsPersistent `$true
             Update-StorageProviderCache
             Update-HostStorageCache 
             Get-Disk  | Where-Object {`$_.Model -match 'STORSIMPLE*'}  | Set-Disk -IsOffline `$false
             Get-Disk  | Where-Object {`$_.Model -match 'STORSIMPLE*'}  | Set-Disk -IsReadOnly `$false"     
        
            $ScriptFileName = ('C:\iscsi-' + $VMRoleName + '.ps1')
            $text | Set-Content $ScriptFileName
        
            Write-Output "Writing file $ScriptName to $ScriptContainer"
            $uri = Set-AzureStorageBlobContent -Blob $ScriptName -Container $ScriptContainer -File $ScriptFileName -Context $Context -Force
            if ($uri -eq $null)
            {
                throw "Unable to write file $ScriptName to container $ScriptContainer"
            }

            # Create a URI for the file in the container 
            $sasuri = New-AzureStorageBlobSASToken -Container $ScriptContainer -Blob $ScriptName -Permission r -FullUri -Context $Context 
            if ($sasuri -eq $null)
            {
                throw "Unable to fetch URI for the file $ScriptName"
            }
        
            $AzureVM = Get-AzureRmVM -Name $VMRoleName -ResourceGroupName $VMServiceName        
            if ($AzureVM -eq $null)
            {
                throw "Unable to connect to Azure VM $VMRoleName"
            }
                                    
            Write-Output "Running script on the VM on $VMRoleName"
            try
            {
                 $result = Set-AzureRmVMCustomScriptExtension -ResourceGroupName $VMServiceName -VMName $VMRoleName -Location $AzureVM.Location -Name "CustomScriptExtension" -TypeHandlerVersion "1.1" -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey -FileName $ScriptName -ContainerName $ScriptContainer
            }
            catch
            {
                 throw "Unable to run the script on the VM - $VMRoleName"
            }    

            while ($true)
            {
                $AzureVM = Get-AzureRmVM -ResourceGroupName $VMServiceName -Name $VMRoleName
                if ($AzureVM -eq $null)
                {
                    throw "Unable to connect to Azure VM"
                }

                #Check if the status is finished execution
                $extension = $AzureVM.Extensions | Where-Object {$_.VirtualMachineExtensionType -eq "CustomScriptExtension"}
                if ($AzureVM.Extensions -eq $null -or $AzureVM.Extensions.Count -eq 0 -or $extension -eq $null)
                {
                    continue
                }
                elseif ($extension.ProvisioningState -eq 'Succeeded')
                {
                    break
                }
	 		   
                Start-Sleep -s $SLEEPTIMEOUT
            }
            Write-Output "Completed running script on VM - $VMRoleName"
        }
		
        $EndpointPublicPort++		
    }
}