<#
.SYNOPSIS
  Promotes DC01 to the first domain controller of a new forest: corp.smallbiz.test (SMALLBIZ).
.DESCRIPTION
  Installs the AD-integrated DNS zone at the same time. You are prompted for the
  Directory Services Restore Mode (DSRM) password. The server restarts afterwards.
  After the restart, sign in as SMALLBIZ\Administrator (same password as the former
  local Administrator).
.NOTES
  Run on: DC01, elevated, as the local Administrator, after 01-Initialize-DC01.ps1.
#>
[CmdletBinding()]
param(
    # Restart automatically 15 seconds after promotion (default). Use -NoRestart to restart yourself.
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig

if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
    Write-LabStep "$env:COMPUTERNAME is already a domain controller - nothing to do."
    return
}

$dsrm = Get-LabSecret -Name 'DSRM_PASSWORD' -Prompt 'Directory Services Restore Mode (DSRM) password'
Start-LabTranscript -Name 'dc01-02-install-adforest' | Out-Null
try {
    Import-Module ADDSDeployment
    $params = @{
        DomainName                    = $cfg.DomainFqdn
        DomainNetbiosName             = $cfg.DomainNetbios
        InstallDns                    = $true
        SafeModeAdministratorPassword = $dsrm
        NoRebootOnCompletion          = $true
        Force                         = $true
    }
    Write-LabStep "Prerequisite check for forest $($cfg.DomainFqdn)"
    $test = Test-ADDSForestInstallation @params -WarningAction SilentlyContinue
    Write-Output ("Prerequisite check: {0} - {1}" -f $test.Status, $test.Message)
    if ($test.Status -ne 'Success') { throw 'Prerequisite check failed' }

    Write-LabStep 'Installing the forest (AD DS + DNS)'
    $r = Install-ADDSForest @params -WarningAction SilentlyContinue
    Write-Output ("Install-ADDSForest: {0} - {1}" -f $r.Status, $r.Message)
}
finally {
    Stop-Transcript | Out-Null
}
if (-not $NoRestart) {
    Write-LabStep 'Restarting in 15 seconds to complete the promotion'
    shutdown.exe /r /t 15 /d p:4:2 /c 'AD DS forest promotion' | Out-Null
}
