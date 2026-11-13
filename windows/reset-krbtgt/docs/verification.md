# Verification record

## Production use

The maintainer confirmed on October 19, 2026 that the tool has been used in
production multiple times and validated as working. This records operational
experience separately from the automated checks below.

## Local release gates

The release is checked with:

```powershell
.\tools\Test-ReleaseHashes.ps1
# Only after intentional package edits and source review:
.\tools\New-ReleaseHashes.ps1
.\tools\Invoke-ReleaseVerification.ps1
```

The development workstation used Windows PowerShell 5.1 parsing/import, Pester
3.4.0, and PSScriptAnalyzer 1.25.0. The test source uses syntax compatible with
the installed Pester 3.4.0 runner.

The release gate requires:

- zero parser errors across the publication manifest's PowerShell files;
- zero findings from `PSScriptAnalyzerSettings.psd1`;
- all mocked Pester tests passing;
- all JSON schemas/fixtures parsing;
- no prohibited web/download/mail/remoting/scheduling/execution-policy/GPO
  commands in implementation source;
- every publication-manifest file present and matching `SHA256SUMS.txt`.

The final local run completed with **24 passed, 0 failed**, zero parser errors,
and zero configured analyzer findings. `AdIntegrationTestsExecuted` is `False`
for this automated gate because it does not connect to Active Directory.

## Import into CSfC scripts

The package was imported from source revision `ff5260e`. The runtime module
and operator entry scripts were not changed, except for repository metadata.
Source checks and past operational statements below are historical evidence,
not a new AD validation claim. Live/lab validation remains deferred for this
import, and the original Test-flow failure report remains unresolved.

## Original repository continuous integration

The original repository's `Verify` GitHub Actions workflow runs the release gate on Windows Server
2022 with Windows PowerShell 5.1, Pester 3.4.0, and PSScriptAnalyzer 1.25.0.
It checks committed hashes without regenerating them. CI downloads development
dependencies on the hosted runner; the offline package never does so.
Checks establish static and mocked properties only, with no AD deployment.

## Mocked behaviors

Pester verifies:

- Preflight calls no AD-changing adapter;
- native Reset 1 `-WhatIf` requests no typed confirmation and calls no AD-changing adapter;
- a successful Reset 1 calls the password adapter exactly once and targeted
  replication exactly once;
- password-write failure prevents replication and post-checks;
- convergence failure prevents post-checks;
- nonexact typed confirmation prevents mutation;
- Test creates one temporary user, calls the shared password adapter once, uses
  the targeted replication path, deletes the user, and verifies cleanup;
- Test password failure stops before deletion/corrective action;
- a 30-minute-old prerequisite receipt is rejected;
- metadata advancement other than exactly one version is rejected;
- effective Kerberos policy is obtained on both DC paths without requesting
  policy-file keys as LDAP attributes;
- inconsistent effective Kerberos policy between DCs is rejected;
- Reset 2 timing, receipt identity, anomaly, and intervening-mutation gates.

## Inert fixtures

`tests/fixtures` contains fictional `.example` domain data only:

- a successful two-DC Preflight profile;
- an extra-DC profile that must fail without writes;
- a Reset 1 convergence timeout that must fail, prohibit Reset 2, and avoid rollback.

They support a novice desk-check and are not a simulated directory. Expected
walkthrough:

1. Read `preflight-success.json`; verify exactly two writable Server 2022 DCs,
   RID 502, 600-minute TGT lifetime, and zero expected writes.
2. Read `preflight-blocked-extra-dc.json`; verify three DCs produces failure,
   not an exclusion prompt.
3. Read `reset1-convergence-timeout.json`; verify a completed password call plus
   stale destination metadata is still failure and cannot trigger rollback.

## Requirements-to-check mapping

| Requirement | Local evidence |
|---|---|
| Exactly one production password call | Mock call-count test and source review |
| No AD writes in Preflight/WhatIf | Zero-call mock assertions |
| Fail immediately after write failure | No replication/post-check mock assertions |
| Five-minute bounds | Fixed module constants; no public timeout parameter; timeout fixture |
| 30-minute receipts | Receipt-age unit test and fixed constant |
| 11-hour Reset 2 wait | Reset 2 unit tests and fixed constant |
| Exact RID-502 target | SID/GUID/DN validation source review and target unit tests |
| No rollback or unrelated features | Prohibited-command scan and source review |
| Durable local evidence | Receipt/event schemas and mocked writer boundary |

## Environment-specific checks

Password acceptance, temporary-user tombstone behavior, metadata values,
replication deadlines, DC diagnostics/localization, ACL enforcement, event-log
retention, application authentication, and recovery depend on the target
environment. Check them under the responsible AD authority's change process.
Automated checks supplement the confirmed production use; they do not execute
AD integration tests or establish compatibility with additional topologies.
