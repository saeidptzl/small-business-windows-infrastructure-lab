<#
.SYNOPSIS
  Joins CL01 to corp.smallbiz.test, directly into OU=Workstations,OU=SmallBiz.
.DESCRIPTION
  Prompts for the password of SMALLBIZ\Administrator. In production use a delegated
  "join computers to the Workstations OU" account instead of a Domain Admin.
  Restarts the client 15 seconds after a successful join.
.NOTES
  Run on: CL01, elevated, as the local administrator, after 01-Initialize-CL01.ps1.
  Afterwards: 03-Test-DomainMembership.ps1.
#>
[CmdletBinding()]
param(
    [string]$JoinAccount = 'Administrator',
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
$cfg = Import-LabConfig

if ((Get-CimInstance Win32_ComputerSystem).Domain -eq $cfg.DomainFqdn) {
    Write-LabStep "$env:COMPUTERNAME is already a member of $($cfg.DomainFqdn)."
    return
}
$pw = Get-LabSecret -Name 'DC01_ADMIN_PASSWORD' -Prompt "Password for $($cfg.DomainNetbios)\$JoinAccount"
$cred = New-Object System.Management.Automation.PSCredential("$($cfg.DomainNetbios)\$JoinAccount", $pw)
Start-LabTranscript -Name 'cl01-02-join-domain' | Out-Null
try {
    $ou = "OU=Workstations,OU=$($cfg.BaseOU),$($cfg.DomainDN)"
    Write-LabStep "Joining $env:COMPUTERNAME to $($cfg.DomainFqdn) in $ou"
    Add-Computer -DomainName $cfg.DomainFqdn -OUPath $ou -Credential $cred -Force -PassThru |
        Format-List ComputerName, HasSucceeded | Out-String | Write-Output
}
finally {
    Stop-Transcript | Out-Null
}
if (-not $NoRestart) {
    Write-LabStep 'Restarting in 15 seconds'
    shutdown.exe /r /t 15 /d p:4:2 /c 'Domain join' | Out-Null
}
