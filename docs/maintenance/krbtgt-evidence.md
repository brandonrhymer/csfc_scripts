# KRBTGT historical Test failure: evidence and next decision

**Disposition: no incident-specific runtime change is justified by the available
evidence.** The historical executed revision, first failing stage and setup/ACL
history are not established. Keep [issue #33](https://github.com/brandonrhymer/csfc_scripts/issues/33)
open for those inputs. A current passing check or a closed older issue does not
identify the original cause or prove that a fix occurred.

This guide supports a review of already retained evidence. It does not authorize
an operational Test, Preflight, reset, ACL repair or directory query. **Test changes
Active Directory:** it creates, resets, replicates and deletes a disabled
temporary account, and a failed stage can leave that account behind. Follow the
[existing failure procedure](../../windows/reset-krbtgt/docs/troubleshooting-and-escalation.md)
for any live incident; do not rerun Test to fill an evidence gap.

## What the current source establishes

The reviewed module is version `0.1.1`. Its SHA-256 is
`1db618658bf431032a3e7f1f50b8c8ed928459c6e4de1f4ef4e7306ff9cc9d7b`.
This identifies the source reviewed on November 13, 2026; it does not identify
the executable used during the historical failure.

The [receipt-directory guard](../../windows/reset-krbtgt/KrbtgtRotation/KrbtgtRotation.psm1)
checks that the directory exists, its ACL is protected from inheritance, its
owner is Administrators or SYSTEM, its explicit Allow entries contain only
those principals, and each has an explicit FullControl Allow entry. An extra
read-only Allow principal is rejected too. These checks are part of the
documented evidence policy, not an invitation to add a principal to the allowlist.
They are not a complete effective-access audit. Receipts are not signed and
remain editable by privileged administrators; see the
[evidence integrity limits](../../windows/reset-krbtgt/docs/security-and-limitations.md#evidence-integrity-limits).

There are two relevant stages in the module:

| Stage | What source review establishes | What the historical console error cannot establish |
|---|---|---|
| Initial runtime check | `Get-KrbtgtEnvironmentSnapshot` calls `Assert-KrbtgtRuntime`; its receipt check precedes the ActiveDirectory import and Test's temporary-user mutation path. Failure at that check stops the current Test before those writes. | That this was the historical first failure, or that the historical executable had this same flow. |
| Saving failure evidence | `Save-KrbtgtReceipt` checks the ACL again. `Write-KrbtgtFailureEvidence` attempts both a failure receipt and, if registered, a System event. A save/event error can replace the outward exception with a durable-evidence failure message. | Whether the first failure happened before or after a mutation, whether a receipt/event was retained, or whether an account was left behind. |

The event attempt carries the original error message. A retained event may help
recover that message; its existence is not guaranteed. Correlate records by
operation/invocation identifiers, phase and UTC time in the private incident
record, rather than treating nearby events as the same invocation.

## Prepare a private evidence worksheet

Keep original files and operational identifiers in the approved evidence store.
Do not paste raw events, receipts, SIDs, account names, paths, domain names,
private links or transcripts into this public repository. Work from approved
preserved copies where required; never edit a receipt to make a prerequisite pass.

| Required field | Evidence to record privately | If unavailable |
|---|---|---|
| Executed source | Exact executable/module files or their contemporaneous SHA-256, manifest version, source commit if known, and how the deployed copy was acquired. Hash the preserved executed copy, not a newly downloaded replacement. | Mark revision applicability unknown. A matching version string alone is insufficient. |
| Invocation | Phase, UTC start/end, operation/invocation identifiers and execution host from the original records. | Do not combine unrelated runs to fill gaps. |
| First failure | Original exception type/message, last successful stage and whether the error came from the original operation or the evidence writer. | Keep the first failing stage unresolved. |
| Mutation evidence | Recorded mutation-attempt flags, temporary-user plan/stages, completed commands and independently retained events/receipts. | Do not infer that no change occurred from an exception or a missing receipt. Any new directory inspection needs separate approval. |
| Intended evidence policy | Responsible owner's approved receipt-directory policy, setup completion evidence and authorized subsequent permission changes. | Do not infer the intended policy from the current ACL alone. |
| Reconciliation history | What action was taken, when, by whom, what evidence showed the result, and why the earlier report was closed. | Closure alone is administrative status, not a technical diagnosis. |

For a preserved local module copy, the following is a file-only hash check; it
does not import the module or execute its functions. Supply an approved private
path and retain the output privately:

```powershell
$preservedModule = Read-Host 'Full path to the preserved executed KrbtgtRotation.psm1 copy'
Get-FileHash -LiteralPath $preservedModule -Algorithm SHA256
```

Hashing today's installed copy establishes today's bytes only. Record the
provenance and collection time separately; do not label that hash as historical
without evidence that the file is unchanged.

## Decision after the worksheet is reviewed

| Evidence establishes | Disposition |
|---|---|
| The guard rejected unapproved permission drift under the documented policy | Preserve the guard; the responsible authority decides any separate setup/environment correction and validation. |
| Additional access is an approved product requirement | Make an explicit evidence-access design decision with security owners; review a scoped change and its synthetic/lab acceptance before altering the policy. |
| The executed revision behaves incorrectly under the approved policy, or the original failure identifies a different defect | Reproduce that specific behavior with isolated inputs where possible, then select a bounded fix. No reset gate is waived by this diagnosis. |
| Revision, original stage or reconciliation evidence is missing | Keep the historical diagnosis unresolved. Request the missing retained evidence; use an approved isolated lab only if needed after review. |

The present disposition is the last row. No incident-specific source fix, ACL
exception, retry or cleanup is authorized by this document. Lab preparation and
pilot validation remain tracked in [issue #29](https://github.com/brandonrhymer/csfc_scripts/issues/29).

## Offline regression coverage

From the repository root, in a fresh Windows PowerShell 5.1 process:

```powershell
powershell.exe -NoProfile -File tests/check-krbtgt-evidence-guards.ps1
```

The suite extracts the actual receipt guard from source without importing the
operational module, rejects unreviewed command/method boundaries before execution,
and substitutes every filesystem read with a local fake. Its twelve cases use
in-memory ACLs: both allowed owners, extra read/full-control Allow entries,
inheritance, an unexpected owner, missing or insufficient required permissions,
an absent directory and an ACL-read error. It also checks that the input ACL is
unchanged. It contacts no directory and changes no real ACL or receipt.

Use the successful GitHub Actions run for the exact reviewed revision as the
integration evidence. These checks establish only the tested policy/control
flow. They do not reconstruct the historical ACL or prove AD, SYSTEM execution,
event-log retention, real permissions, cleanup or reset readiness.
