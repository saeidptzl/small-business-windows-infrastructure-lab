# Test results

Reference run: **13 November 2026**, Ubuntu 26.04 host, QEMU/KVM 10.2.1.
Status values: **PASS** (observed = expected), **FAIL** (observed ≠ expected), **PENDING** (not run),
**INFO** (observation, not a pass/fail test). Every row links to the sanitised output it is based on.
All accounts and data are synthetic.

## Summary

| Area | PASS | FAIL (final) | PENDING | Notes |
|---|---|---|---|---|
| Build: DC01, AD, shares, GPO | 7 | 0 | 0 | |
| Build: CL01, domain join, isolation | 5 | 0 | 0 | two manual console actions during install, see B-07 |
| Ticket 1 – onboarding | 7 | 0 | 0 | Finance hire (manual) + Operations hire (scripted) |
| Ticket 2 – DNS incident | 7 | 0 | 0 | 3 intermediate failures found and fixed, kept below |
| File backup / recovery | 5 | 0 | 0 | single file, see scope |
| Reproducibility | 3 | 0 | 2 | full re-install from scratch not re-run |

## Build and infrastructure

| ID | Test | Expected | Observed | Status | Evidence |
|---|---|---|---|---|---|
| B-01 | Unattended install of DC01 | Windows Server 2025 Standard Evaluation, Server Core | `Windows Server 2025 Standard Evaluation`, build 26100 | **PASS** | [licence/OS](../evidence/logs/build/09-licence-status.txt), [SConfig](../evidence/screenshots/00-dc01-sconfig-server-core.png) |
| B-02 | DC01 baseline | static 10.10.50.10/24, no gateway; D: Data, E: Backup; roles installed | as expected; AD-Domain-Services, DNS, FS-FileServer, GPMC, Windows-Server-Backup *Installed* | **PASS** | [01](../evidence/logs/build/01-dc01-initialize.txt) |
| B-03 | New forest `corp.smallbiz.test` | prerequisite check + promotion succeed | both *Success*; domain mode `Windows2025Domain` | **PASS** | [02](../evidence/logs/build/02-dc01-install-adforest.txt) |
| B-04 | OUs, AGDLP groups, synthetic staff | 6 OUs, GG→DL nesting, 4 users in department OUs | as expected; `redircmp` to OU=Workstations | **PASS** | [03](../evidence/logs/build/03-dc01-new-labdirectory.txt) |
| B-05 | Shares + permissions | share: Admins Full + DL group Change; NTFS: no inheritance, DL group Modify; ABE on | as expected (`Get-SmbShareAccess`, `icacls`) | **PASS** | [04](../evidence/logs/build/04-dc01-departmentshares.txt) |
| B-06 | Drive-map GPO | created, linked to OU=SmallBiz, F:/O: with group targeting, AD/SYSVOL versions equal | user 1/1, computer 1/1, link enabled | **PASS** | [05](../evidence/logs/build/05-dc01-drivemapgpo.txt), [GPO report](../evidence/logs/build/05-gpo-report-SB-U-DepartmentDriveMaps.html) |
| B-07 | Unattended install of CL01 | Windows 11 Enterprise LTSC 2024 Evaluation with Secure Boot + vTPM | installed and reached the desktop. Two manual console actions: Enter at the firmware boot menu (first boot) and a restart without the install ISO after the join (VM stuck in firmware) | **PASS** (with notes) | [OS](../evidence/logs/build/09-licence-status.txt) |
| B-08 | CL01 network + DC reachability | TCP 53/389/445 open; A and SRV records resolve | as expected | **PASS** | [06](../evidence/logs/build/06-cl01-initialize.txt) |
| B-09 | Domain join | member of the domain in OU=Workstations, secure channel, DC locator, GPO applied | DJ-01…DJ-04 PASS | **PASS** | [08](../evidence/logs/build/08-cl01-domain-membership.txt) |
| B-10 | Network isolation | no default route; host LAN and Internet unreachable; host has no route/TAP to the lab | 0 default routes; 192.168.1.1 and 1.1.1.1 unreachable; host: no TAP/bridge, no reply from 10.10.50.10 | **PASS** | [10](../evidence/logs/build/10-network-isolation-check.txt) |
| B-11 | Domain controller health | `dcdiag /test:Advertising /test:Services /test:NetLogons` clean | exit code 0, no errors printed | **PASS** | [verify](../evidence/logs/verify/verify-dc01.txt) |
| B-12 | Autologon left by setup | sign-in screen after reboot | **observed:** CL01 still had `AutoAdminLogon=1` and signed the local admin in after a reboot → baseline script now disables it; re-run confirmed `AutoAdminLogon=0` | **PASS** (after fix) | [06b](../evidence/logs/build/06b-cl01-initialize-rerun-autologon-fix.txt) |
| B-13 | Evaluation licences | – | DC01: initial grace period, 10 days left. **CL01: `Notification` mode, 0xC004F009 (grace time expired)** right after the offline install; watermark "Windows License is expired" | **INFO** | [09](../evidence/logs/build/09-licence-status.txt) |

