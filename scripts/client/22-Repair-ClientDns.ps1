<#
.SYNOPSIS
  Ticket 2 fix: point CL01's lab adapter back to the AD DNS server and verify.
.DESCRIPTION
  Sets DNS = 10.10.50.10 (DC01), clears the resolver cache, re-registers the client's
  DNS record, then verifies A + SRV resolution and the DC locator.
  In a production network the DNS server would normally come from DHCP; fixing the DHCP
  scope option (006) or removing the wrong static entry is the equivalent change there.
.NOTES
  Run on: CL01, elevated (local admin).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
Start-LabTranscript -Name 'cl01-22-repair-clientdns' | Out-Null
$results = @()
try {
    $if = $cfg.LanAdapterName
    $before = (Get-DnsClientServerAddress -InterfaceAlias $if -AddressFamily IPv4).ServerAddresses -join ', '
    Write-LabStep "DNS servers before: $before"
    Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses $cfg.DcIPv4
    Clear-DnsClientCache
    Register-DnsClient
    $after = (Get-DnsClientServerAddress -InterfaceAlias $if -AddressFamily IPv4).ServerAddresses -join ', '
    Write-LabStep "DNS servers after : $after"

    # If the PC booted while DNS was wrong, Netlogon has cached "no logon servers"
    # (nltest /sc_query: ERROR_NO_LOGON_SERVERS). Re-discover a DC and rebuild the secure
    # channel now instead of waiting for Netlogon's next retry. This does not reset the
    # computer account password (that would be Test-ComputerSecureChannel -Repair).
    # Netlogon also keeps a short negative cache, so force DC rediscovery and retry for up to ~90 s.
    for ($i = 1; $i -le 18 -and -not (Test-ComputerSecureChannel -ErrorAction SilentlyContinue); $i++) {
        Write-LabStep "Secure channel not established yet (attempt $i): nltest /dsgetdc /force + /sc_reset"
        nltest.exe /dsgetdc:$($cfg.DomainFqdn) /force | Out-Null
        nltest.exe /sc_reset:$($cfg.DomainFqdn) 2>&1 | Select-Object -First 3 | ForEach-Object { "   $_" } | Write-Output
        Start-Sleep -Seconds 5
    }

    $a = try { (Resolve-DnsName $cfg.DcFqdn -Type A -DnsOnly -ErrorAction Stop | Where-Object Type -eq 'A').IPAddress -join ', ' } catch { 'FAILED' }
    $results += New-LabResult -Id 'R-01' -Check "Resolve $($cfg.DcFqdn)" -Expected $cfg.DcIPv4 -Observed $a -Passed ($a -eq $cfg.DcIPv4)
    $srv = try { (Resolve-DnsName "_ldap._tcp.dc._msdcs.$($cfg.DomainFqdn)" -Type SRV -DnsOnly -ErrorAction Stop | Where-Object Type -eq 'SRV').NameTarget -join ', ' } catch { 'FAILED' }
    $results += New-LabResult -Id 'R-02' -Check 'Resolve DC SRV record' -Expected $cfg.DcFqdn -Observed $srv -Passed ($srv -eq $cfg.DcFqdn)
    $nl = nltest.exe /dsgetdc:$($cfg.DomainFqdn) /force 2>&1 | Out-String
    $dc = [regex]::Match($nl, 'DC:\s*(\S+)').Groups[1].Value
    $results += New-LabResult -Id 'R-03' -Check 'DC locator' -Expected "\\$($cfg.DcFqdn)" -Observed $dc -Passed ($dc -like "\\$($cfg.DcName)*")
    $sc = Test-ComputerSecureChannel -ErrorAction SilentlyContinue
    $results += New-LabResult -Id 'R-04' -Check 'Secure channel' -Expected 'True' -Observed "$sc" -Passed ([bool]$sc)

    Write-LabStep 'Result'
    $results | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
    Write-Output 'Next: the affected user signs out and back in (or runs gpupdate) and re-tests share access.'
}
finally {
    Stop-Transcript | Out-Null
}
if ($results | Where-Object Result -ne 'PASS') { exit 1 }
