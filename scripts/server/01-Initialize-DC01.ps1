<#
.SYNOPSIS
  Base configuration of DC01 before it becomes a domain controller.
.DESCRIPTION
  * Lab NIC: renamed to "LAB", static 10.10.50.10/24, no default gateway (isolated LAN),
    DNS pointing to itself.
  * Data disk -> D: ("Data", department shares), backup disk -> E: ("Backup").
  * Allows ICMP echo from the lab subnet only (useful for troubleshooting).
  * Installs AD DS, DNS, File Server, Windows Server Backup and the GPMC PowerShell module.
.NOTES
  Run on: DC01, elevated PowerShell, as the local Administrator. Safe to run again.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
Start-LabTranscript -Name 'dc01-01-initialize' | Out-Null
try {
    Write-LabStep 'Configuring the lab network adapter'
    $nic = Get-NetAdapter -Physical | Where-Object MacAddress -eq $cfg.DcMac
    if (-not $nic) { throw "No network adapter with MAC $($cfg.DcMac)" }
    if ($nic.Name -ne $cfg.LanAdapterName) {
        Rename-NetAdapter -Name $nic.Name -NewName $cfg.LanAdapterName
    }
    $if = $cfg.LanAdapterName
    Set-NetIPInterface -InterfaceAlias $if -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -ne $cfg.DcIPv4 | Remove-NetIPAddress -Confirm:$false
    if (-not (Get-NetIPAddress -InterfaceAlias $if -IPAddress $cfg.DcIPv4 -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceAlias $if -IPAddress $cfg.DcIPv4 -PrefixLength $cfg.PrefixLength | Out-Null
    }
    # Single DC: point DNS to itself (its own IP first, loopback second).
    Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses @($cfg.DcIPv4, '127.0.0.1')

    Write-LabStep 'Bringing the data and backup disks online'
    $disks = @(
        @{ Serial = $cfg.DataDiskSerial;   Letter = $cfg.DataDriveLetter;   Label = 'Data' }
        @{ Serial = $cfg.BackupDiskSerial; Letter = $cfg.BackupDriveLetter; Label = 'Backup' }
    )
    foreach ($d in $disks) {
        $disk = Get-Disk | Where-Object { $_.SerialNumber -and $_.SerialNumber.Trim() -eq $d.Serial }
        if (-not $disk) { throw "Disk with serial $($d.Serial) not found (is the VM started in run mode?)" }
        if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false }
        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
        $disk = Get-Disk -Number $disk.Number
        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT
            New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $d.Letter |
                Format-Volume -FileSystem NTFS -NewFileSystemLabel $d.Label -Confirm:$false | Out-Null
        }
    }

    Write-LabStep 'Allowing ICMPv4 echo from the lab subnet only'
    Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In*' -ErrorAction SilentlyContinue |
        Set-NetFirewallRule -Enabled True -RemoteAddress $cfg.LabSubnet

    Write-LabStep 'Installing roles and features'
    $features = 'AD-Domain-Services', 'DNS', 'FS-FileServer', 'Windows-Server-Backup', 'GPMC'
    Install-WindowsFeature -Name $features -IncludeManagementTools |
        Select-Object Success, RestartNeeded, ExitCode | Format-Table -AutoSize | Out-String | Write-Output

    Write-LabStep 'Result'
    Get-NetIPConfiguration -InterfaceAlias $if |
        Select-Object InterfaceAlias, @{n='IPv4';e={$_.IPv4Address.IPAddress}},
            @{n='Gateway';e={$_.IPv4DefaultGateway.NextHop}}, @{n='DNS';e={$_.DNSServer.ServerAddresses -join ', '}} |
        Format-List | Out-String | Write-Output
    Get-Volume | Where-Object DriveLetter -in 'C', $cfg.DataDriveLetter, $cfg.BackupDriveLetter |
        Sort-Object DriveLetter |
        Select-Object DriveLetter, FileSystemLabel, FileSystem, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}} |
        Format-Table -AutoSize | Out-String | Write-Output
    Get-WindowsFeature -Name $features | Select-Object Name, InstallState |
        Format-Table -AutoSize | Out-String | Write-Output
}
finally {
    Stop-Transcript | Out-Null
}
