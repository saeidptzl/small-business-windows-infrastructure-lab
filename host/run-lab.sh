#!/usr/bin/env bash
# End-to-end runner: the same commands used for the reference run, grouped in stages.
# Every guest script output is saved under $LAB_RUNTIME/evidence-raw/<stage>-<time>/.
#
#   host/run-lab.sh prepare                      secrets + LABCFG ISOs for both VMs
#   host/run-lab.sh install dc01|cl01            unattended install, then restart in run mode
#   host/run-lab.sh dc01                         server scripts 01-05 (AD DS, DNS, shares, GPO)
#   host/run-lab.sh cl01                         client scripts 01-03 (network, join, checks)
#   host/run-lab.sh backup                       file backup/restore demo (script 06)
#   host/run-lab.sh ticket1 <Given> <Surname> <Finance|Operations> <TicketId>
#   host/run-lab.sh ticket2 <sam> <Finance|Operations> <TicketId>
#   host/run-lab.sh verify                       read-only health checks
#
# Ticket stages sign in on the CL01 console with real keystrokes (QMP), exactly like a person.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=host/lab.env
source "$HERE/lab.env"
L() { "$LAB_PYTHON" "$HERE/labctl.py" "$@"; }

stage="${1:-}"; shift || true
OUT="$LAB_RUNTIME/evidence-raw/${stage:-none}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/screens"
log() { echo "[$(date +%H:%M:%S)] $*"; }
# run <vm> <logname> <labctl args...>: run and keep the output
run() { local vm="$1" name="$2"; shift 2; log "$vm: $name"; L "$@" 2>&1 | tee "$OUT/$name.txt"; return "${PIPESTATUS[0]}"; }
shot() { L screenshot "$1" "$OUT/screens/$2.png" >/dev/null && log "screenshot $2.png"; }
in_user() { # in_user <user> <script> [args]  - run a script inside the user's own session
  L ps cl01 --timeout 600 'client\tools\Invoke-InUserSession.ps1' -User "$1" -Script "C:\\LabSetup\\$2" -ScriptArgs "${3:-}"
}
wait_dc_services() {
  for _ in $(seq 60); do
    [[ "$(L pscmd dc01 '(Get-Service ADWS,DNS,Netlogon,NTDS | ? Status -ne Running).Count' 2>/dev/null | tr -d '\r\n ')" == 0 ]] && return 0
    sleep 10
  done
  echo "DC services not running after 10 minutes" >&2; return 1
}
signout_all() {
  L pscmd cl01 'quser 2>$null | Select-Object -Skip 1 | ForEach-Object { if ($_ -match "\s(\d+)\s+(Active|Disc)") { logoff.exe $Matches[1] } }' >/dev/null 2>&1 || true
  sleep 8
}
signin() { # signin <DOMAIN\user> <secret> [new-secret]  - console sign-in; new-secret = first sign-in password change
  L keys cl01 ctrl-alt-delete >/dev/null; sleep 5
  L type cl01 --text "$1" >/dev/null; L keys cl01 tab >/dev/null
  L type cl01 --secret "$2" --enter >/dev/null; sleep 8
  if [[ -n "${3:-}" ]]; then
    shot cl01 signin-must-change
    L keys cl01 ret >/dev/null; sleep 4                       # "password must be changed" -> OK
    L type cl01 --secret "$3" >/dev/null; L keys cl01 tab >/dev/null
    L type cl01 --secret "$3" --enter >/dev/null; sleep 6
    shot cl01 signin-password-changed
    L keys cl01 ret >/dev/null                                # "Your password has been changed" -> OK
  fi
  local sam="${1#*\\}"
  for _ in $(seq 40); do
    L pscmd cl01 'quser 2>$null | Out-String' 2>/dev/null | grep -qi "$sam.*Active" && { sleep 45; return 0; }
    sleep 5
  done
  echo "sign-in of $1 did not complete" >&2; return 1
}

