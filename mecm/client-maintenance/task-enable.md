# Enable one approved existing scheduled task

Product: `mecm-task-enable`. Entry point: `Invoke-MecmTaskEnable.ps1`.
Template: [task-enable.policy.example.json](task-enable.policy.example.json).

This enables one exact existing disabled application task, then verifies its
enabled setting and approved definition. An enabled task returns `Already correct`.
Missing or ambiguous identity fails closed. The script never requests a run,
registers/recreates a task, or changes actions, triggers, principal or other
settings. **Enabling allows the task's existing triggers to take effect**, so
Task Scheduler may subsequently run it without this script requesting a run.
The owner must review triggers and missed-run behavior before approval. This
product cannot promise the task remains idle after enablement.

## Operator inputs and preconditions

Read the [overview](README.md), [policy guide](policies.md) and
[pilot checklist](pilot-checklist.md). Use offline Windows PowerShell **5.1** in
MECM's SYSTEM context or an approved equivalent elevated pilot account. The
application owner provides a reviewed policy already staged on each client and
its separately approved hash. Operators do not edit source or policy content.

| MECM parameter | Type | Accepted value |
| --- | --- | --- |
| `Mode` | String | `Preview` (default), `Apply` |
| `PolicyPath` | String | Absolute local fixed-drive `.json` path; maximum 240 characters |
| `PolicySha256` | String | 64 hexadecimal characters identifying the approved file bytes |
| `TimeoutSeconds` | Integer | 5-120; default 60 |

Set those types and bounds in MECM. UNC/device paths, wildcards, traversal and
reparse points are rejected. Files are limited to 64 KiB of UTF-8 JSON. The same
bytes are hashed and parsed. Missing or changed policy fails closed. Both modes
reject the supplied `Example: true` synthetic template; it is never an active
fallback. Do not compute a new hash simply to bypass a mismatch. Obtain a
reviewed replacement policy and approved digest. Protect the file and its parent
folders against non-admin writes. Keep operational policy/evidence outside Git.

## Policy identity and review

Root fields are exactly `SchemaVersion` (integer `1`), `Product`
(`mecm-task-enable`), `Example` (boolean `false` in an approved policy), and
`Target`. `Target` contains exactly three strings:

| Field | Meaning |
| --- | --- |
| `TaskPath` | Exact folder path beginning and ending with `\`; root `\` is valid; maximum 200 characters; folder names use letters/digits/spaces/underscore/dot/hyphen |
| `TaskName` | Exact name, 1-128 letters/digits/spaces/underscore/dot/hyphen, starting with a letter or digit |
| `DefinitionSha256` | SHA256 of the normalized XML described below; 64 hexadecimal characters |

No wildcard/path traversal or alternate target is accepted. Microsoft/Windows,
Configuration Manager and common MECM/security task paths/names are excluded.
The reviewer must establish that a custom-named task is an approved application
task rather than a system/security/management task that evades those patterns.
Do not weaken safeguards to permit an excluded target.

The full exported definition is fingerprinted, including actions, principal,
triggers, registration metadata and settings. Only the task's own
`Settings.Enabled` element is excluded. Trigger-level Enabled flags remain
covered. The worker enumerates and selects tasks by literal path/name equality,
then checks the definition before Preview/no-op, immediately before enablement,
and afterward. The mutation uses the selected task object. External
re-registration can race between provider calls; this product cannot lock Task
Scheduler against administrators. A post-change mismatch is failure/uncertainty.
`LastState` is `Enabled` or `Disabled` from the setting, not the runtime state.

### Read-only fingerprint recipe for the policy reviewer

A senior administrator runs this in the approved lab. Save the exported XML with
the change evidence and review the entire definition with the owner before
approving the digest. **Generating a digest does not approve the definition.**
Never update policy to match an unexplained mismatch. Routine operators need
only the approved policy path and its separately approved file digest.

```powershell
function Get-ReviewedTaskDefinitionHash {
    param([string]$TaskPath, [string]$TaskName)
    $ErrorActionPreference = 'Stop'
    if ($TaskPath -match '[*?\[\]]' -or $TaskName -match '[*?\[\]]') { throw 'Use exact names.' }
    $matches = @(Get-ScheduledTask | Where-Object { $_.TaskPath -ieq $TaskPath -and $_.TaskName -ieq $TaskName })
    if ($matches.Count -ne 1) { throw 'Expected exactly one existing task.' }
    $text = Export-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader $text), $settings)
    $document = New-Object Xml.XmlDocument
    $document.PreserveWhitespace = $false
    $document.XmlResolver = $null
    try { $document.Load($reader) } finally { $reader.Dispose() }
    $ns = New-Object Xml.XmlNamespaceManager($document.NameTable)
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    if ($null -eq $document.SelectSingleNode('/t:Task', $ns)) { throw 'Unexpected XML.' }
    $nodes = @($document.SelectNodes('/t:Task/t:Settings/t:Enabled', $ns))
    if ($nodes.Count -gt 1) { throw 'Unexpected Enabled elements.' }
    foreach ($node in $nodes) { $null = $node.ParentNode.RemoveChild($node) }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($document.OuterXml)))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}
