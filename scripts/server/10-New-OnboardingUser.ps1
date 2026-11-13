<#
.SYNOPSIS
  Ticket 1 (server side): onboard a new employee into a department.
.DESCRIPTION
  Creates the account in the department OU, sets a temporary password with
  "User must change password at next logon", adds the user to the department role
  group (GG_<Department>) and shows the resulting access chain:
      user -> GG_<Dept> -> DL_FS_<Dept>_Modify -> \\DC01.corp.smallbiz.test\<Dept>
  Then the technician verifies on CL01 (see docs/runbooks/RB-01-new-employee-onboarding.md).
.EXAMPLE
  .\10-New-OnboardingUser.ps1 -GivenName Elena -Surname Marini -Department Finance -Title 'Accounts Payable Clerk' -TicketId 'LAB-1001'
.NOTES
  Run on: DC01, elevated, as SMALLBIZ\Administrator (or a delegated helpdesk account).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GivenName,
    [Parameter(Mandatory)][string]$Surname,
    [Parameter(Mandatory)][ValidateSet('Finance', 'Operations')][string]$Department,
    [string]$Title = 'Employee',
    [Parameter(Mandatory)][string]$TicketId,
    [string]$SamAccountName
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LabCommon.psm1') -Force
Import-Module ActiveDirectory
$cfg = Import-LabConfig
if (-not $SamAccountName) { $SamAccountName = ("$GivenName.$Surname").ToLower() }
$dep = $cfg.Departments | Where-Object Name -eq $Department
$ou = "OU=$Department,OU=Users,OU=$($cfg.BaseOU),$($cfg.DomainDN)"
$tempPassword = Get-LabSecret -Name 'ONBOARD_INITIAL_PASSWORD' -Prompt "Temporary password for $SamAccountName"
Start-LabTranscript -Name "dc01-10-onboarding-$SamAccountName" | Out-Null
try {
    Wait-LabADReady
    Write-LabStep "Ticket $TicketId - onboarding $GivenName $Surname ($SamAccountName) into $Department"
    if (Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'") {
        throw "Account $SamAccountName already exists - check for a duplicate ticket before continuing."
    }
    New-ADUser -Name "$GivenName $Surname" -GivenName $GivenName -Surname $Surname `
        -SamAccountName $SamAccountName -UserPrincipalName "$SamAccountName@$($cfg.DomainFqdn)" `
        -DisplayName "$GivenName $Surname" -Department $Department -Title $Title -Company 'SmallBiz Lab' `
        -Description "Synthetic lab user - onboarded via $TicketId" -Path $ou `
        -AccountPassword $tempPassword -ChangePasswordAtLogon $true -Enabled $true
    Add-ADGroupMember -Identity $dep.UserGroup -Members $SamAccountName

    Write-LabStep 'Verification (directory side)'
    $u = Get-ADUser $SamAccountName -Properties Department, Title, Enabled, pwdLastSet, MemberOf
    [pscustomobject]@{
        SamAccountName        = $u.SamAccountName
        UserPrincipalName     = $u.UserPrincipalName
        OU                    = ($u.DistinguishedName -split ',', 2)[1]
        Department            = $u.Department
        Enabled               = $u.Enabled
        MustChangePassword    = ($u.pwdLastSet -eq 0)
        DirectGroups          = (($u.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }) -join ', ')
    } | Format-List | Out-String | Write-Output

    $chain = Get-ADGroupMember $dep.ShareGroup | Where-Object SamAccountName -eq $dep.UserGroup
    Write-Output ("Access chain: {0} -> {1} -> {2} -> \\{3}\{4}  ({5})" -f $SamAccountName, $dep.UserGroup,
        $dep.ShareGroup, $cfg.DcFqdn, $dep.Share, $(if ($chain) { 'OK' } else { 'BROKEN' }))
    $other = $cfg.Departments | Where-Object Name -ne $Department
    $inOther = Get-ADGroupMember $other.UserGroup | Where-Object SamAccountName -eq $SamAccountName
    Write-Output ("Not a member of {0}: {1}" -f $other.UserGroup, $(if ($inOther) { 'NO - check!' } else { 'confirmed' }))
    Write-Output "Next: sign in on CL01 as $($cfg.DomainNetbios)\$SamAccountName and run scripts\client\10-Test-DepartmentAccess.ps1"
}
finally {
    Stop-Transcript | Out-Null
}
