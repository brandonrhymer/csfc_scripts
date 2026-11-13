# Restart one approved application agent service

Product: `mecm-agent-restart`. Entry point: `Invoke-MecmAgentRestart.ps1`.
Template: [agent-restart.policy.example.json](agent-restart.policy.example.json).

This performs one bounded stop/start cycle for one exact approved application
agent that is Running and accepts stop. It verifies Stopped before StartService,
then verifies Running. A stopped, paused or transitioning service is ineligible.
A running service is the prerequisite for restart, not an already-correct no-op.
The script does not change startup configuration or kill application processes.

## Operator inputs and preconditions

Read the [overview](README.md), [policy guide](policies.md) and
[pilot checklist](pilot-checklist.md). Use offline Windows PowerShell **5.1** in
MECM's SYSTEM context or an approved equivalent elevated pilot account. The
application owner supplies a reviewed policy already staged on the client and
its separately approved hash. Operators do not edit source or policy content.

| MECM parameter | Type | Accepted value |
| --- | --- | --- |
| `Mode` | String | `Preview` (default), `Apply` |
| `PolicyPath` | String | Absolute local fixed-drive `.json` path; at most 240 characters |
| `PolicySha256` | String | 64 hexadecimal characters identifying the approved file bytes |
| `TimeoutSeconds` | Integer | 5-120; default 60 |

Set those types and bounds in MECM. UNC/device paths, wildcards, traversal and
reparse points are rejected. Policy files are at most 64 KiB, UTF-8 JSON. The
same bytes are hashed and parsed. Missing/changed policy fails closed. The
synthetic example is marked `Example: true` and rejected in both modes; it never
becomes an active default. Obtain a reviewed replacement policy and digest after
a mismatch, rather than calculating a hash simply to bypass approval.

## Policy review and exclusions

Root fields are exactly `SchemaVersion` (integer `1`), `Product`
(`mecm-agent-restart`), `Example` (boolean `false` for an approved policy), and
`Target`. `Target` has exactly five strings:

| Field | Required content |
| --- | --- |
| `ServiceName` | Exact service name, first character a letter, then letters/digits/underscore/dot/hyphen; at most 128 characters |
| `ExpectedPathName` | Exact configured command line with absolute `.exe` path, quoted if it contains spaces |
| `ExpectedStartName` | Exact configured account from Win32_Service |
| `ExpectedStartMode` | Exact `Auto` or `Manual` |
| `ExpectedServiceType` | Exactly `Own Process` |

A senior administrator inventories these values read-only in the approved lab,
compares them with application-owner records, and supplies the policy outside
Git. Protect the file and its parent folders against non-admin writes. This
synthetic inventory example is read-only:

```powershell
Get-CimInstance -Namespace root\cimv2 -ClassName Win32_Service -Filter "Name='SyntheticAppAgent'" |
    Select-Object Name, PathName, StartName, StartMode, ServiceType, State, AcceptStop
```

**Never target CcmExec or another MECM delivery component through Run Scripts.**
The script rejects MECM-related names, core OS names, common security/vendor
patterns, Windows-directory executables, shared-process services, drivers,
unresolved variables and ambiguous unquoted paths. The reviewer must also reject
OS/security/identity/network/management and business-critical infrastructure
services whose custom names evade those checks. Patterns cannot identify every
third-party product's role. Do not weaken a safeguard for an excluded target.

Any configured prerequisite service or load-order group causes
`DependencyRefused`, even if currently running. **Any dependent service also
causes refusal, including a stopped dependent.** The implementation never stops
dependencies or dependents. It uses `Win32_Service.StopService`, which refuses
an active dependent-service conflict; it does not use cascading
`ServiceController.Stop()` or `Restart-Service`. Identity/state/dependencies are
rechecked before each mutation. The original configuration is preserved.
Review recovery actions, triggers and external supervisors during approval;
their independent automatic actions remain outside this script's control.

## Operator procedure and partial-stop recovery

1. Confirm approval for this agent's interruption and maintenance window.
   Complete the pilot checklist, including an out-of-band recovery path.
2. Enter the approved path/digest and run `Mode=Preview`. Confirm
   `Skipped/PreviewOnly`; escalate unexpected results before Apply.
3. Run `Mode=Apply` once under the approved change. Save the JSON and verify
   the agent's own health and communication with its server.

`Changed/AgentRestarted` requires observed Stopped followed by observed Running
with matching identity. It does not prove application health. After StopService
is submitted, a failure may leave the service **stopped**. `StartRejected`,
`StartFailed`, `StartNotConfirmed`, identity change after stop or `WorkerTimeout`
never triggers an automatic retry. Inspect actual service state and application/
event logs through the approved out-of-band channel. If configuration changed,
do not blindly start the replacement. The application owner decides recovery.

One JSON object below 4 KiB reports Status (`Changed`, `Already correct`,
`Skipped`, `Failed`), fixed `Reason`, `Phase` and `LastState`. For this product,
there is no normal already-correct restart result. `MayHaveChanged` records a
submitted or possible mutation. `OutcomeUncertain=true` requires reconciliation
before another action. `LastState=Stopped` is a past observation, not proof of
current state after a later timeout. Exit **0** means evaluated, **1** failure,
**2** invalid input or timeout; inspect `Reason` and `TimedOut`. PowerShell may
reject malformed non-integer input before JSON; MECM's integer type prevents it.

Policy errors require policy review. `TargetMissing`, `TargetAmbiguous`,
`IdentityMismatch`, `TargetExcluded`, `StateNotEligible`, `DependencyRefused` or
`RevalidationChanged` require investigation, not broader selectors.
`AnotherOperationActive` means another local operation owns the service mutex.
`StopRejected`, `StopFailed` or `StopNotConfirmed` means the stop was not verified;
no start is attempted after an unresolved stop.

Every provider call is in an owned child. Asynchronous stdin and execution share
the timeout; termination/output cleanup can add roughly 8 seconds. The parent
kills only its worker. An accepted Windows action can continue afterward, so
timeout/bad output is failed and conservatively uncertain. There is no retry,
reset or rollback. The per-service mutex covers these products on the same host;
other administrators do not honor it, so rechecks cannot eliminate every race.

## Validation and remaining pilot work

GitHub Actions is the primary integration/test gate; local mocks are development
evidence. From the repository root, use a fresh Windows PowerShell 5.1 process:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\mecm\tests\check-agent-restart.ps1
```

Guarded synthetic providers exercise the actual parent/worker, policy hashes,
preview/apply, stopped/ineligible agents, dependency/dependent refusal, target
changes, stop/start errors and partial outcomes, protocol validation, real owned
child timeouts and blocked stdin. Tests never call real service/task providers.

No real target or MECM lab was supplied. Provider types, account permissions,
actual stop/start semantics, application recovery, MECM import/approval/output,
policy distribution and timing need an authorized single-device lab pilot.
Passing CI does not establish readiness, deployment or recovery. No operational
execution or release is part of this implementation.

## Microsoft behavior references

- [StopService](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/stopservice-method-in-class-win32-service) documents return code 3 for active dependents and asynchronous state changes.
- [ServiceController.Stop](https://learn.microsoft.com/en-us/dotnet/api/system.serviceprocess.servicecontroller.stop) documents dependent-service stopping behavior; this product does not call it.
- [StartService](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/startservice-method-in-class-win32-service) documents request return values; the script additionally verifies Running.
