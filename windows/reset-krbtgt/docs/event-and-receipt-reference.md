# Event and receipt reference

## Evidence locations

- Classic event log: **System**
- Event source: `KrbtgtRotation`
- JSON receipts: `%ProgramData%\KrbtgtRotation\Receipts`
- Event message schema: [`schemas/event.schema.json`](../schemas/event.schema.json)
- Receipt schema: [`schemas/receipt.schema.json`](../schemas/receipt.schema.json)
- Machine-readable event catalog: [`schemas/event-catalog.json`](../schemas/event-catalog.json)

Each event message is compact JSON. Event 900 and its Setup receipt record the
one-time local setup. Receipts are overwritten only as the same invocation
advances from its initial pre-mutation checkpoint to its terminal result; a
separate receipt is never created for the same invocation.

## Event IDs

| ID | Level | Meaning |
|---:|---|---|
| 900 | Information | One-time local event/evidence setup completed |
| 1100 | Information | Preflight succeeded |
| 1101 | Error | Preflight failed |
| 1200 | Information | Temporary-user Test mutation started |
| 1201 | Information | Test and cleanup succeeded |
| 1202 | Error | Test or cleanup failed |
| 1300 | Information | Exact typed production confirmation accepted |
| 1301 | Warning | Exactly one production password mutation is being attempted |
| 1400 | Information | Reset 1 and all post-checks succeeded |
| 1401 | Error | Reset 1 failed or became anomalous |
| 1500 | Information | Reset 2 and all post-checks succeeded |
| 1501 | Error | Reset 2 failed or became anomalous |
| 1600 | Information | Native read-only WhatIf preview completed |

## Receipt status

| Status | Meaning |
|---|---|
| `Running` | A checkpoint exists; inspect `DirectoryMutationAttempted` before assuming anything about AD state |
| `Succeeded` | Every required stage for this invocation completed |
| `Failed` | A required stage failed; production mutation may or may not have been attempted |
| `WhatIf` | Read-only production preview completed; no AD-changing adapter was called |

`DirectoryMutationAttempted=true` is deliberately set and saved immediately
before Test object creation or a production password call. For a production
receipt, treat `Running` or `Failed` plus this flag as an anomaly that prohibits
Reset 2.

`ConfirmationAccepted` is true only after the live production operator types the
exact case-sensitive domain-and-phase phrase. No password or credential appears
in events or receipts.

## Receipt relationships

- `InvocationId` uniquely identifies one script invocation and receipt.
- `OperationId` binds the Preflight/Test/reset group.
- `PrerequisiteReceipts` records the matching receipt invocation IDs.
- Reset 1 and Reset 2 use different operation IDs.
- Reset 2 additionally records the selected successful Reset 1 invocation ID.

The runtime manually validates required schema fields, path locality, status,
timestamps, domain, DC, operator (for the 30-minute gates), target SID/GUID, and
policy. The published JSON Schema is for independent tooling and review; runtime
does not download or invoke a schema engine.
