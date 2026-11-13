<#
.SYNOPSIS
  Automation helper: run a script or program inside a signed-in user's interactive session.
.DESCRIPTION
  Used by the host automation (via the QEMU guest agent, which runs as LocalSystem) to run
  checks exactly as the user sees things: same logon session, same mapped drives, same
  Kerberos tickets, no elevation. It registers a temporary scheduled task with the
  "Interactive" logon type (runs only if the user is signed in), starts it, waits, prints the
  output file and deletes the task. No password is needed or stored.
  A person reproducing the lab does not need this: sign in as the user and run the script.
.EXAMPLE
  .\Invoke-InUserSession.ps1 -User 'SMALLBIZ\elena.marini' -Script C:\LabSetup\client\10-Test-DepartmentAccess.ps1
.EXAMPLE
  .\Invoke-InUserSession.ps1 -User 'SMALLBIZ\elena.marini' -Program explorer.exe -ProgramArgs 'shell:MyComputerFolder' -NoWait
.NOTES
  Run on: CL01, as LocalSystem or an administrator.
#>
[CmdletBinding(DefaultParameterSetName = 'Script')]
param(
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory, ParameterSetName = 'Script')][string]$Script,
    [Parameter(ParameterSetName = 'Script')][string]$ScriptArgs = '',
    [Parameter(Mandatory, ParameterSetName = 'Program')][string]$Program,
    [Parameter(ParameterSetName = 'Program')][string]$ProgramArgs = '',
    [Parameter(ParameterSetName = 'Program')][switch]$NoWait,
    [int]$TimeoutSec = 300
)
$ErrorActionPreference = 'Stop'
$name = 'LabUserSession-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$out = $null
if ($PSCmdlet.ParameterSetName -eq 'Script') {
    $out = Join-Path 'C:\LabEvidence' ("usersession-{0}.txt" -f $name)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" -OutFile `"{1}`" {2}" -f $Script, $out, $ScriptArgs)
} else {
    $action = New-ScheduledTaskAction -Execute $Program -Argument $ProgramArgs
}
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSec)
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
try {
    Start-ScheduledTask -TaskName $name
    if ($PSCmdlet.ParameterSetName -eq 'Program' -and $NoWait) { Start-Sleep -Seconds 3; return }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskName $name).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
    $info = Get-ScheduledTaskInfo -TaskName $name
    if ($out) {
        if (Test-Path $out) { Get-Content -LiteralPath $out -Encoding UTF8 } else { Write-Output "No output file (task result $($info.LastTaskResult))" }
    }
    Write-Output ("[task {0} finished, result 0x{1:X}]" -f $name, $info.LastTaskResult)
}
finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}
