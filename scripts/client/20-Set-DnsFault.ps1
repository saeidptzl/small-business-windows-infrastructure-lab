<#
.SYNOPSIS
  LAB ONLY - Ticket 2 setup: deliberately misconfigures the DNS server on CL01's lab adapter.
.DESCRIPTION
  Reproduces a frequent real-world mistake: a domain PC pointed at a public resolver
  (default 8.8.8.8) instead of the AD DNS server. Public resolvers do not know the internal
  zone corp.smallbiz.test, so domain names stop resolving. In this isolated lab 8.8.8.8 is
  also unreachable; either way, internal names fail.
  Refuses to run anywhere except CL01 in corp.smallbiz.test.
.NOTES
  Run on: CL01, elevated (local admin). Undo with 22-Repair-ClientDns.ps1.
#>
[CmdletBinding()]
param([string]$WrongDnsServer = '8.8.8.8')
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
$cs = Get-CimInstance Win32_ComputerSystem
if ($env:COMPUTERNAME -ne $cfg.ClientName -or $cs.Domain -ne $cfg.DomainFqdn) {
    throw "Safety stop: this fault injection only runs on $($cfg.ClientName) in $($cfg.DomainFqdn)."
}
Start-LabTranscript -Name 'cl01-20-set-dnsfault' | Out-Null
try {
    $if = $cfg.LanAdapterName
    $before = (Get-DnsClientServerAddress -InterfaceAlias $if -AddressFamily IPv4).ServerAddresses -join ', '
    Write-LabStep "DNS servers before: $before"
    Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $WrongDnsServer
    Clear-DnsClientCache
    $after = (Get-DnsClientServerAddress -InterfaceAlias $if -AddressFamily IPv4).ServerAddresses -join ', '
    Write-LabStep "DNS servers after : $after   (fault injected, DNS cache cleared)"
}
finally {
    Stop-Transcript | Out-Null
}
