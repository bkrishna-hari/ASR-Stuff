<#
.DESCRIPTION
    This runbook uninstalls the Custom Script Extension from the Azure VMs (brought up after a failover)
    This is required so that after a failover -> failback -> failover, the Custom Script Extension can trigger the iSCSI script
     
.ASSETS (The following need to be stored as Automation Assets) 
    [You can choose to encrypt these assets]
    
    The following have to be added with the Recovery Plan Name as a prefix, eg - TestPlan-StorSimRegKey [where TestPlan is the name of the recovery plan]
    [All these are String variables]
    
    'RecoveryPlanName'-AzureSubscriptionName: The name of the Azure Subscription
    'RecoveryPlanName'-VMGUIDS: 
        	Upon protecting a VM, ASR assigns every VM a unique ID which gives the details of the failed over VM. 
        	Copy it from the Protected Item -> Protection Groups -> Machines -> Properties in the Recovery Services tab.
        	In case of multiple VMs then add them as a comma separated string
#>

workflow Uninstall-Custom-Script-Extension
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
    
    $VMGUIDString = Get-AutomationVariable -Name "$PlanName-VMGUIDS" 
    if ($VMGUIDString -eq $null) 
    { 
        throw "The VMGUIDs asset has not been created in the Automation service."  
    }
    $VMGUIDs =  $VMGUIDString.Split(",").Trim()

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

    foreach  ($VMGUID in $VMGUIDs)
    { 
        #Fetch VM Details 
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
         
        InLineScript 
        {
            $VMRoleName = $Using:VMRoleName
            $VMServiceName = $Using:VMServiceName            
            
            $AzureVM = Get-AzureRmVM -Name $VMRoleName -ResourceGroupName $VMServiceName              
            if ($AzureVM -eq $null)
            {
                throw "Unable to fetch details of Azure VM - $VMRoleName"
            }
            
            Write-Output "Uninstalling custom script extension on $VMRoleName" 
            try
            {
                $result = Remove-AzureRmVMCustomScriptExtension -ResourceGroupName $VMServiceName -VMName $VMRoleName -Name "CustomScriptExtension" -Force
            }  
              
            catch
            {
                throw "Unable to uninstall custom script extension - $VMRoleName"
            }                          
        } 
    }
}