case "$stage" in
  prepare)
    L init-secrets
    "$HERE/build-config-iso.sh" dc01
    "$HERE/build-config-iso.sh" cl01 ;;

  install)
    vm="${1:?dc01|cl01}"
    "$HERE/vm.sh" install "$vm"
    L wait-agent "$vm" --timeout 3600
    "$HERE/vm.sh" stop "$vm"           # detach setup media; DC01 also gets its data/backup disks
    "$HERE/vm.sh" start "$vm"
    L wait-agent "$vm" --timeout 900
    L push "$vm" "$LAB_REPO_ROOT/scripts" 'C:\LabSetup' ;;

  dc01)
    L push dc01 "$LAB_REPO_ROOT/scripts" 'C:\LabSetup'
    run dc01 dc01-01-initialize        ps dc01 --timeout 2400 'server\01-Initialize-DC01.ps1'
    run dc01 dc01-02-install-adforest  ps dc01 --timeout 1800 --secrets DSRM_PASSWORD 'server\02-Install-ADForest.ps1'
    sleep 60; L wait-agent dc01 --timeout 1200; wait_dc_services
    run dc01 dc01-03-new-labdirectory  ps dc01 --timeout 1200 --secrets STAFF_INITIAL_PASSWORD 'server\03-New-LabDirectory.ps1'
    run dc01 dc01-04-shares            ps dc01 --timeout 900 'server\04-New-DepartmentShares.ps1'
    run dc01 dc01-05-gpo               ps dc01 --timeout 900 'server\05-New-DriveMapGpo.ps1' ;;

  cl01)
    L push cl01 "$LAB_REPO_ROOT/scripts" 'C:\LabSetup'
    run cl01 cl01-01-initialize        ps cl01 --timeout 900 'client\01-Initialize-CL01.ps1'
    run cl01 cl01-02-join              ps cl01 --timeout 600 --secrets DC01_ADMIN_PASSWORD 'client\02-Join-LabDomain.ps1'
    sleep 60; L wait-agent cl01 --timeout 900; sleep 45
    run cl01 cl01-03-membership        ps cl01 --timeout 600 'client\03-Test-DomainMembership.ps1' ;;

  backup)
    run dc01 dc01-06-file-recovery     ps dc01 --timeout 1800 'server\06-Invoke-FileRecoveryDemo.ps1' ;;

  ticket1)
    given="${1:?Given}"; surname="${2:?Surname}"; dept="${3:?Finance|Operations}"; ticket="${4:?TicketId}"
    sam="$(echo "$given.$surname" | tr '[:upper:]' '[:lower:]')"
    L push dc01 "$LAB_REPO_ROOT/scripts" 'C:\LabSetup' >/dev/null
    L push cl01 "$LAB_REPO_ROOT/scripts" 'C:\LabSetup' >/dev/null
    run dc01 t1-1-create-account ps dc01 --timeout 600 --secrets ONBOARD_INITIAL_PASSWORD \
      'server\10-New-OnboardingUser.ps1' -GivenName "$given" -Surname "$surname" -Department "$dept" -TicketId "$ticket"
    signout_all
    log "cl01: first sign-in of SMALLBIZ\\$sam (temporary password, forced change)"
    signin "SMALLBIZ\\$sam" ONBOARD_INITIAL_PASSWORD ONBOARD_NEW_PASSWORD
    shot cl01 t1-desktop
    log "cl01: access checks inside the user's session"
    in_user "SMALLBIZ\\$sam" 'client\10-Test-DepartmentAccess.ps1' "-Label $ticket" 2>&1 | tee "$OUT/t1-2-user-access.txt"
    grep -q 'failed: 0\|, 0 failed' "$OUT/t1-2-user-access.txt" && log "TICKET 1: PASS" || { log "TICKET 1: FAIL"; exit 1; } ;;

  ticket2)
    sam="${1:?sam}"; dept="${2:?Finance|Operations}"; ticket="${3:?TicketId}"
    L push cl01 "$LAB_REPO_ROOT/scripts" 'C:\LabSetup' >/dev/null
    run cl01 t2-0-baseline     ps cl01 --timeout 400 'client\21-Get-DnsDiagnostics.ps1'
    run cl01 t2-1-inject-fault ps cl01 --timeout 300 'client\20-Set-DnsFault.ps1'
    log "cl01: reboot (the user arrives the next morning)"
    L pscmd cl01 'shutdown.exe /r /t 5 /c "next morning"' >/dev/null
    sleep 60; L wait-agent cl01 --timeout 900; sleep 20
    signin "SMALLBIZ\\$sam" ONBOARD_NEW_PASSWORD
    in_user "SMALLBIZ\\$sam" 'client\10-Test-DepartmentAccess.ps1' "-Label $ticket-broken -ExpectedDepartment $dept" 2>&1 | tee "$OUT/t2-2-user-symptom.txt"
    run cl01 t2-3-diagnose     ps cl01 --timeout 400 'client\21-Get-DnsDiagnostics.ps1'
    run cl01 t2-4-repair       ps cl01 --timeout 400 'client\22-Repair-ClientDns.ps1'
    # Observed: a gpupdate in the first seconds after the repair can still miss the DC, so the
    # drive is re-checked and the refresh repeated (up to 3 times, 45 s apart).
    for attempt in 1 2 3; do
      L ps cl01 --timeout 300 'client\tools\Invoke-InUserSession.ps1' -User "SMALLBIZ\\$sam" -Program gpupdate.exe -ProgramArgs '/target:user /force' -TimeoutSec 240 >/dev/null
      in_user "SMALLBIZ\\$sam" 'client\10-Test-DepartmentAccess.ps1' "-Label $ticket-fixed -ExpectedDepartment $dept" 2>&1 | tee "$OUT/t2-5-user-after-fix-attempt$attempt.txt"
      grep -q ', 0 failed' "$OUT/t2-5-user-after-fix-attempt$attempt.txt" && { log "TICKET 2: PASS (user policy refresh attempt $attempt)"; break; }
      [[ $attempt == 3 ]] && { log "TICKET 2: FAIL"; exit 1; }
      log "drive not mapped yet - waiting 45 s before refreshing user policy again"; sleep 45
    done ;;

  verify)
    run dc01 verify-dc01 pscmd dc01 --timeout 300 'Import-Module ActiveDirectory, GroupPolicy; Get-Service ADWS,DNS,Netlogon,NTDS,LanmanServer | ft -a Name,Status; $g = Get-GPO -Name SB-U-DepartmentDriveMaps; "GPO user DS/Sysvol {0}/{1}, computer DS/Sysvol {2}/{3}" -f $g.User.DSVersion,$g.User.SysvolVersion,$g.Computer.DSVersion,$g.Computer.SysvolVersion; Get-SmbShareAccess Finance,Operations | ft -a Name,AccountName,AccessRight; Get-ADGroupMember GG_Finance | ft -a SamAccountName; Get-ADGroupMember GG_Operations | ft -a SamAccountName; dcdiag /test:Advertising /test:Services /test:NetLogons /q; "dcdiag exit code: $LASTEXITCODE"'
    run cl01 verify-cl01 ps cl01 --timeout 600 'client\03-Test-DomainMembership.ps1' ;;

  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
log "stage '$stage' done - output in $OUT"
