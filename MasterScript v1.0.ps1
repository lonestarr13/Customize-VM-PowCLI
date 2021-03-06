################
# Script to Rename workstation, set IP/Gateway Address and join to domain.
# Ping the IPs in the text file until one does not respond - Variable that one. (not sure if this will work)
# Save to variable that IP and it's associated workstation name.
# Set the IP and hostname.
# add the script to RunOnce registry key and restart computer (I'm pretty sure we can't join to domain until machine restarts)
# at the next login automatically join workstation to the domain.

Import-Module -Name VMware.VimAutomation.Core

# Fully Qualified Domain Name
$domain = "FQD NAME"
# OU you want to join the VMs to
$ou="OU=Workstations,OU=CHANGE,DC=ME"
# CSV list of machines formated as comma separated: WORKSTATION_NAME,IP_ADDRESS
$workstations = Import-Csv "$PSScriptRoot\DR-Machine-IP.txt"

# Below is the corporate network and VCenter ip info
$subnet = "255.255.255.0"
$gateway = "192.168.50.1"
$DNS_Server="192.168.50.0"
$vCenter = "VCenterServer.FWDN.com

write-host "Enter your Active Directory Credentials to connect to vSphere & Join Workstations to AD" -BackgroundColor Red -ForegroundColor White
$ADcred = get-credential
Write-host "Enter the local administrator account credentials to log into VM Workstations" -BackgroundColor Red -ForegroundColor White
$Localcred = get-credential

#Function checks it can make a powerCLI connection to the VM, to confirm the VM is up.
Function CheckVMPowerShell ($Host_Name,$Error_Log)
{
	Do
    {
        $retry="no error"
        Try 
        {
            Invoke-VMScript -VM "$Host_Name" -ScriptText "Write-Host 'hi'" -GuestCredential $Localcred -ScriptType Powershell -ErrorAction Stop
            Write-Host "PowerShell Connection UP"
	    }
        catch [System.Exception]
        {
            #Write-Host "Error Found"
			$retry="error"
			sleep 5
        }
        
    } While($retry -eq "error")

}

#Connect to vSphere server
try 
{
    connect-VIServer -server $vCenter -protocol https -Credential $ADcred -ErrorAction Stop
}
Catch
{
    $ErrorMessage = $_.Exception.Message
    $FailedItem = $_.Exception.ItemName
    Write-Output "Error Connecting.  See $PSScriptRoot\VSphere_ERROR.txt"
    "Error: $ErrorMessage" | Out-File "$PSScriptRoot\VSphere_ERROR.txt"
    echo $_.Exception | Format-List -force >> "$PSScriptRoot\VSphere_ERROR.txt"
    Break
}

