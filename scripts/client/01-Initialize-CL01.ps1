<#
.SYNOPSIS
  Base configuration of the Windows 11 client CL01 before the domain join.
.DESCRIPTION
  * Lab NIC: renamed "LAB", static 10.10.50.21/24, no gateway, DNS = DC01 (10.10.50.10),
    DNS suffix corp.smallbiz.test. A domain client must use the AD DNS server, never a
    public resolver.
  * Name-resolution hardening: LLMNR off (policy) and NetBIOS over TCP/IP off on the LAB NIC.
    Both are common hardening steps (they block LLMNR/NBT-NS spoofing) and they make DNS the
    only resolver, which is what the DNS incident (ticket 2) relies on.
  * Sign-in screen does not show the last user name (shared PCs).
  * C:\LabEvidence: test output folder writable by signed-in users.
  * Connectivity checks to DC01 (DNS, LDAP, SMB).
.NOTES
  Run on: CL01, elevated, as the local administrator "labadmin". Safe to run again.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
Start-LabTranscript -Name 'cl01-01-initialize' | Out-Null
try {
    Write-LabStep 'Configuring the lab network adapter'
    $nic = Get-NetAdapter -Physical | Where-Object MacAddress -eq $cfg.ClientMac
    if (-not $nic) { throw "No network adapter with MAC $($cfg.ClientMac)" }
    if ($nic.Name -ne $cfg.LanAdapterName) { Rename-NetAdapter -Name $nic.Name -NewName $cfg.LanAdapterName }
    $if = $cfg.LanAdapterName
    Set-NetIPInterface -InterfaceAlias $if -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -ne $cfg.ClientIPv4 | Remove-NetIPAddress -Confirm:$false
    if (-not (Get-NetIPAddress -InterfaceAlias $if -IPAddress $cfg.ClientIPv4 -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceAlias $if -IPAddress $cfg.ClientIPv4 -PrefixLength $cfg.PrefixLength | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $cfg.DcIPv4
    Set-DnsClient -InterfaceAlias $if -ConnectionSpecificSuffix $cfg.DomainFqdn -RegisterThisConnectionsAddress $true

    Write-LabStep 'Name-resolution hardening: LLMNR off, NetBIOS over TCP/IP off on LAB'
    $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -Path $k -Name EnableMulticast -Value 0 -Type DWord
    $wmiNic = Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.MACAddress -eq ($cfg.ClientMac -replace '-', ':') }
    Invoke-CimMethod -InputObject $wmiNic -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 } | Out-Null

    Write-LabStep 'Sign-in screen: do not display the last signed-in user'
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name dontdisplaylastusername -Value 1 -Type DWord

    Write-LabStep 'Disabling the one-time autologon left by unattended setup'
    # Observed on the reference run: after setup Windows kept AutoAdminLogon=1 and signed the
    # local admin in again after a reboot. A domain workstation must always show the sign-in screen.
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value '0' -Type String
    Remove-ItemProperty -Path $wl -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue

    Write-LabStep "Evidence folder $($cfg.EvidenceRoot)"
    New-Item -ItemType Directory -Force -Path $cfg.EvidenceRoot | Out-Null
    icacls.exe $cfg.EvidenceRoot /grant 'BUILTIN\Users:(OI)(CI)M' | Out-Null

    Write-LabStep 'Connectivity checks to DC01'
    Start-Sleep -Seconds 5
    foreach ($port in 53, 389, 445) {
        $t = Test-NetConnection -ComputerName $cfg.DcIPv4 -Port $port -WarningAction SilentlyContinue
        Write-Output ("  TCP {0,-4} to {1}: {2}" -f $port, $cfg.DcIPv4, $(if ($t.TcpTestSucceeded) { 'open' } else { 'FAILED' }))
    }
    Resolve-DnsName -Name $cfg.DcFqdn -Type A -DnsOnly |
        Select-Object Name, Type, IPAddress | Format-Table -AutoSize | Out-String | Write-Output
    Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$($cfg.DomainFqdn)" -Type SRV -DnsOnly |
        Where-Object Type -eq 'SRV' | Select-Object Name, NameTarget, Port | Format-Table -AutoSize | Out-String | Write-Output
    Get-NetIPConfiguration -InterfaceAlias $if |
        Select-Object InterfaceAlias, @{n='IPv4';e={$_.IPv4Address.IPAddress}},
            @{n='DNS';e={$_.DNSServer.ServerAddresses -join ', '}} | Format-List | Out-String | Write-Output
}
finally {
    Stop-Transcript | Out-Null
}