## Ticket 1 – new employee onboarding

| ID | Test | Expected | Observed | Status | Evidence |
|---|---|---|---|---|---|
| T1-01 | Create account (LAB-1001) | `elena.marini` in OU=Finance, only `GG_Finance`, must change password | as expected; access chain OK; not in GG_Operations | **PASS** | [log](../evidence/logs/ticket1-onboarding/LAB-1001-1-dc01-create-account-elena.marini.txt) |
| T1-02 | First interactive sign-in on CL01 | forced password change, then desktop | prompts shown, password changed, session active | **PASS** | [1](../evidence/screenshots/t1-02-must-change-password.png), [2](../evidence/screenshots/t1-03-password-changed.png) |
| T1-03 | `F:` mapped by the GPO | `F: → \\DC01.corp.smallbiz.test\Finance` | as expected | **PASS** | [log](../evidence/logs/ticket1-onboarding/LAB-1001-2-cl01-user-session-checks-elena.marini.txt), [This PC](../evidence/screenshots/t1-04-this-pc-finance-drive.png) |
| T1-04 | Own share via UNC | list + create/delete file OK | OK | **PASS** | same log |
| T1-05 | Other department drive | `O:` not mapped | not mapped | **PASS** | same log |
| T1-06 | Other department share via UNC | Access denied | `Access is denied.` | **PASS** | same log, [console](../evidence/screenshots/t1-05-user-console-operations-denied.png) |
| T1-07 | Mirror case, scripted (LAB-1003, `paolo.russo`, Operations) | O: mapped, Operations OK, Finance denied | 5/5 checks PASS, sign-in and password change done by `run-lab.sh` | **PASS** | [account](../evidence/logs/ticket1-onboarding/LAB-1003-1-dc01-create-account-paolo.russo.txt), [user](../evidence/logs/ticket1-onboarding/LAB-1003-2-cl01-user-session-checks-paolo.russo.txt) |

## Ticket 2 – DNS incident

