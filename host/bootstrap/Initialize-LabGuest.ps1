<#
.SYNOPSIS
  First-logon bootstrap for both lab VMs (runs once from FirstLogonCommands).
.DESCRIPTION
  * Copies the lab scripts from the LABCFG media to C:\LabSetup.
  * Installs the virtio drivers (needed for the virtio-serial port) and the QEMU guest agent
    from the virtio-win ISO, so the Linux host can run the setup scripts without any
    network path into the isolated lab LAN.
  Runs on: DC01 and CL01, as the local administrator, automatically.
#>
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path 'C:\LabSetup\logs' | Out-Null
Start-Transcript -Path 'C:\LabSetup\logs\bootstrap.log' -Append | Out-Null
try {
    $cfg = (Get-Volume | Where-Object FileSystemLabel -eq 'LABCFG' | Select-Object -First 1).DriveLetter
    $vio = (Get-Volume | Where-Object FileSystemLabel -like 'virtio-win*' | Select-Object -First 1).DriveLetter
    if (-not $cfg -or -not $vio) { throw "LABCFG ($cfg) or virtio-win ($vio) media not found" }

    Copy-Item -Path "$($cfg):\lab\*" -Destination 'C:\LabSetup' -Recurse -Force
    # Files copied from a CD are read-only: clear the flag so the scripts can be updated later.
    Get-ChildItem -Path 'C:\LabSetup' -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    Write-Output "Lab scripts copied to C:\LabSetup"

    foreach ($msi in @("$($vio):\virtio-win-gt-x64.msi", "$($vio):\guest-agent\qemu-ga-x86_64.msi")) {
        $log = 'C:\LabSetup\logs\' + [IO.Path]::GetFileNameWithoutExtension($msi) + '.log'
        $p = Start-Process -FilePath msiexec.exe -Wait -PassThru `
            -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"")
        Write-Output "$msi -> exit code $($p.ExitCode) (0 = OK, 3010 = OK, reboot pending)"
    }
    Set-Service -Name 'QEMU-GA' -StartupType Automatic
    Start-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
    Get-Service -Name 'QEMU-GA' | Format-List Name, Status, StartType | Out-String | Write-Output
}
catch {
    Write-Output "BOOTSTRAP ERROR: $_"
}
finally {
    Stop-Transcript | Out-Null
}
