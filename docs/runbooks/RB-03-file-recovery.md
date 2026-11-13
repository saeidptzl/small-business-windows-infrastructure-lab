# RB-03 · Restore a single file from Windows Server Backup

| | |
|---|---|
| **Ticket type** | Incident: "I saved over the Q1 budget file in the Finance share" |
| **System** | DC01 (file server role), backup volume `E:` |
| **Who** | IT technician (Administrators or Backup Operators on DC01) |
| **Reference run** | 13 Nov 2026, 5/5 checks **PASS** |

## Scope (read this first)

This lab demonstrates the **restore procedure and its verification** for one file:

* one-time Windows Server Backup job of a single file to a second virtual disk (`E:`) on the **same** VM;
* restore to an **alternate location**, then SHA-256 comparison with the original;
* the recovered file is copied back only after the hashes match.

It is **not** a backup strategy. There is no schedule, retention, off-site or offline/immutable copy
(3-2-1), no system-state / Active Directory backup and no bare-metal recovery. The backup disk lives
on the same host as the data, so a host failure or ransomware on the host loses both.
A production design would add scheduled backups (VSS-aware), an off-site/immutable copy, a
system-state backup of the DC, and regular restore tests.

## Automated demo

```powershell
# DC01, elevated
C:\LabSetup\server\06-Invoke-FileRecoveryDemo.ps1
```

## Manual procedure (what the script does)

```powershell
$file = 'D:\Shares\Finance\Budget-2026-Q1-SAMPLE.csv'

# 0. (normally done by the backup schedule) one-time backup of the file to E:
Get-FileHash $file -Algorithm SHA256            # record the original hash
wbadmin start backup -backupTarget:E: -include:$file -quiet

# 1. Find the version to restore (identifier is in UTC)
wbadmin get versions -backupTarget:E:

# 2. Restore to an ALTERNATE location - never straight over the live file
wbadmin start recovery -version:11/13/2026-00:31 -itemType:File -items:$file `
        -backupTarget:E: -recoveryTarget:D:\RecoveryTest\20261113 -overwrite:CreateCopy -quiet

# 3. Verify integrity before handing it back
Get-FileHash D:\RecoveryTest\20261113\Budget-2026-Q1-SAMPLE.csv -Algorithm SHA256

# 4. Hashes match -> put it back (or give the user the copy to compare)
Copy-Item D:\RecoveryTest\20261113\Budget-2026-Q1-SAMPLE.csv $file -Force
```

Why an alternate location: the user may have made valid changes after the backup; restoring
side by side lets them compare, and it never destroys the current file by mistake.

## Reference result

```text
original  SHA-256 92B9803F99A8B93D71B52DC2647EB8C599450E100FBFF1DBCFD0DF5BA03D9611
damaged   SHA-256 8A02E58E22FADD5F707B0BCCF1B419ED2082F11DD11A672319803669EA5600FC
recovered SHA-256 92B9803F99A8B93D71B52DC2647EB8C599450E100FBFF1DBCFD0DF5BA03D9611

BR-01 Backup job completed           PASS
BR-02 Damage simulated               PASS   (hash differs from original)
BR-03 Restore to alternate location  PASS   (D:\RecoveryTest\20261113-013146\Budget-2026-Q1-SAMPLE.csv)
BR-04 Recovered hash = original hash PASS
BR-05 File back in the share         PASS
```

Full log: [`evidence/logs/file-recovery/dc01-file-recovery-demo.txt`](../../evidence/logs/file-recovery/dc01-file-recovery-demo.txt)

## Notes

* `wbadmin get versions` prints the identifier in **UTC**; the backup time is shown in local time.
* The restored file keeps its NTFS ACL (only `DL_FS_Finance_Modify` + admins), so the copy in
  `D:\RecoveryTest` is not exposed to other departments. Delete the restore folder when done.
* Windows Server Backup is a role feature (`Install-WindowsFeature Windows-Server-Backup`); the
  same commands work on Server Core and Desktop Experience.
