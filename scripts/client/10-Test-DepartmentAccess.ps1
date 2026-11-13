<#
.SYNOPSIS
  Checks, from the signed-in user's own session, which department drive is mapped and which
  department shares the user can really open, using the direct UNC paths.
.DESCRIPTION
  The drive letter only proves the GPO ran. Access is proved separately on the UNC paths:
    own department share   -> list + create/delete a test file  (expected: OK)
    other department share -> list                              (expected: ACCESS DENIED)
.NOTES
  Run on: CL01, as the domain user being tested (NOT elevated, NOT as an admin):
    powershell -ExecutionPolicy Bypass -File C:\LabSetup\client\10-Test-DepartmentAccess.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [string]$Label = 'access',
    # The department the ticket says the user belongs to. Needed when the group names in the
    # token cannot be resolved (for example a cached sign-in while DNS is broken).
    [ValidateSet('', 'Finance', 'Operations')][string]$ExpectedDepartment = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
if (-not $OutFile) {
    $OutFile = Join-Path $cfg.EvidenceRoot ('{0}_{1}_{2}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $env:USERNAME, $Label)
}

$lines = New-Object System.Collections.Generic.List[string]
function Out-Both([string]$Text) { $lines.Add($Text); Write-Output $Text }

$who = (whoami.exe).Trim()
$tokenGroups = @(whoami.exe /groups /fo csv | ConvertFrom-Csv)
$groups = $tokenGroups | Where-Object { $_.'Group Name' -like "$($cfg.DomainNetbios)\*" } | ForEach-Object { $_.'Group Name' }
$unresolved = @($tokenGroups | Where-Object { $_.SID -like 'S-1-5-21-*' -and $_.'Group Name' -notlike "$($cfg.DomainNetbios)\*" }).Count
Out-Both ("[{0}] User: {1}   Computer: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $who, $env:COMPUTERNAME)
Out-Both ("Domain groups in token: {0}" -f $(if ($groups) { $groups -join ', ' } else { '(no names resolved)' }))
if ($unresolved) { Out-Both "Domain group SIDs whose names could not be resolved: $unresolved (is a DC reachable by name?)" }

$mine = @($cfg.Departments | Where-Object { $groups -contains "$($cfg.DomainNetbios)\$($_.UserGroup)" })
if ($mine.Count -eq 0 -and $ExpectedDepartment) {
    $mine = @($cfg.Departments | Where-Object Name -eq $ExpectedDepartment)
    Out-Both "Department taken from the ticket: $ExpectedDepartment"
}
if ($mine.Count -ne 1) {
    Out-Both "User is in $($mine.Count) department groups - expected exactly 1."
}
$maps = @(Get-SmbMapping -ErrorAction SilentlyContinue)
Out-Both 'Mapped drives (Get-SmbMapping):'
if ($maps.Count -eq 0) { Out-Both '  (none)' }
foreach ($m in $maps) { Out-Both ("  {0}  {1}  {2}" -f $m.LocalPath, $m.RemotePath, $m.Status) }

$results = @()
foreach ($dep in $cfg.Departments) {
    $unc = "\\$($cfg.DcFqdn)\$($dep.Share)"
    $isMine = ($mine | Where-Object Name -eq $dep.Name) -ne $null
    $map = $maps | Where-Object LocalPath -eq "$($dep.Drive):"
    if ($isMine) {
        $ok = $map -and $map.RemotePath -eq $unc
        $results += New-LabResult -Id "AC-$($dep.Drive)1" -Check "$($dep.Drive): drive mapped by GPO" `
            -Expected "$($dep.Drive): -> $unc" -Observed $(if ($map) { "$($map.LocalPath) -> $($map.RemotePath)" } else { 'not mapped' }) -Passed ([bool]$ok)

        $read = Test-LabUncAccess -Path $unc
        $results += New-LabResult -Id "AC-$($dep.Drive)2" -Check "List own share via UNC" -Expected 'OK' `
            -Observed "$unc : $read" -Passed ($read -eq 'OK')

        $probe = Join-Path $unc ("write-test-{0}-{1}.tmp" -f $env:USERNAME, (Get-Random))
        try {
            Set-Content -LiteralPath $probe -Value 'write test' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -ErrorAction Stop
            $write = 'OK (created and deleted a test file)'
        } catch { $write = 'FAILED: ' + $_.Exception.Message.Trim() }
        $results += New-LabResult -Id "AC-$($dep.Drive)3" -Check "Write to own share via UNC" -Expected 'OK' `
            -Observed $write -Passed ($write -like 'OK*')
    }
    else {
        $results += New-LabResult -Id "AC-$($dep.Drive)1" -Check "$($dep.Drive): drive NOT mapped" `
            -Expected 'not mapped' -Observed $(if ($map) { "$($map.LocalPath) -> $($map.RemotePath)" } else { 'not mapped' }) -Passed (-not $map)
        $read = Test-LabUncAccess -Path $unc
        $results += New-LabResult -Id "AC-$($dep.Drive)2" -Check "Other department share via UNC" -Expected 'ACCESS DENIED' `
            -Observed "$unc : $read" -Passed ($read -eq 'ACCESS DENIED')
    }
}
Out-Both ''
($results | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() -split "`r?`n" | ForEach-Object { Out-Both $_ }
$fail = @($results | Where-Object Result -ne 'PASS').Count
Out-Both ''
Out-Both ("Summary: {0} checks, {1} passed, {2} failed" -f $results.Count, ($results.Count - $fail), $fail)
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
Set-Content -LiteralPath $OutFile -Value $lines -Encoding UTF8
