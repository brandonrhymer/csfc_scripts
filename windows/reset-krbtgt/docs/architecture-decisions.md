# Architecture decisions

## ADR-001: Clean-room task-focused implementation

**Decision:** Implement an original small Windows PowerShell 5.1 module and thin
operator scripts. Do not copy or adapt the upstream GPL implementation.

**Reason:** A narrow trust boundary is reviewable and maps directly to supported
Microsoft commands. The product uses [`Set-ADAccountPassword`](https://learn.microsoft.com/en-us/powershell/module/activedirectory/set-adaccountpassword?view=windowsserver2025-ps),
[`Sync-ADObject`](https://learn.microsoft.com/en-us/powershell/module/activedirectory/sync-adobject?view=windowsserver2025-ps), and
[`Get-ADReplicationAttributeMetadata`](https://learn.microsoft.com/en-us/powershell/module/activedirectory/get-adreplicationattributemetadata?view=windowsserver2025-ps).

## ADR-002: Fixed two-writable-DC profile

**Decision:** Fail unless discovery returns exactly two writable Windows Server
2022 DCs and no RODC.

**Reason:** Missing or skipped DCs make the two-key sequence unsafe. Supporting
additional topologies would require separate design and representative
validation. There is no expected-DC exclusion or topology override.

## ADR-003: Exact built-in target allowlist

**Decision:** Target only `sAMAccountName=krbtgt` with current-domain SID plus RID
502, then cross-check GUID/SID/DN/disabled state and metadata independently on
both DCs.

**Reason:** Name-only selection can represent the wrong directory identity.
Production accepts neither `krbtgt_<number>` nor `krbtgt_AzureAD` patterns.

## ADR-004: Explicit phase receipts

**Decision:** Bind Preflight, Test, and one reset phase to a GUID operation ID,
domain, execution DC, and operator. Preflight/Test receipts expire after 30
minutes. Reset 2 requires the explicit protected-local Reset 1 receipt.

**Reason:** The reset must not infer readiness from console history or stale
state. Reset 1 and Reset 2 use separate operation IDs because each needs a fresh
Preflight/Test pair.

## ADR-005: Temporary-user Test uses production adapters

**Decision:** Test creates one uniquely named disabled user, replicates it,
resets its password through the same internal adapter, verifies metadata,
deletes it, replicates the deleted object, and verifies live absence on both DCs.

**Reason:** This is an explicit state-changing proof of the intended supported
command path without modifying `krbtgt`. It is separate from read-only Preflight
and WhatIf. Any stage failure stops immediately; later cleanup is not attempted
as an unapproved corrective action.

## ADR-006: Exactly one write and bounded convergence

**Decision:** One reset invocation performs one password call. Source metadata
must increment exactly once, then one-object replication is forced to the second
DC and exact origin/version metadata is polled for at most five minutes.

**Reason:** Microsoft documents single-object replication through
`Sync-ADObject`. A deadline converts nonconvergence into a deterministic failure
instead of an unbounded privileged session.

## ADR-007: Fail-closed policy and time

**Decision:** Query each DC's effective Kerberos intervals through the read-only
Windows LSA policy API (`LsaQueryDomainInformationPolicy`) and read the
default-domain password policy from each DC. Values must be readable and
identical, and `MaxTicketAge` must be exactly 10 hours. Reset 2 requires 11
elapsed UTC hours with no bypass. Kerberos policy-file keys such as
`MaxServiceAge` are not treated as LDAP attributes.

**Reason:** Microsoft documents a default 10-hour maximum user-ticket lifetime
and describes the policy fields in [MS-GPSB Kerberos Policy](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpsb/0fce5b92-bcc1-4b96-9c2b-56397c3f144f).
The extra hour is the approved conservative buffer. Substituting a default when
policy is unreadable could make the second reset premature.

## ADR-008: Read-only diagnostics without remediation

**Decision:** Use DNS queries, AD replication cmdlets, `w32tm /stripchart`, and
per-DC targeted `dcdiag` DNS, Replications, and Services tests. Invoke `dcdiag`
without `/fix` and never refresh or modify Group Policy.

**Reason:** Microsoft describes [`dcdiag`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/dcdiag)
as the supported DC diagnostic and documents `/DnsBasic`. Unavailable, failed,
timed-out, empty, or unparseable output blocks mutation.

## ADR-009: Local durable evidence and explicit setup

**Decision:** Register `KrbtgtRotation` in the classic System log through a
separate one-time local setup on each DC. Runtime never registers it. Each
invocation has one administrator-protected JSON receipt and documented event IDs.

**Reason:** Microsoft documents that [`New-EventLog`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/new-eventlog?view=powershell-5.1)
registers a source in an existing classic log and that
[`Write-EventLog`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/write-eventlog?view=powershell-5.1)
requires prior registration. Explicit setup keeps machine configuration outside
the sensitive runtime.

## ADR-010: No rollback, bypass, or unrelated facilities

**Decision:** Omit automatic rollback, retry/timing/topology bypasses, alternate
credentials, remoting, scheduling, e-mail, cloud/web/download behavior,
dependency installation, execution-policy changes, GPO changes, `gpupdate`,
self-elevation, evidence deletion/compression, and change-ticket fields.

**Reason:** Each facility enlarges privileges or failure paths without improving
the correctness of one attended routine rotation.

## ADR-011: Separate automated checks from operational validation

**Decision:** Release only after parser success, clean selected static analysis,
mocked Pester call-boundary tests, fixture walkthroughs, hash generation, and
source review. Record production-use confirmation separately from automated
verification results.

**Reason:** Mocks can verify orchestration but cannot establish operational
fitness, permissions, replication, KDC behavior, authentication impact, or
recovery behavior.

**Status update (October 19, 2026):** The maintainer confirmed successful
production use on multiple occasions. Automated checks remain a separate
source of regression evidence.