Get-ReviewedTaskDefinitionHash -TaskPath '\SyntheticApp\' -TaskName 'Synthetic Maintenance'
```

This uses deterministic XML serialization, not universal XML canonicalization.
Whitespace between elements is discarded. Attribute ordering, registration data
and provider serialization changes can require reviewed policy replacement even
if an administrator considers the definition equivalent. The recipe and worker
use DTD-prohibited XML readers with no external resolver. Verify fingerprint
stability across the actual supported Windows builds in the authorized pilot.

## Operator procedure and results

1. Confirm approval for the existing task's behavior after enabling, including
   triggers, principal, action arguments, maintenance window and missed runs.
2. Complete the pilot checklist. Enter the supplied policy path/digest and run
   `Mode=Preview`. Reconcile any result other than the expected preview/no-op.
3. Run `Mode=Apply` once under the approved change. Save per-device JSON and
   verify enablement plus any application effects through approved checks.

One JSON object smaller than 4 KiB reports `Changed`, `Already correct`, `Skipped`
or `Failed`, a fixed `Reason`, `Phase`, `LastState`, `MayHaveChanged` and
`OutcomeUncertain`. `Changed/TaskEnabled` confirms the enabled setting and
definition at the final read; it does not assert a successful task run.
`Already correct/TaskEnabled` makes no change. Exit **0** means evaluated, **1**
failure, **2** invalid input or timeout; inspect `Reason` and `TimedOut`.
PowerShell may reject malformed non-integer input before JSON; MECM's parameter
type should prevent those submissions.

Policy errors require policy review. Missing/ambiguous/changed/excluded targets
require owner investigation; do not broaden selectors or replace the definition.
`AnotherOperationActive` means another local enable operation holds the mutex.
`EnableNotConfirmed`, `EnableFailed`, post-enable `IdentityMismatch`, or
`WorkerTimeout` may still have enabled the task. Inspect Task Scheduler and the
application's evidence. Do not automatically retry or disable it: the owner must
reconcile its current state and any trigger-driven execution first.

Provider calls run inside one owned child. Asynchronous input transfer and
execution share the timeout, with roughly 8 seconds additional cleanup possible.
The parent kills only its own worker. It cannot cancel an enable request already
accepted by Windows or stop work the scheduler subsequently runs. Timeout/bad
output fails with conservative uncertainty; `LastState` is only the last known
observation. No automatic retry, rollback or reset occurs. A local target mutex
prevents overlapping product invocations but not independent administrator edits.

## Validation and remaining pilot work

GitHub Actions is the primary integration/test gate. Local synthetic checks are
development evidence. From the repository root use a fresh Windows PowerShell
5.1 process:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\mecm\tests\check-task-enable.ps1
```

Guarded mocks exercise the real parent/worker flow: preview/apply/no-op, policy
hash/schema/type checks, exact selection, missing/ambiguous/changed definitions,
DTD rejection, partial enablement, malformed/oversized output, real owned-child
timeout, blocked stdin transfer and no run/register/redefine calls. No real
service/task provider is invoked on the development host.

No real application target or MECM lab was supplied. Actual ScheduledTasks object
types, fingerprint stability, permissions, trigger behavior, policy distribution,
MECM import/approval/output capture and timing require an authorized single-device
pilot. Passing CI does not establish readiness or deployment. No operational
execution or release is part of this implementation.

## Microsoft behavior references

- [Get-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/get-scheduledtask) and [Export-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/export-scheduledtask) provide task objects and XML definitions.
- [Enable-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/enable-scheduledtask) changes enablement of an existing task.
- [Enabled task setting](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-enabled-settingstype-element) describes the setting that permits a task to be performed; enabling preserves existing triggers.
