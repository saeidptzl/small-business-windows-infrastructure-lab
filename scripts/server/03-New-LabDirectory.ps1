<#
.SYNOPSIS
  Creates the OU structure, the department security groups (AGDLP) and the synthetic staff.
.DESCRIPTION
  OU=SmallBiz
    OU=Users        -> OU=Finance, OU=Operations   (staff accounts)
    OU=Groups       -> GG_* (global, "who you are") and DL_FS_* (domain local, "what you can use")
    OU=Workstations -> new domain computers land here (redircmp)
  AGDLP: user -> GG_Finance -> DL_FS_Finance_Modify -> share + NTFS permission.
  Staff passwords: one temporary password (prompted), "change at next logon" is set.
.NOTES
  Run on: DC01, elevated, as SMALLBIZ\Administrator (Domain Admins). Safe to run again.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
Import-Module ActiveDirectory
$cfg = Import-LabConfig
$staffPassword = Get-LabSecret -Name 'STAFF_INITIAL_PASSWORD' -Prompt 'Temporary password for the synthetic staff accounts'
Start-LabTranscript -Name 'dc01-03-new-labdirectory' | Out-Null
try {
    Wait-LabADReady
    $base = "OU=$($cfg.BaseOU),$($cfg.DomainDN)"

    function New-LabOU([string]$Name, [string]$Path) {
        $dn = "OU=$Name,$Path"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
            Write-Host "  created OU $dn"
        }
        return $dn
    }

    Write-LabStep 'Organizational units'
    $null     = New-LabOU $cfg.BaseOU $cfg.DomainDN
    $usersOU  = New-LabOU 'Users' $base
    $groupsOU = New-LabOU 'Groups' $base
    $wksOU    = New-LabOU 'Workstations' $base
    foreach ($dep in $cfg.Departments) { $null = New-LabOU $dep.Name $usersOU }

    Write-LabStep 'New computer accounts default to OU=Workstations'
    redircmp.exe $wksOU | Out-String | Write-Output

    Write-LabStep 'Security groups (AGDLP)'
    foreach ($dep in $cfg.Departments) {
        if (-not (Get-ADGroup -Filter "SamAccountName -eq '$($dep.UserGroup)'")) {
            New-ADGroup -Name $dep.UserGroup -GroupScope Global -GroupCategory Security -Path $groupsOU `
                -Description "Role group: members of the $($dep.Name) department"
        }
        if (-not (Get-ADGroup -Filter "SamAccountName -eq '$($dep.ShareGroup)'")) {
            New-ADGroup -Name $dep.ShareGroup -GroupScope DomainLocal -GroupCategory Security -Path $groupsOU `
                -Description "Resource group: Modify on \\$($cfg.DcFqdn)\$($dep.Share)"
        }
        Add-ADGroupMember -Identity $dep.ShareGroup -Members $dep.UserGroup
    }

    Write-LabStep 'Synthetic staff accounts'
    foreach ($s in $cfg.Staff) {
        $dep = $cfg.Departments | Where-Object Name -eq $s.Department
        $ou = "OU=$($s.Department),$usersOU"
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($s.Sam)'")) {
            New-ADUser -Name "$($s.GivenName) $($s.Surname)" -GivenName $s.GivenName -Surname $s.Surname `
                -SamAccountName $s.Sam -UserPrincipalName "$($s.Sam)@$($cfg.DomainFqdn)" `
                -DisplayName "$($s.GivenName) $($s.Surname)" -Department $s.Department -Title $s.Title `
                -Company 'SmallBiz Lab' -Description 'Synthetic lab user' -Path $ou `
                -AccountPassword $staffPassword -ChangePasswordAtLogon $true -Enabled $true
            Write-Output "  created $($s.Sam) in $ou"
        }
        Add-ADGroupMember -Identity $dep.UserGroup -Members $s.Sam
    }

    Write-LabStep 'Result: groups and members'
    foreach ($dep in $cfg.Departments) {
        foreach ($g in @($dep.UserGroup, $dep.ShareGroup)) {
            $grp = Get-ADGroup $g -Properties GroupScope
            $members = (Get-ADGroupMember $g | Sort-Object SamAccountName | ForEach-Object SamAccountName) -join ', '
            Write-Output ("  {0,-26} {1,-12} members: {2}" -f $g, $grp.GroupScope, $members)
        }
    }
    Write-LabStep 'Result: users'
    Get-ADUser -SearchBase $usersOU -Filter * -Properties Department, Title, Enabled |
        Sort-Object Department, SamAccountName |
        Select-Object SamAccountName, Department, Title, Enabled,
            @{n='OU';e={($_.DistinguishedName -split ',', 2)[1]}} |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Output
}
finally {
    Stop-Transcript | Out-Null
}
