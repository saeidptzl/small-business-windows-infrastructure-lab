<#
.SYNOPSIS
  Verifies that CL01 is a healthy domain member and receives the drive-map GPO.
.NOTES
  Run on: CL01, elevated (local admin or domain admin), after the restart that follows the join.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
Start-LabTranscript -Name 'cl01-03-test-domainmembership' | Out-Null
$results = @()
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $results += New-LabResult -Id 'DJ-01' -Check 'Computer is domain member' -Expected $cfg.DomainFqdn `
        -Observed "$($cs.Domain) (PartOfDomain=$($cs.PartOfDomain))" -Passed ($cs.PartOfDomain -and $cs.Domain -eq $cfg.DomainFqdn)

    $sc = Test-ComputerSecureChannel -ErrorAction SilentlyContinue
    $results += New-LabResult -Id 'DJ-02' -Check 'Secure channel to the domain' -Expected 'True' `
        -Observed "$sc" -Passed ([bool]$sc)

    $dc = (nltest.exe /dsgetdc:$($cfg.DomainFqdn) 2>&1 | Select-String -Pattern '^\s*DC:\s*(\S+)').Matches
    $dcName = if ($dc) { $dc[0].Groups[1].Value } else { '(none)' }
    $results += New-LabResult -Id 'DJ-03' -Check 'DC locator finds a DC' -Expected "\\$($cfg.DcFqdn)" `
        -Observed $dcName -Passed ($dcName -like "\\$($cfg.DcName)*")

    Write-LabStep 'Refreshing computer policy'
    gpupdate.exe /target:computer /force | Out-Null
    $gp = gpresult.exe /scope computer /r 2>&1 | Out-String
    $results += New-LabResult -Id 'DJ-04' -Check 'Drive-map GPO applies to the computer' -Expected $cfg.DriveMapGpoName `
        -Observed $(if ($gp -match [regex]::Escape($cfg.DriveMapGpoName)) { 'listed under Applied GPOs' } else { 'not listed' }) `
        -Passed ($gp -match [regex]::Escape($cfg.DriveMapGpoName))
    $ou = ($gp | Select-String -Pattern 'CN=CL01,(OU=[^\r\n]+)').Matches
    Write-Output ('Computer object: ' + $(if ($ou) { $ou[0].Value } else { 'see gpresult' }))

    Write-LabStep 'Result'
    $results | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
}
finally {
    Stop-Transcript | Out-Null
}
if ($results | Where-Object Result -ne 'PASS') { exit 1 }
