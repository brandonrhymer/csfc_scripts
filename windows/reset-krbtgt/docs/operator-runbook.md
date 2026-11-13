# Operator runbook

## Stop conditions first

**Stop immediately on any nonzero exit, red error, failed receipt, timeout,
unexpected object, extra metadata version, failed cleanup, event-write failure,
or post-check anomaly. Do not rerun a production reset, attempt a password
rollback, or continue to Reset 2.** Preserve the System events and JSON receipts
and follow the escalation guide.

Use under the responsible AD authority's approved change process and confirm
the target environment meets the supported profile.

## What each flow does

| Flow | AD effect | Required prior evidence | Success lifetime |
|---|---|---|---|
| Preflight | Reads only; never forces replication | None | 30 minutes |
| Test | Creates, password-resets, replicates, deletes one disabled temporary user | Matching Preflight | 30 minutes |
| Reset 1 | Exactly one built-in `krbtgt` password reset | Matching Preflight and Test | Durable Reset 1 evidence |
| Reset 2 | Exactly one built-in `krbtgt` password reset | New matching Preflight/Test, explicit Reset 1 receipt, 11-hour wait | Final evidence |

Preflight and native `-WhatIf` perform no AD write. Both still write mandated
local evidence. Test is not a simulation and is state-changing.

## Before Reset 1

1. Confirm both expected DCs are online and no topology change is in progress.
2. Select the DC that will execute both Reset 1 and Reset 2. Record it in the
   approved local change record outside this tool.
3. Sign in interactively with the current-domain Domain Admin account.
4. Start elevated Windows PowerShell 5.1 and change to the verified release root.
5. Ensure the maintenance window leaves enough time for Preflight, Test, the
   reset, automatic post-checks, and manual client smoke tests.

Create one operation ID for the Reset 1 group of commands:

```powershell
$reset1OperationId = [guid]::NewGuid()
$reset1OperationId
```

Keep the same value for the following Preflight, Test, optional WhatIf, and live
Reset 1 commands.

## Reset 1 sequence

Run Preflight:

```powershell
.\Invoke-KrbtgtPreflight.ps1 -OperationId $reset1OperationId
```

Read the output. Continue only when `Status` is `Succeeded`. Preflight validates
Windows PowerShell/elevation/current identity, exact topology/OS, event/evidence
setup, DNS, Kerberos/default password policy, time offset, replication failures
and partner state, targeted `dcdiag` DNS/Replications/Services tests, and exact
RID-502 account identity/metadata on both DCs.

Run the explicit state-changing Test:

```powershell
.\Invoke-KrbtgtTest.ps1 -OperationId $reset1OperationId
```

Continue only when `Status` is `Succeeded`. The Test must report verified
temporary-user deletion on both DCs.

Optional native read-only preview:

```powershell
.\Invoke-KrbtgtReset.ps1 -Phase Reset1 -OperationId $reset1OperationId -WhatIf
```

The WhatIf event/receipt does not extend or replace the 30-minute Preflight/Test
receipts.

Run live Reset 1:

```powershell
.\Invoke-KrbtgtReset.ps1 -Phase Reset1 -OperationId $reset1OperationId
```

The command shows DN, `sAMAccountName`, SID, object GUID, and source DC. It then
shows the exact case-sensitive phrase. Type it exactly—for example:

```text
contoso.example RESET 1
```

Do not paste a phrase prepared for a different domain or phase. Continue only
when the final receipt is `Succeeded`. Record its full `ReceiptPath`; Reset 2
requires that explicit file.

## Manual validation after Reset 1

From an approved client—not from the DC and not automated by this package—run
the enclave owner's approved smoke tests. At minimum the owner should define:

- new interactive authentication with a test account;
- access to representative Kerberos-protected enclave services;
- service/application checks for critical workloads;
- approved KDC, replication, and detection-tool review.

If any test fails, stop and escalate. Do not proceed to Reset 2.

## Mandatory wait

Wait at least 11 hours from the successful Reset 1 receipt's UTC
`CompletedUtc`: the approved 10-hour maximum TGT lifetime plus a one-hour safety
buffer. The tool uses UTC, rejects future/inconsistent timestamps, and has no
timing bypass.

## Reset 2 sequence

Return to the **same selected DC**. Create a new operation ID:

```powershell
$reset2OperationId = [guid]::NewGuid()
```

Run fresh Preflight and Test:

```powershell
.\Invoke-KrbtgtPreflight.ps1 -OperationId $reset2OperationId
.\Invoke-KrbtgtTest.ps1 -OperationId $reset2OperationId
```

Optional preview, using the actual Reset 1 receipt path:

```powershell
$reset1Receipt = 'C:\ProgramData\KrbtgtRotation\Receipts\<Reset1 receipt>.json'
.\Invoke-KrbtgtReset.ps1 -Phase Reset2 -OperationId $reset2OperationId `
    -Reset1ReceiptPath $reset1Receipt -WhatIf
```

Run live Reset 2:

```powershell
.\Invoke-KrbtgtReset.ps1 -Phase Reset2 -OperationId $reset2OperationId `
    -Reset1ReceiptPath $reset1Receipt
```

The exact typed phrase ends in `RESET 2`. Continue only when the Reset 2 receipt
is `Succeeded`, then repeat all owner-defined client smoke tests.

## Evidence handling

- Receipts remain under `%ProgramData%\KrbtgtRotation\Receipts` on the execution
  DC; events remain in the System log.
- Never delete, rename, edit, compress, or automatically purge this evidence.
- Treat domain/DC names, account identifiers, policy, replication state, and
  errors according to enclave classification and retention rules.
- A failed or `Running` production receipt with
  `DirectoryMutationAttempted=true` is an anomaly even if console output was lost.
