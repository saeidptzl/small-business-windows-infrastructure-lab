<#
.SYNOPSIS
  Ticket 2: client-side DNS diagnostics for "I can't open the shared drive".
.DESCRIPTION
  Works from the bottom up and separates "network" from "name resolution":
    D-01 Which DNS servers does the adapter use?      (Get-DnsClientServerAddress / ipconfig /all)
    D-02 Is the DC reachable by IP?                    (ping 10.10.50.10)
    D-03 Is each configured DNS server reachable?      (TCP 53)
    D-04 Does the DC's FQDN resolve with the system resolver?
    D-05 Does the domain's DC SRV record resolve?      (_ldap._tcp.dc._msdcs.<domain>)
    D-06 Does the AD DNS server itself answer correctly?   (Resolve-DnsName -Server <DC IP>)
    D-07 Can the DC locator find a domain controller?  (nltest /dsgetdc)
  and prints a one-line conclusion. Read-only: changes nothing.
.NOTES
  Run on: CL01. Any user can run it; elevation is not required.
#>
[CmdletBinding()]
param([string]$OutFile)
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
$if = $cfg.LanAdapterName
$results = @()

function Try-Resolve([string]$Name, [string]$Type, [string]$Server) {
    try {
        $p = @{ Name = $Name; Type = $Type; DnsOnly = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
        if ($Server) { $p.Server = $Server }
        $r = Resolve-DnsName @p | Where-Object { $_.Type -eq $Type }
        if ($Type -eq 'SRV') { return 'OK: ' + (($r | ForEach-Object { "$($_.NameTarget):$($_.Port)" }) -join ', ') }
        return 'OK: ' + (($r | ForEach-Object IPAddress) -join ', ')
    } catch { return 'FAILED: ' + ($_.Exception.Message -split "`r?`n")[0].Trim() }
}

Write-LabStep "DNS diagnostics on $env:COMPUTERNAME as $(whoami)"
Write-Output 'ipconfig /all (lab adapter):'
$ipc = ipconfig.exe /all | Out-String
$section = [regex]::Match($ipc, "(?s)Ethernet adapter $if\s*:.*?(?=\r?\n\r?\n\S|\z)").Value
($section -split "`r?`n") | Where-Object { $_ -match 'IPv4|Subnet|Gateway|DNS Servers|NetBIOS|Connection-specific|^\s+\d' } |
    ForEach-Object { "   $($_.TrimEnd())" } | Write-Output

$dns = @((Get-DnsClientServerAddress -InterfaceAlias $if -AddressFamily IPv4).ServerAddresses)
$results += New-LabResult -Id 'D-01' -Check 'Adapter uses the AD DNS server' -Expected $cfg.DcIPv4 `
    -Observed ($dns -join ', ') -Passed ($dns.Count -ge 1 -and $dns[0] -eq $cfg.DcIPv4)

$ping = Test-Connection -ComputerName $cfg.DcIPv4 -Count 2 -Quiet
$results += New-LabResult -Id 'D-02' -Check 'DC reachable by IP (ICMP)' -Expected 'reachable' `
    -Observed $(if ($ping) { 'reachable' } else { 'no reply' }) -Passed $ping

foreach ($s in $dns) {
    $t = Test-NetConnection -ComputerName $s -Port 53 -WarningAction SilentlyContinue -InformationLevel Quiet
    $results += New-LabResult -Id 'D-03' -Check "Configured DNS $s answers on TCP 53" -Expected 'open' `
        -Observed $(if ($t) { 'open' } else { 'unreachable' }) -Passed $t
}

$a = Try-Resolve -Name $cfg.DcFqdn -Type A
$results += New-LabResult -Id 'D-04' -Check "Resolve $($cfg.DcFqdn) (system resolver)" -Expected "OK: $($cfg.DcIPv4)" `
    -Observed $a -Passed ($a -eq "OK: $($cfg.DcIPv4)")

$srvName = "_ldap._tcp.dc._msdcs.$($cfg.DomainFqdn)"
$srv = Try-Resolve -Name $srvName -Type SRV
$results += New-LabResult -Id 'D-05' -Check 'Resolve DC SRV record (system resolver)' -Expected "OK: $($cfg.DcFqdn):389" `
    -Observed $srv -Passed ($srv -like 'OK:*')

$direct = Try-Resolve -Name $cfg.DcFqdn -Type A -Server $cfg.DcIPv4
$results += New-LabResult -Id 'D-06' -Check "Ask AD DNS $($cfg.DcIPv4) directly" -Expected "OK: $($cfg.DcIPv4)" `
    -Observed $direct -Passed ($direct -eq "OK: $($cfg.DcIPv4)")

$nl = nltest.exe /dsgetdc:$($cfg.DomainFqdn) /force 2>&1 | Out-String
$dcLine = [regex]::Match($nl, 'DC:\s*(\S+)').Groups[1].Value
$nlStatus = if ($dcLine) { $dcLine } else { ([regex]::Match($nl, 'ERROR_\w+').Value) }
$results += New-LabResult -Id 'D-07' -Check 'DC locator (nltest /dsgetdc)' -Expected "\\$($cfg.DcFqdn)" `
    -Observed $nlStatus -Passed ($dcLine -like "\\$($cfg.DcName)*")

Write-Output ''
$table = ($results | Format-Table -AutoSize | Out-String -Width 220).TrimEnd()
Write-Output $table

$wrongDns = -not ($results | Where-Object Id -eq 'D-01').Result.Equals('PASS')
$serverOk = ($results | Where-Object Id -eq 'D-06').Result -eq 'PASS'
$ipOk = ($results | Where-Object Id -eq 'D-02').Result -eq 'PASS'
$conclusion = if ($wrongDns -and $serverOk -and $ipOk) {
    "ROOT CAUSE: the adapter '$if' uses DNS $($dns -join ', ') instead of the AD DNS server $($cfg.DcIPv4). " +
    'The DC is reachable and its DNS answers correctly, so the client configuration is at fault.'
} elseif (-not $ipOk) {
    'The DC is not reachable by IP: check cabling/VLAN/IP settings before looking at DNS.'
} elseif (-not $serverOk) {
    'The AD DNS server does not answer correctly: check the DNS Server service and zone on DC01.'
} else {
    'Name resolution is healthy.'
}
Write-Output ''
Write-Output "Conclusion: $conclusion"
if ($OutFile) {
    @("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $env:COMPUTERNAME", $table, '', "Conclusion: $conclusion") |
        Set-Content -LiteralPath $OutFile -Encoding UTF8
}
