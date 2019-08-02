<#
  .SYNOPSIS
    Powers on or resets any unregistered machine in Citrix XenApp (as long as the machine is power-managed)
  .DESCRIPTION
    This script was designed for environments using read-only virtual machines that will revert to their Gold Standard image when reset.
    This can be Citrix Provisioning Services with Standard-Mode vDisks, or an equivalent solution.
    The script will:
        Get all Broker Machines from a specified Delivery Controller
        Check their power state and registration status
        If they are Off, Power them on
        If they are Unregistered, Reset them
  .OUTPUTS
    No output is returned to the pipeline.
    If run interactively, the actions taken on VMs will be written to the host UI.
  .EXAMPLE
    .\WatchDogTask.ps1 -DeliveryController 'server123'
  .NOTES
    Tested running on Windows 10 connecting to XenApp 7.6
    Prerequisites:
      PowerShell PSSnap-Ins for Citrix XenApp 7.6 (easily installed by installing Citrix Studio)
      Must be able to connect to the Delivery Controller
      User running the script must have rights to reset/power on VMs via XenApp
#>

param(

    # Hostname of the Citrix XenApp/XenDesktop Delivery Controller
    [Parameter(Mandatory=$True)]
    [String]$DeliveryController,

    [int]$DeliveryControllerPort = 80,

    # Machine Names to exclude from the watchdog script
    [String[]]$ExcludeMachineName, # = @('contoso\computer01','contoso\computer02'),
   
    #SMTP server to use to send the notification e-mails
    [String]$SmtpServer,
    
    #SMTP address to use as the Sender of the notification e-mails. 
    [String]$SmtpSender,

    #SMTP addresses to send the notification e-mails to
    [String[]]$SmtpRecipient

)
begin{

    Add-PSSnapIn Citrix.Broker.Admin.V2

    $CitrixAdminAddress = "$DeliveryController`:$DeliveryControllerPort"

    $BrokerMachines = Get-BrokerMachine -AdminAddress $CitrixAdminAddress |
        Where-Object -FilterScript {
            ($_.DeliveryType -eq 'AppsOnly') -and
            ($ExcludeMachineName -notcontains $_.MachineName)
        }
    Write-Verbose "$($BrokerMachines.Count) total Broker Machines found in XenApp"

    $ActionsTaken = [System.Collections.Generic.List[Citrix.Broker.Admin.SDK.HostingPowerAction]]::new()
    $MaintModeMachines = [System.Collections.Generic.List[PSObject]]::new()

}
process{

    ForEach ($BrokerMachine in $BrokerMachines){

        if ($BrokerMachine.InMaintenanceMode -eq $true) {

            Write-Host "$($BrokerMachine.MachineName) is in Maintenance Mode. Disabling Maintenance Mode.."

            Set-BrokerMachineMaintenanceMode -InputObject $BrokerMachine -MaintenanceMode $false -AdminAddress $CitrixAdminAddress
            
            $Props = @{
                MachineName = $BrokerMachine.MachineName
                Action = "Disable maintenance mode"
            }
            $null = $MaintModeMachines.Add((New-Object -TypeName PSObject -Property $Props))
        }

                    
        if ($BrokerMachine.PowerState -eq 'Off') {

            Write-Host "$($BrokerMachine.MachineName) is powered off. Powering on."

            $Action = New-BrokerHostingPowerAction -Action TurnOn -MachineName $BrokerMachine.MachineName -AdminAddress $CitrixAdminAddress
            $null = $ActionsTaken.Add($Action)
                
        }
        else{

            Write-Debug "$($BrokerMachine.MachineName) is not powered off. Proceeding."

            if ($BrokerMachine.RegistrationState -ne 'Registered'){

                Write-Host "$($BrokerMachine.MachineName) is not successfully registered with the Delivery Controller.  Resetting the VM."

                $Action = New-BrokerHostingPowerAction -Action Reset -MachineName $BrokerMachine.MachineName -AdminAddress $CitrixAdminAddress
                $null = $ActionsTaken.Add($Action)

            }
            else{

                Write-Verbose "$($BrokerMachine.MachineName) is successfully registered with the Delivery Controller.  Skipping."

            }
        }

    }

}
end{

    if ($ActionsTaken.Count -gt 0){

        Import-Module "$PSScriptRoot\Modules\BootstrapReport\BootstrapReport.psm1"
        $Table = $ActionsTaken | 
            Select MachineName,Action | 
                ConvertTo-Html -Fragment |
                    New-BootstrapTable |
                        New-BootstrapColumn -Width 6
        $Table2 = $MaintModeMachines | 
            Select MachineName,Action | 
                ConvertTo-Html -Fragment |
                    New-BootstrapTable |
                        New-BootstrapColumn -Width 6
        $Body = (New-HtmlHeading "Actions Taken") + $Table + $Table2
        $Title = "Citrix XenApp Watchdog Script"
        $Report = New-BootstrapReport -Title $Title -Description "Powers on or resets Citrix machines as needed." -Body $Body
        $Report | Out-File "$PSScriptRoot\Reports\$((Get-Date -Format s) -replace ':','-').html"
        Send-MailMessage -SmtpServer $SmtpServer -To $SmtpRecipient -From $SmtpSender -Subject $Title -Body $Report -BodyAsHtml
        Remove-Module BootstrapReport

    }

}