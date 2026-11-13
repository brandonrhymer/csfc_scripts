# Selective MECM client cache cleanup

Product: `mecm-cache-cleanup`. Entry point: `Invoke-MecmCacheCleanup.ps1`.

**Local candidate; an approved real-client pilot is still required.** The script
has synthetic provider tests, not evidence from an installed MECM client. Use the
[shared pilot checklist](pilot-checklist.md) before authorizing a collection run.

The script previews old, complete, unreferenced, nonpersistent cache entries. In
Apply mode it asks the client's cache API to remove eligible entries. It does not
delete cache files or WMI records directly, clear orphan folders, force deletion
of persistent content, change cache settings, or restart services.

## Requirements and parameters

- Windows PowerShell **5.1**, running on the target MECM client as Local System
  through MECM Run Scripts, or an explicitly approved elevated pilot session.
- The installed client must expose the COM resource manager and read-only
  `root\ccm\SoftMgmtAgent:CacheInfoEx` metadata described below. No internet,
  downloaded module, Configuration Manager console, or remoting is required.
- Import the entry-point file into MECM Run Scripts using the normal author and
  approver separation. Supply parameters through the console; do not edit source.

| Parameter | Type | Default | Accepted values |
|---|---|---|---|
| `Mode` | String | `Preview` | `Preview`, `Apply` |
| `RetentionDays` | Integer | `30` | 1–3650 |
| `TimeoutSeconds` | Integer | `60` | 5–120 |

The 30-day default is a conservative **proposed retention choice**, not a
Microsoft requirement or an approved site policy. A site owner must approve the
age policy and account for offline deployments and pre-cached content. Removing
content can require it to be downloaded again when a later deployment needs it.

Examples for an approved pilot only:

```powershell
.\Invoke-MecmCacheCleanup.ps1 -Mode Preview -RetentionDays 30 -TimeoutSeconds 60
.\Invoke-MecmCacheCleanup.ps1 -Mode Apply -RetentionDays 30 -TimeoutSeconds 60
```

The default is Preview when `Mode` is omitted. Neither mode prompts. Typed
parameter-binding errors, such as passing nonnumeric text to an integer, are
PowerShell errors before the script starts; validly bound but out-of-range values
produce `Failed / InvalidParameter` and exit 2 without starting the worker.

## Selection and change behavior

The script joins COM cache entries to `CacheInfoEx` by unique cache identity and
requires matching content identity and location. The following must all hold:

- The persistence flag explicitly represents false, content is complete, and
  both COM and CIM reference counts are explicitly zero.
- Both last-reference timestamps are valid `DateTime` values from 1970 onward,
  are not in the future, and are strictly older than the retention cutoff.
- The reported content size is a nonnegative integer. Missing, duplicate,
  mismatched or unreadable metadata retains the entry.

Before each deletion, the script rereads the complete COM and CIM inventories.
It requires the same identity, location, timestamps and size, plus continued
eligibility. A changed entry is skipped. It calls only
`GetCacheInfo().DeleteCacheElement(id)` and then confirms that the identity no
longer appears in either COM or CIM inventory. If the call throws, remains unconfirmed, or
post-call inspection fails, the batch stops with a failure; it does not retry.

There remains a race between the final read and the provider's deletion. The
script cannot lock MECM's cache or guarantee that the provider rejects a newly
referenced or newly persisted item. Validate that behavior in the pilot and use
an approved quiet maintenance window. No production suitability claim is made
from the synthetic tests.

## Results and exit codes

The script emits one compact JSON object with product, device, mode, status,
reason, retained/unknown/eligible/removed counts, size accounting and uncertainty
flags. It does not return cache paths, content IDs, or raw provider errors. MECM
truncates output at 4 KB; the fixed summary stays below that limit.

| Status | Typical reason | Meaning / operator action |
|---|---|---|
| `Skipped` | `PreviewOnly` | Inspect the planned count and size; nothing changed. |
| `Already correct` | `NoEligibleContent` | All observed entries were protected/recent, or the cache was empty. This is not a client-health certification. |
| `Skipped` | `UnknownMetadataRetained` | Unknown metadata prevented selection. Escalate; do not bypass the guards. |
| `Skipped` | `EligibilityChanged` | Entries changed between preview and deletion; inspect current client activity before deciding on a later run. |
| `Changed` | `EligibleContentRemoved` or `EligibleContentRemovedOthersChanged` | Reported removals disappeared from both client inventories. Other entries may have been retained/skipped. |
| `Failed` | `InspectionFailed` or `RevalidationFailed` | Provider access/read failed; confirmed earlier removals, if any, remain reported. |
| `Failed` | `DeletionFailed`, `VerificationFailed`, `DeletionNotConfirmed` | A deletion's outcome is uncertain. Reconcile the client inventory before any later Apply. |
| `Failed` | `WorkerTimeout`, `WorkerFailed`, `WorkerStopUnconfirmed` | The worker did not finish reliably; inspect the client and do not automatically retry. |

