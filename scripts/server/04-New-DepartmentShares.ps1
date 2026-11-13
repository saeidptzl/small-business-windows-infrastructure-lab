<#
.SYNOPSIS
  Creates the department folders and SMB shares and enforces access with share AND NTFS permissions.
.DESCRIPTION
  D:\Shares\Finance     -> \\DC01.corp.smallbiz.test\Finance
  D:\Shares\Operations  -> \\DC01.corp.smallbiz.test\Operations
  Share permissions : Administrators = Full, DL_FS_<Dept>_Modify = Change. Nobody else.
  NTFS permissions  : inheritance removed; SYSTEM + Administrators = Full,
                      DL_FS_<Dept>_Modify = Modify (this folder, subfolders, files).
  Access-based enumeration is on, offline caching is off.
  Effective access = the more restrictive of share and NTFS. Drive letters (GPO) are
  only a convenience; these permissions are what enforce access.
  Also writes one synthetic sample file per department.
.NOTES
  Run on: DC01, elevated, as SMALLBIZ\Administrator. Safe to run again.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig
Start-LabTranscript -Name 'dc01-04-new-departmentshares' | Out-Null
try {
    $nb = $cfg.DomainNetbios
    Write-LabStep "Share root $($cfg.ShareRoot) (administrators only)"
    New-Item -ItemType Directory -Force -Path $cfg.ShareRoot | Out-Null
    icacls.exe $cfg.ShareRoot /inheritance:r /grant:r 'NT AUTHORITY\SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null

    foreach ($dep in $cfg.Departments) {
        $path = Join-Path $cfg.ShareRoot $dep.Share
        $group = "$nb\$($dep.ShareGroup)"
        Write-LabStep "Folder + NTFS: $path"
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        icacls.exe $path /inheritance:r /grant:r 'NT AUTHORITY\SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F' "$($group):(OI)(CI)M" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on $path" }

        Write-LabStep "SMB share: \\$($cfg.DcFqdn)\$($dep.Share)"
        if (Get-SmbShare -Name $dep.Share -ErrorAction SilentlyContinue) {
            Remove-SmbShare -Name $dep.Share -Force
        }
        New-SmbShare -Name $dep.Share -Path $path -FullAccess 'BUILTIN\Administrators' -ChangeAccess $group `
            -FolderEnumerationMode AccessBased -CachingMode None `
            -Description "$($dep.Name) department share (lab)" | Out-Null
    }

    Write-LabStep 'Synthetic sample files'
    $finance = @(
        'Month,CostCentre,Category,AmountEUR'
        '2026-01,FIN-100,Office supplies,1250.00'
        '2026-02,FIN-100,Software licences,3400.00'
        '2026-03,FIN-200,Training,980.00'
        '# Synthetic data for the SmallBiz Windows lab - not real figures'
    )
    $operations = @(
        'Week,Team,Shift,Coordinator'
        '2026-W10,Warehouse A,Morning,marco.verdi'
        '2026-W10,Warehouse A,Afternoon,sara.conti'
        '# Synthetic data for the SmallBiz Windows lab'
    )
    if (-not (Test-Path $cfg.SampleFile)) {
        Set-Content -Path $cfg.SampleFile -Value $finance -Encoding UTF8
    }
    $opsFile = Join-Path $cfg.ShareRoot 'Operations\Shift-Plan-2026-W10-SAMPLE.csv'
    if (-not (Test-Path $opsFile)) { Set-Content -Path $opsFile -Value $operations -Encoding UTF8 }

    Write-LabStep 'Result: share permissions'
    Get-SmbShare | Where-Object Name -in $cfg.Departments.Share |
        Select-Object Name, Path, FolderEnumerationMode, CachingMode | Format-Table -AutoSize | Out-String | Write-Output
    Get-SmbShareAccess -Name $cfg.Departments.Share |
        Select-Object Name, AccountName, AccessControlType, AccessRight | Format-Table -AutoSize | Out-String | Write-Output
    Write-LabStep 'Result: NTFS permissions'
    foreach ($dep in $cfg.Departments) { icacls.exe (Join-Path $cfg.ShareRoot $dep.Share) | Write-Output }
}
finally {
    Stop-Transcript | Out-Null
}
