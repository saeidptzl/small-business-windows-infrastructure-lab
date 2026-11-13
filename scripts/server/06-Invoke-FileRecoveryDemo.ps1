<#
.SYNOPSIS
  File-level backup and recovery demo with Windows Server Backup (wbadmin), verified by SHA-256.
.DESCRIPTION
  1. Record the SHA-256 of the sample file D:\Shares\Finance\Budget-2026-Q1-SAMPLE.csv.
  2. One-time backup of that file to the backup volume E: (wbadmin start backup -include).
  3. Simulate the incident: the file is accidentally overwritten.
  4. Restore the file from the backup to an ALTERNATE location (D:\RecoveryTest\<timestamp>).
  5. Compare the recovered file's hash with the original hash.
  6. Only if the hashes match, copy the recovered file back over the damaged one and re-check.

  SCOPE - what this demo is and is not:
  * It is a single-file, on-demand backup to a second virtual disk attached to the SAME VM.
  * It proves the restore procedure and the integrity check, nothing more.
  * It is NOT a backup strategy: no schedule, no retention policy, no off-site or offline/
    immutable copy (3-2-1), no system state / Active Directory backup, no bare-metal recovery.
    The backup disk lives on the same host, so a host failure loses both copies.
.NOTES
  Run on: DC01, elevated, as SMALLBIZ\Administrator (Backup Operators would also be enough).
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$BackupTarget,
    # Skip step 6 (leave the damaged original in place).
    [switch]$NoReplace
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
if (-not $Path) { $Path = $cfg.SampleFile }
if (-not $BackupTarget) { $BackupTarget = "$($cfg.BackupDriveLetter):" }
Start-LabTranscript -Name 'dc01-06-file-recovery-demo' | Out-Null
$results = @()
try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $restoreDir = Join-Path $cfg.RecoveryRoot $stamp

    Write-LabStep "1. Original file: $Path"
    $orig = Get-Item -LiteralPath $Path
    $origHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Write-Output ("   size {0} bytes, modified {1}, SHA-256 {2}" -f $orig.Length, $orig.LastWriteTime, $origHash)

    Write-LabStep "2. One-time backup of the file to $BackupTarget"
    $out = & wbadmin.exe start backup "-backupTarget:$BackupTarget" "-include:$Path" -quiet 2>&1
    $out | Where-Object { $_ -match '\S' } | Select-Object -Last 6 | ForEach-Object { "   $_" } | Write-Output
    if ($LASTEXITCODE -ne 0) { throw "wbadmin backup failed (exit $LASTEXITCODE)" }

    $versions = & wbadmin.exe get versions "-backupTarget:$BackupTarget" 2>&1
    $version = ($versions | Select-String -Pattern 'Version identifier:\s*(\S+)' |
        Select-Object -Last 1).Matches[0].Groups[1].Value
    Write-Output "   newest backup version: $version (identifier is in UTC)"

    Write-LabStep '3. Incident simulation: the file is accidentally overwritten'
    Set-Content -LiteralPath $Path -Value 'oops - spreadsheet saved over by mistake' -Encoding UTF8
    $damagedHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Write-Output "   damaged file SHA-256 $damagedHash"

    Write-LabStep "4. Restore to an alternate location: $restoreDir"
    New-Item -ItemType Directory -Force -Path $restoreDir | Out-Null
    $out = & wbadmin.exe start recovery "-version:$version" -itemType:File "-items:$Path" `
        "-backupTarget:$BackupTarget" "-recoveryTarget:$restoreDir" -overwrite:CreateCopy -quiet 2>&1
    $out | Where-Object { $_ -match '\S' } | Select-Object -Last 4 | ForEach-Object { "   $_" } | Write-Output
    if ($LASTEXITCODE -ne 0) { throw "wbadmin recovery failed (exit $LASTEXITCODE)" }
    $restored = Get-ChildItem -LiteralPath $restoreDir -Recurse -File -Filter (Split-Path $Path -Leaf) | Select-Object -First 1
    if (-not $restored) { throw "Recovered file not found under $restoreDir" }
    $restoredHash = (Get-FileHash -LiteralPath $restored.FullName -Algorithm SHA256).Hash
    Write-Output "   recovered file: $($restored.FullName)"

    Write-LabStep '5. Integrity check'
    Write-Output "   original  SHA-256 $origHash"
    Write-Output "   recovered SHA-256 $restoredHash"
    $results += New-LabResult -Id 'BR-01' -Check 'Backup job completed' -Expected 'wbadmin exit 0, version listed' `
        -Observed "version $version" -Passed ([bool]$version)
    $results += New-LabResult -Id 'BR-02' -Check 'Damage simulated' -Expected 'hash differs from original' `
        -Observed $damagedHash.Substring(0, 16) -Passed ($damagedHash -ne $origHash)
    $results += New-LabResult -Id 'BR-03' -Check 'Restore to alternate location' -Expected "file under $restoreDir" `
        -Observed $restored.FullName -Passed ($restored.FullName -like "$restoreDir*")
    $results += New-LabResult -Id 'BR-04' -Check 'Recovered hash = original hash' -Expected $origHash.Substring(0, 16) `
        -Observed $restoredHash.Substring(0, 16) -Passed ($restoredHash -eq $origHash)

    if (-not $NoReplace -and $restoredHash -eq $origHash) {
        Write-LabStep '6. Hashes match: putting the recovered file back in place'
        Copy-Item -LiteralPath $restored.FullName -Destination $Path -Force
        $finalHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        $results += New-LabResult -Id 'BR-05' -Check 'File back in the share' -Expected $origHash.Substring(0, 16) `
            -Observed $finalHash.Substring(0, 16) -Passed ($finalHash -eq $origHash)
    }

    Write-LabStep 'Result'
    $results | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
}
finally {
    Stop-Transcript | Out-Null
}
if ($results | Where-Object Result -ne 'PASS') { exit 1 }
