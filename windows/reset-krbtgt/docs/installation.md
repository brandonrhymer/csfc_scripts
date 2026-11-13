# Installation

## Operational approval

The tool has been successfully used in production on multiple occasions.
Follow the responsible AD authority's change process and confirm the target
environment meets the supported profile before using any state-changing phase.

## Fixed prerequisites

Each in-scope enclave must meet every item:

- one AD forest/domain for this invocation;
- exactly two writable DCs, both Windows Server 2022, both online;
- no RODCs or cloud/Entra Kerberos integration;
- Microsoft Windows PowerShell 5.1 Desktop edition on both DCs;
- Microsoft `ActiveDirectory` module and `dcdiag.exe` already installed;
- working DNS, ADWS, KDC, time, RPC/LSA policy access, and replication services;
- effective domain `MaxTicketAge` of exactly 10 hours and readable consistent
  Kerberos/default-domain password policy on both DCs (Kerberos intervals are
  read through the Windows LSA policy API used by the KDC);
- an interactive current-domain Domain Admin account;
- a Windows PowerShell session already started with **Run as administrator**.

The package will not install, repair, or change any prerequisite.

## Verify the transferred package

Transfer the complete windows/reset-krbtgt package through the enclave's approved media-handling
process. From the release root in Windows PowerShell 5.1, run:

```powershell
.\tools\Test-ReleaseHashes.ps1
```

The result must be `Succeeded` with zero missing, unexpected, or mismatched
files. Compare `SHA256SUMS.txt` with the value published in the source repository
through a separately trusted path if enclave procedure requires it. Stop if any
hash differs.

## Execution policy

The package never calls `Set-ExecutionPolicy`, edits policy registry keys, or
relaunches itself. Group Policy remains authoritative. If enclave policy
explicitly permits an operator-selected process-only bypass, start a separate
session yourself:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass
```

This example affects only that new process; it is not an instruction to weaken
enclave policy. If policy blocks the package, stop and use the enclave's approved
application-control process.

## One-time local setup on each DC

The event source registration is local machine state. Sign in and run the setup
separately on **each** of the two DCs—do not use remoting:

```powershell
Set-Location 'C:\ApprovedPath\reset-krbtgt'
.\Install-KrbtgtRotation.ps1
```

Review the native confirmation before accepting it. The command:

- registers classic event source `KrbtgtRotation` in the existing System log;
- creates `%ProgramData%\KrbtgtRotation\Receipts`;
- protects that directory from inherited ACLs and grants FullControl only to
  local Administrators and SYSTEM;
- writes System event ID 900.

It does not contact the other DC. Repeat the command while locally signed into
the second DC.

Verify locally on each DC:

```powershell
[Diagnostics.EventLog]::LogNameFromSourceName('KrbtgtRotation', '.')
Get-Acl "$env:ProgramData\KrbtgtRotation\Receipts" | Format-List Owner,AreAccessRulesProtected,Access
Get-EventLog -LogName System -Source KrbtgtRotation -Newest 1
```

Expected results are `System`, protected inheritance, Administrators/SYSTEM
FullControl only, and event 900. Runtime Preflight fails closed if the event
source or receipt ACL is absent or wrong.

## Developer-only verification dependencies

Pester and PSScriptAnalyzer are not runtime dependencies and are never
downloaded by the package. A review workstation that already has approved local
copies can run:

```powershell
.\tools\Invoke-ReleaseVerification.ps1
```

The published verification record identifies the versions used for this release.