| ID | Test | Expected | Observed | Status | Evidence |
|---|---|---|---|---|---|
| T2-01 | Healthy baseline | 7/7 diagnostics PASS | 7/7 PASS | **PASS** | [log](../evidence/logs/ticket2-dns-incident/LAB-1002-0-baseline-diagnostics.txt) |
| T2-02 | Inject the fault | DNS on LAB = 8.8.8.8 | before 10.10.50.10 → after 8.8.8.8 | **PASS** | [log](../evidence/logs/ticket2-dns-incident/LAB-1002-1-inject-fault.txt) |
| T2-03 | Reproduce after reboot + sign-in | user signs in (cached), no F:, UNC "network path not found" | as expected; 4 of 5 user checks fail as intended | **PASS** (failure reproduced) | [log](../evidence/logs/ticket2-dns-incident/LAB-1002-2-user-symptom.txt), [screen](../evidence/screenshots/t2-01-user-symptom-network-path-not-found.png) |
| T2-04 | Client-side diagnosis | wrong DNS identified; DC reachable by IP; AD DNS answers directly | D-01/03/04/05/07 FAIL, D-02/06 PASS → root cause printed | **PASS** | [log](../evidence/logs/ticket2-dns-incident/LAB-1002-3-diagnostics.txt), [screen](../evidence/screenshots/t2-02-client-side-diagnostics.png) |
| T2-05a | Repair, first attempt | R-01…R-04 PASS | DNS fixed, **R-04 secure channel False** (`ERROR_NO_LOGON_SERVERS` cached by Netlogon) | **FAIL** → script fixed | [4a](../evidence/logs/ticket2-dns-incident/LAB-1002-4a-repair-first-attempt-R04-FAIL.txt), [4b](../evidence/logs/ticket2-dns-incident/LAB-1002-4b-secure-channel-check.txt) |
| T2-05 | Repair with `nltest /sc_reset` | R-01…R-04 PASS | 4/4 PASS | **PASS** | [4c](../evidence/logs/ticket2-dns-incident/LAB-1002-4c-repair-with-sc-reset.txt) |
| T2-06 | User verification after fix | F: back, Finance OK, Operations denied | 5/5 PASS after `gpupdate /target:user /force` | **PASS** | [log](../evidence/logs/ticket2-dns-incident/LAB-1002-5-user-after-fix.txt), [screen](../evidence/screenshots/t2-03-after-fix.png) |
| T2-07 | Whole ticket scripted (LAB-1004, `paolo.russo`) | `run-lab.sh ticket2` ends with TICKET 2: PASS | PASS on the 3rd run. Run 1: R-04 FAIL (`/sc_reset` in the same second as the DNS change → rediscovery + retry added). Run 2: drive not remapped by one immediate `gpupdate` (UNC already OK) → retry added. Run 3: PASS, drive mapped on refresh attempt 2 | **PASS** | [runner logs](../evidence/logs/ticket2-dns-incident/) (`LAB-1004-runner-*`) |

## File backup and recovery

| ID | Test | Expected | Observed | Status |
|---|---|---|---|---|
| BR-01 | One-time wbadmin backup of the sample file to E: | success, version listed | `11/13/2026-00:31` (UTC) | **PASS** |
| BR-02 | Simulated overwrite | hash changes | `8A02E58E…` ≠ `92B9803F…` | **PASS** |
| BR-03 | Restore to alternate location | file under `D:\RecoveryTest\<timestamp>` | `D:\RecoveryTest\20261113-013146\Budget-2026-Q1-SAMPLE.csv` | **PASS** |
| BR-04 | Recovered hash = original | identical SHA-256 | `92B9803F…9611` both | **PASS** |
| BR-05 | File back in the share | hash = original | identical | **PASS** |

Evidence: [`dc01-file-recovery-demo.txt`](../evidence/logs/file-recovery/dc01-file-recovery-demo.txt) · Scope: [RB-03](runbooks/RB-03-file-recovery.md).

## Reproducibility

| ID | Test | Status | Notes |
|---|---|---|---|
| R-01 | `run-lab.sh ticket1` end to end | **PASS** | LAB-1003 |
| R-02 | `run-lab.sh ticket2` end to end | **PASS** | LAB-1004 (3rd run, see T2-07) |
| R-03 | `run-lab.sh verify` | **PASS** | [dc01](../evidence/logs/verify/verify-dc01.txt), [cl01](../evidence/logs/verify/verify-cl01.txt) |
| R-04 | `run-lab.sh prepare / install / dc01 / cl01 / backup` as single stages | **PENDING** | the same commands were run one by one on the reference host, not through these stages |
| R-05 | Fresh install with the final `vm.sh` boot-key handling (Enter for 30 s) | **PENDING** | changed after the reference install; not re-run |