ForEach ($workstation in $workstations) 
{
    # Loop does:
	# 1. Power on the machine if turned off
	# 2. Enable the Network if it's disabled and enable Network on Boot up
	# 3. Find the active vmxnet NIC and assign it an IP, Gatway & DNS Addresses
    # 4. Remove from Domain if necessary and restart (restart needed b/c powercli stops connecting)
    # 4. Set the computer name and restart
    # 5. Join to domain and loop to the next!
    
    $IP_Address=$workstation.IP_Address
    $Host_Name=$workstation.HOSTNAME
    $Error_Log="$PSScriptRoot\VM_"+"$Host_Name"+"_ERROR.txt"

	if ( (Get-VM $workstations.HOSTNAME | %{$_.PowerState}) -eq "PoweredOff" ) 
	{
		Get-VM $workstation.HOSTNAME | Start-VM
        sleep 10
	}
	
	#Get Network Connection settings to confirm the Network Cable is plugged in
	Get-NetworkAdapter -VM $workstation.HOSTNAME | %{ 
	$Connected=$_.ConnectionState.Connected; 
	$Start_Connected=$_.ConnectionState.StartConnected 
	$Network_Adapter=$_ 
    }
	
#Set the VM to connect to Network at startup and connect to the Network
	if (-not $Start_Connected -or -not $Connected)
	{
        Write-Host "Setting Network Adapters"
		Set-NetworkAdapter -NetworkAdapter $Network_Adapter -Connected:$True -StartConnected:$True -Confirm:$false
	}

sleep 5

	$execute1 = @"
Get-WmiObject -class win32_networkadapterconfiguration -filter {(Description LIKE 'vmxnet3%')} |
where-object {`$_.IpEnabled -eq `$true} | %{`$_.EnableStatic("$IP_Address", "$subnet");
`$_.SetGateways("$gateway", 1); `$_.SetDNSServerSearchOrder("$DNS_Server")};
`$PC=Get-WmiObject Win32_ComputerSystem;
if(`$PC.PartofDomain){`$PC.UnJoinDomainOrWorkgroup()};
restart-computer -force;
exit
"@

    $execute2 = @"
`$PC=Get-WmiObject Win32_ComputerSystem;
`$PC.Rename("$Host_Name");
restart-computer -force;
exit
"@
	
	write-output "Runing Invoke-VMScript on $($workstation.HOSTNAME)" | Out-File "$Error_Log"

    Try 
    {
        CheckVMPowerShell -Host_Name $Host_Name -Error_Log $Error_Log
        
        Write-Output "Executing first script"
        Invoke-VMScript -VM "$Host_Name" -ScriptText $execute1 -GuestCredential $Localcred -ScriptType Powershell #-ErrorAction Stop
        
        sleep 2
        
        write-output "restarting..."
        
        CheckVMPowerShell -Host_Name $Host_Name -Error_Log $Error_Log
        
        sleep 3
        Write-Output "Executing 2nd Script"
        Invoke-VMScript -VM "$Host_Name" -ScriptText $execute2 -GuestCredential $Localcred -ScriptType Powershell
        write-output "Restarting..."
        
		CheckVMPowerShell -Host_Name $Host_Name -Error_Log $Error_Log

        write-output "Joining machine to domain"
	
		#having too much trouble with the Add-Computer command, Invoke-VMScript just freezes when I use it... trying a different technique.
		$Join_Domain=@"
`$PC=Get-WmiObject Win32_ComputerSystem;
`$PC.JoinDomainOrWorkGroup("$domain", "$($ADcred.GetNetworkCredential().Password)", "$($ADcred.UserName)", "$ou", 3)
restart-computer -force
"@
        Invoke-VMScript -VM "$Host_Name" -ScriptText $Join_Domain -GuestCredential $Localcred
		
    }
    Catch 
    {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-Output "Error Connecting.  See $Error_Log"
        "Error: $ErrorMessage" | Out-File "$Error_Log" -Append
        echo $_.Exception | Format-List -force >> "$Error_Log"
        Break
    }

}

# ----  Old Code I kept for reference ----
<#
Function CheckRestart ($PC,$IP)
{

	#Sleep script while workstation powers down
	do {
		write-output "Waiting for machine to power down..."
		sleep 1
	} while (test-connection -count 1 -quiet $IP)

	# Sleep script while workstation comes back online
	do {
		write-output "Waiting for machine to come back online..."
		sleep 1
	} while (-not (test-connection -count 1 -quiet $IP))

    Write-Output "$PC back online..."
}
#>


        #not needed, add-computer adds the machine to the domain.
       # Write-Output "Create AD Account"
       # Invoke-VMScript -VM "$Host_Name" -ScriptText "New-ADComputer -Credential $ADcred -Name `"`$Host_Name`" -SamAccountName `"`$Host_Name`" -Path `"OU=Workstations,OU=Corporate,DC=cbs,DC=ad,DC=cbs,DC=net`" -Server cbs.ad.cbs.net" -GuestCredential $Localcred -ScriptType Powershell -ErrorAction Stop
        
<#        $Join_Domain=@"
`$domain="cbs.ad.cbs.net";
`$pwd=$($ADcred.Password);
`$credential=New-Object System.Management.Automation.PSCredential(`$user,`$pwd);
add-computer -domainname "cbs.ad.cbs.net" -credential `$credential -OUPath OU=Workstations,OU=Corporate,DC=cbs,DC=ad,DC=cbs,DC=net;
"@

        $Join_Domain=@"
add-computer -domainname "cbs.ad.cbs.net" -credential $ADcred -OUPath "OU=Workstations,OU=Corporate,DC=cbs,DC=ad,DC=cbs,DC=net" -confirm:`$false;
"@
	    write-output "Joining to doamin"
	    Invoke-VMScript -VM "$Host_Name" -ScriptText $Join_Domain -GuestCredential $Localcred
#>