Exit 0 means an evaluated result, including Preview and safe skips. Exit 1 means
failure. Exit 2 means a bound parameter failed validation. Inspect the JSON status
and reason as well as the process exit code.

`PlannedContentSize` is the sum of the initially eligible COM `ContentSize`
values; `RemovedContentSize` counts only entries whose absence was confirmed.
`SizeBasis=ClientMetadataUnitsUnverified`: these are **client-reported accounting
values**, not measured free disk space. The exact unit mapping must be verified
on the pilot client before interpreting these values as KB/bytes or reclaimed
space. Unknown physical reclamation is never presented as measured bytes.

`MayHaveChanged` remains true after any deletion attempt, including confirmed
changes. `OutcomeUncertain` marks an unresolved attempt. A timeout loses the
worker's observations, so counts and sizes become `null`, not zero. In Apply,
timeout uncertainty is conservative even if the worker had not reached deletion.

## Timeout, recovery and repeat runs

All COM and CIM calls run inside one hidden, owned Windows PowerShell child. The
parent waits up to `TimeoutSeconds`, kills that child if needed, and allows up to
two additional seconds for process cleanup. Starting Windows PowerShell and
formatting the result add small overhead; this is not a guarantee that an
external COM server operation ends when the child is killed.

Stopping the worker does not undo completed removals and may leave an external
provider operation unresolved. Keep MECM's outer execution allowance above the
configured timeout plus startup/cleanup overhead. Do not add an automatic Apply
retry after a failure or timeout. A reviewer should inspect cache inventory and
client logs, confirm the worker is gone, and reconcile the result first.

After confirmed success, a repeat invocation reevaluates the current cache;
already removed identities are absent and no deletion is repeated. There is no
attempt to recreate removed cache content. If content is needed again, let the
normal client deployment/download process obtain it.

## Evidence and pilot boundaries

Local command (development checkout only):

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -File mecm/tests/check-cache-cleanup.ps1
```

The harness injects synthetic COM/CIM providers into a temporary copy of the
actual worker and runs the unchanged launcher in real child processes. It covers
preview/apply/repeat, protected and unknown metadata, eligibility races,
partial failure, no-op deletion, invalid input, and actual child-process hangs.
It does not contact a MECM client or instantiate the real COM/CIM providers.

The approved pilot must establish these facts on each supported client version:

1. COM `CacheElementID` matches the corresponding CIM `CacheId`; GUID braces and
   letter case are normalized, but other unknown identities are matched exactly
   apart from case. Content IDs and locations must match as well.
2. `PersistInCache`, `ContentComplete`, both reference counts, and timestamps
   accurately protect persistent, incomplete and active content, including a
   change occurring immediately before the deletion request.
3. The client reports `ContentSize` consistently; record its units and compare
   metadata removal with actual cache accounting and filesystem observations.
4. A disposable eligible entry can be removed through the API; protected
   entries, client metadata, and subsequent content retrieval stay correct.
5. Console parameter import, Local System execution, application-control rules,
   process lifetime, result size/format and timeout reporting work in the site.

Any unsupported or unknown property fails closed. Do not relax that protection
to make a particular client pass; record the evidence and revise the candidate.

For an all-unknown preview, ask the client administrator to capture **private**
schema/type evidence for these exact fields; do not post cache identities,
locations, content inventories or client logs in public issues:

| Provider | Required fields and accepted meaning |
|---|---|
| COM `GetCacheElements()` | `CacheElementID`, `ContentID`, `Location`: nonempty identities; `ReferenceCount`: nonnegative integer, zero for eligibility; `ContentSize`: nonnegative integer with units to be established; `LastReferenceTime`: actual `DateTime`. |
| CIM `root\ccm\SoftMgmtAgent:CacheInfoEx` | `CacheId`, `ContentId`, `Location`: matching identities; `PersistInCache`: boolean or numeric 0/1, false/0 required; `ContentComplete`: boolean or numeric 0/1, true/1 required; `ReferenceCount`: nonnegative integer, zero required; `LastReferenced`: actual `DateTime`. |

Missing fields, null values, textual `true`/`false` flags, or formatted date
strings are unknown metadata. Escalate with the private evidence and client
version; do not edit the script or bypass its selection guards.

## Source basis

- Microsoft documents cache ownership and warns against direct filesystem
  deletion: [Configure the client cache](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/manage/configure-client-cache).
- Microsoft's archived first-party example uses the resource-manager COM object
  and `DeleteCacheElement`: [Clear Client Cache](https://github.com/microsoft/configmgr-hub-firstparty/blob/master/Clear%20Client%20Cache).
  That example is usage evidence, not a current support contract for every
  property or concurrency behavior.
- Supported console parameter types, Local System execution and the output
  limit: [Create and run scripts](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-deploy-scripts).

No primary reference establishing all `CacheInfoEx` property semantics or size
units was found during implementation. Those remain explicit pilot assumptions.
