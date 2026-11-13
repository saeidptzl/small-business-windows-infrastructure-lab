<#
.SYNOPSIS
  Creates ONE Group Policy Object that maps each department's share for its members.
.DESCRIPTION
  GPO "SB-U-DepartmentDriveMaps", linked to OU=SmallBiz (covers the staff and CL01):
    User Configuration > Preferences > Windows Settings > Drive Maps
      F: -> \\DC01.corp.smallbiz.test\Finance     item-level targeting: member of GG_Finance
      O: -> \\DC01.corp.smallbiz.test\Operations  item-level targeting: member of GG_Operations
    Computer Configuration > Administrative Templates > System > Logon
      "Always wait for the network at computer startup and logon" = Enabled
      (Drive Maps need synchronous foreground processing to apply reliably at sign-in.)
  The GroupPolicy module has no cmdlet for Group Policy Preferences, so the script writes
  Drives.xml exactly as the GPMC editor would, registers the Drive Maps client-side
  extension on the GPO and increments the version in AD and in GPT.INI.
  The mapping is a convenience. Access is enforced by share + NTFS permissions (script 04).
.NOTES
  Run on: DC01, elevated, as SMALLBIZ\Administrator, after scripts 03 and 04.
  Equivalent GUI path: Group Policy Management > OU SmallBiz > Create a GPO and link it here.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
Import-Module ActiveDirectory, GroupPolicy
$cfg = Import-LabConfig
Start-LabTranscript -Name 'dc01-05-new-drivemapgpo' | Out-Null
try {
    Wait-LabADReady
    $name = $cfg.DriveMapGpoName
    $target = "OU=$($cfg.BaseOU),$($cfg.DomainDN)"

    Write-LabStep "GPO $name"
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $name -Comment ('Maps the department share for members of GG_Finance (F:) and ' +
            'GG_Operations (O:). Convenience only: share + NTFS permissions enforce access.')
    }

    Write-LabStep 'Computer setting: Always wait for the network at computer startup and logon'
    Set-GPRegistryValue -Guid $gpo.Id -Key 'HKLM\Software\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon' `
        -ValueName 'SyncForegroundPolicy' -Type DWord -Value 1 | Out-Null

    Write-LabStep 'User preference: Drive Maps with item-level targeting by security group'
    $sysvol = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters').SysVol
    $policyPath = Join-Path $sysvol "$($cfg.DomainFqdn)\Policies\{$($gpo.Id)}"
    $drivesDir = Join-Path $policyPath 'User\Preferences\Drives'
    New-Item -ItemType Directory -Force -Path $drivesDir | Out-Null
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $items = foreach ($dep in $cfg.Departments) {
        $sid = (Get-ADGroup $dep.UserGroup).SID.Value
        $uid = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
        $unc = "\\$($cfg.DcFqdn)\$($dep.Share)"
        ('<Drive clsid="{{935D1B74-9CB8-4e3c-9914-7DD559B7A417}}" name="{0}:" status="{0}:" image="2" changed="{1}" uid="{2}" bypassErrors="1">' -f $dep.Drive, $now, $uid) +
        ('<Properties action="R" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="{0}" label="{1}" persistent="0" useLetter="1" letter="{2}"/>' -f $unc, $dep.Name, $dep.Drive) +
        ('<Filters><FilterGroup bool="AND" not="0" name="{0}\{1}" sid="{2}" userContext="1" primaryGroup="0" localGroup="0"/></Filters>' -f $cfg.DomainNetbios, $dep.UserGroup, $sid) +
        '</Drive>'
    }
    $xml = '<?xml version="1.0" encoding="utf-8"?>' + "`r`n" +
           '<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">' + ($items -join '') + '</Drives>'
    [IO.File]::WriteAllText((Join-Path $drivesDir 'Drives.xml'), $xml, (New-Object System.Text.UTF8Encoding($false)))

    Write-LabStep 'Registering the Drive Maps client-side extension and bumping the user version'
    $gpoDN = "CN={$($gpo.Id)},CN=Policies,CN=System,$($cfg.DomainDN)"
    $cse = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]' +
           '[{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]'
    $ad = Get-ADObject $gpoDN -Properties versionNumber
    $ver = [int]$ad.versionNumber
    $newVer = ((($ver -shr 16) + 1) -shl 16) -bor ($ver -band 0xFFFF)
    Set-ADObject $gpoDN -Replace @{ gPCUserExtensionNames = $cse; versionNumber = $newVer }
    $gptIni = Join-Path $policyPath 'GPT.INI'
    $lines = @(Get-Content $gptIni | Where-Object { $_ -notmatch '^Version=' })
    $lines += "Version=$newVer"
    Set-Content -Path $gptIni -Value $lines -Encoding Ascii

    Write-LabStep "Linking the GPO to $target"
    $linked = (Get-GPInheritance -Target $target).GpoLinks | Where-Object DisplayName -eq $name
    if (-not $linked) { New-GPLink -Guid $gpo.Id -Target $target -LinkEnabled Yes | Out-Null }

    Write-LabStep 'Result'
    $g = Get-GPO -Guid $gpo.Id
    [pscustomobject]@{
        DisplayName       = $g.DisplayName
        Id                = $g.Id
        GpoStatus         = $g.GpoStatus
        'User DS/Sysvol'  = "$($g.User.DSVersion)/$($g.User.SysvolVersion)"
        'Comp DS/Sysvol'  = "$($g.Computer.DSVersion)/$($g.Computer.SysvolVersion)"
        LinkedTo          = $target
    } | Format-List | Out-String | Write-Output
    (Get-GPInheritance -Target $target).GpoLinks |
        Select-Object DisplayName, Enabled, Enforced, Order | Format-Table -AutoSize | Out-String | Write-Output
    Write-Output 'Drives.xml:'
    ([xml]$xml).Drives.Drive | ForEach-Object {
        '  {0}  {1,-40} target group: {2}' -f $_.name, $_.Properties.path, $_.Filters.FilterGroup.name
    } | Write-Output
    $report = Join-Path $cfg.EvidenceRoot 'gpo-SB-U-DepartmentDriveMaps.html'
    Get-GPOReport -Guid $gpo.Id -ReportType Html -Path $report
    Write-Output "HTML report: $report"
}
finally {
    Stop-Transcript | Out-Null
}
