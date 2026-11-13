# KrbtgtRotation

Attended KRBTGT rotation for a fixed, two-domain-controller Active Directory
environment. Built for Windows PowerShell 5.1 with explicit safety gates,
structured evidence, and mocked Pester tests.

The tool has been successfully used in production on multiple occasions.
See the [verification record](docs/verification.md) for production-use status
and the scope of automated checks.

KrbtgtRotation is a small Windows PowerShell 5.1 tool for attended, routine
rotation of the current domain's built-in `krbtgt` account in one narrowly
approved profile:

- one air-gapped, single-domain enclave per run;
- exactly two writable Windows Server 2022 domain controllers;
- no RODCs, cloud integration, remote forest, alternate credentials, remoting,
  scheduling, self-elevation, or unattended execution;
- Reset 1 and Reset 2 run manually on the same selected DC as the current
  signed-in Domain Admin;
- the effective maximum TGT lifetime is exactly 10 hours.

The tool is for routine rotation only. It is not an incident-response,
compromise-recovery, or forest-recovery tool.

## Repository location

This package is maintained under `windows/reset-krbtgt` in CSfC scripts.
It was imported from reset-krbtgt revision `ff5260e`. Keep its scripts, module,
schemas, tools, and runbooks together. Run package-relative commands from this
folder, not the CSfC repository root. No nested Git repository is required.

The source repository has an unresolved report of a Test-flow failure. See
[known limitations](docs/security-and-limitations.md#open-source-issue).
This relocation does not resolve that report or establish new lab validation.

## Safety model

The operator performs four distinct flows: read-only **Preflight**,
state-changing temporary-user **Test**, **Reset 1**, and—after at least 11
hours—**Reset 2**. Fresh Preflight and Test receipts are mandatory before each
reset and expire after 30 minutes. Replication and cleanup deadlines are fixed
at five minutes. There is no bypass, retry switch, alternate credential,
automatic rollback, or corrective write.

Production validates only the current domain object whose `sAMAccountName` is
exactly `krbtgt`, whose SID is the current domain SID plus RID 502, and whose
GUID, SID, DN, disabled state, and `pwdLastSet` metadata agree on both DCs. Each
reset invocation contains one `Set-ADAccountPassword` call, then one targeted
`Sync-ADObject` call and two-DC metadata verification.

Native `-WhatIf` is a directory-read-only preview. It still reads all health and
receipt gates and writes the required local System event and JSON receipt; it
does not replace Preflight or Test.

## Start here

1. Read [Security and limitations](docs/security-and-limitations.md).
2. Follow [Installation](docs/installation.md), including SHA-256 verification
   and the one-time local setup on each DC.
3. Execute only from [Operator runbook](docs/operator-runbook.md).
4. On any anomaly, stop and use [Troubleshooting and escalation](docs/troubleshooting-and-escalation.md).

Additional references:

- [Architecture decisions](docs/architecture-decisions.md)
- [Event and receipt reference](docs/event-and-receipt-reference.md)
- [Verification record](docs/verification.md)
- [Receipt JSON Schema](schemas/receipt.schema.json)
- [Event payload JSON Schema](schemas/event.schema.json)

## Package layout

```text
Install-KrbtgtRotation.ps1       one-time local setup, run separately on each DC
Invoke-KrbtgtPreflight.ps1       strictly AD-read-only health gate
Invoke-KrbtgtTest.ps1            explicit temporary-user mutation and cleanup test
Invoke-KrbtgtReset.ps1           exactly one Reset1 or Reset2 operation; supports -WhatIf
KrbtgtRotation/                  testable module
schemas/                         JSON receipt/event contracts and event catalog
tests/                           mocked Pester tests and inert fixtures
tools/                           offline verification and hash utilities
SHA256SUMS.txt                   published air-gap integrity hashes
```

## Non-features

The package never installs prerequisites, changes execution policy, modifies or
refreshes Group Policy, remotes through PowerShell, stores credentials, schedules
work, contacts the Internet/cloud, downloads dependencies, sends mail, creates a
rollback password, or deletes/compresses evidence.

All runtime evidence stays on the executing DC under
`%ProgramData%\KrbtgtRotation\Receipts` and in the classic **System** event log
under source `KrbtgtRotation`.

## Development

Use Windows PowerShell 5.1 with Pester 3.4.0 and PSScriptAnalyzer 1.25.0.
Verification runs on a development workstation without AD RSAT or a domain
controller; directory operations are mocked.

```powershell
.\tools\Invoke-ReleaseVerification.ps1
```

This checks release hashes, PowerShell syntax, the configured analyzer rules,
and the mocked test suite. It never installs dependencies. The standalone
repository's GitHub Actions workflow is not included in this package;
CSfC-wide automation is configured separately.

See [Contributing](CONTRIBUTING.md) for the branch, validation, and release
workflow. See [Verification](docs/verification.md) for what the checks establish
and which checks depend on the target environment.
