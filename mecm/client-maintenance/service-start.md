# Start one approved stopped application service

Product: `mecm-service-start`. Entry point: `Invoke-MecmServiceStart.ps1`.
Template: [service-start.policy.example.json](service-start.policy.example.json).

This starts one exact approved application service only when it is stopped and
verifies a final `Running` observation. A running service returns `Already correct`
with `ServiceRunning` and receives no mutation. Paused or transition states fail
closed. It never changes startup mode, account, executable, recovery settings or
other service configuration. `Running` does not establish application health.

## Operator inputs and preconditions

Read the [overview](README.md), [policy guide](policies.md) and
[pilot checklist](pilot-checklist.md). Use offline Windows PowerShell **5.1** in
MECM's SYSTEM context or an approved equivalent elevated pilot account. The
application owner supplies the policy file already staged on the client and its
separately approved hash. Routine operators do not edit source or policy content.

| MECM parameter | Type | Accepted value |
| --- | --- | --- |
| `Mode` | String | `Preview` (default), `Apply` |
| `PolicyPath` | String | Absolute local fixed-drive `.json` path; maximum 240 characters |
| `PolicySha256` | String | 64 hexadecimal characters identifying the approved file bytes |
| `TimeoutSeconds` | Integer | 5-120; default 60 |

Set those types and bounds in MECM. No UNC/device paths, wildcard selectors,
traversal or reparse points are accepted. Policy files are limited to 64 KiB of
UTF-8 JSON. The hash is checked before parsing the same bytes; missing or changed
policy fails closed. The example has `Example: true` and is rejected in both
modes. It is never an activated default. Do not compute a replacement hash simply
to bypass a mismatch. Obtain a reviewed policy and approved digest.

## Policy review and scope

The root fields are exactly `SchemaVersion` (integer `1`), `Product`
(`mecm-service-start`), `Example` (boolean `false` in an approved policy) and
`Target`. `Target` contains exactly these strings:

| Field | Meaning |
| --- | --- |
| `ServiceName` | Exact service name, not display name; starts with a letter, then letters/digits/underscore/dot/hyphen; at most 128 characters |
| `ExpectedPathName` | Exact `Win32_Service.PathName`, including quotes and arguments; absolute `.exe` path, quoted if it contains spaces |
| `ExpectedStartName` | Exact configured service account from `Win32_Service.StartName` |
| `ExpectedStartMode` | Exact `Auto` or `Manual`; disabled services are outside scope |
| `ExpectedServiceType` | Exactly `Own Process`; shared-process services and drivers are outside scope |

A senior administrator obtains evidence read-only in the approved lab, compares
it with the application owner's installation records, and prepares the policy
outside Git. This synthetic inventory example is read-only:

```powershell
Get-CimInstance -Namespace root\cimv2 -ClassName Win32_Service -Filter "Name='SyntheticAppAgent'" |
    Select-Object Name, PathName, StartName, StartMode, ServiceType, State
```

CcmExec/MECM-related names, core OS names, common security/network/vendor patterns,
Windows-directory executables, unresolved variables and ambiguous unquoted paths
are rejected. Those conservative checks cannot classify every third-party
service. The reviewer must establish that the target is an ordinary application
service, not an OS, security, identity, network, management or business-critical
infrastructure service under another name. Do not weaken checks for an excluded
target. Protect the policy and its parent directories against non-admin writes.

For a stopped target, any configured `DependOnService` or `DependOnGroup` causes
`DependencyRefused`, even if a prerequisite is currently running. This narrow
boundary avoids implicitly starting other services. Review service triggers,
recovery actions and external supervisors too; their automatic behaviors remain
outside the script's control. Identity, state and dependencies are rechecked
before the one StartService request. Identity and state are checked while waiting
for Running. No configuration write or retry is performed.

## Operator procedure and results

1. Confirm the owner approved this target, its maintenance window and any effect
   on application availability. Complete the pilot checklist first.
2. Enter the supplied policy path and digest and run `Mode=Preview`. Confirm
   `Skipped/PreviewOnly`, or reconcile any other result with the owner.
3. Under the approved change, run `Mode=Apply` once. Retain the per-device JSON
   with the change record and verify the application's own health checks.

One JSON object is emitted below 4 KiB. Status is `Changed`, `Already correct`,
`Skipped` or `Failed`. `Changed/ServiceStarted` requires observed Running.
`Phase` and `LastState` record the last observation. `MayHaveChanged` means an
action was submitted or cannot be ruled out; `OutcomeUncertain=true` requires
external inspection before further action. Exit **0** means evaluated, **1**
failure, **2** invalid input or timeout (`Reason`/`TimedOut` distinguishes them).
PowerShell can reject malformed non-integer arguments before JSON is produced;
MECM's integer parameter definition should prevent those submissions.

`PolicyInvalid`, `PolicyHashMismatch` or `ExamplePolicyRejected` require policy
review. `TargetMissing`, `TargetAmbiguous`, `IdentityMismatch`, `TargetExcluded`,
`StateNotEligible`, `DependencyRefused` or `RevalidationChanged` require owner
investigation. Do not broaden the target selector. `AnotherOperationActive`
means a local operation for that service already owns the mutex.

`StartRejected`, `StartFailed`, `StartNotConfirmed` or `WorkerTimeout` are
failures even if Windows later starts the service. Inspect real service state
and application/event logs through the approved support path. Do not retry
automatically or change startup configuration to make the request succeed.

All provider calls run inside an owned child. Asynchronous input transfer and
worker execution share the timeout; termination/output cleanup can add roughly
8 seconds. Only that worker is killed, never the application process. Killing
the worker cannot undo or cancel an accepted Windows action. Timeout or bad
worker output reports conservative uncertainty. The per-service mutex prevents
overlapping instances of these products on one host, but external administrators
do not honor it; provider calls cannot eliminate every concurrent-change race.

## Validation and remaining pilot work

GitHub Actions is the primary integration/test gate. Local synthetic checks are
development evidence. Run this check from the repository root in a fresh process:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\mecm\tests\check-service-start.ps1
```

Guarded mocks execute the real parent/worker flow with synthetic policies and
targets. Cases include preview/apply/no-op, policy/type/hash exclusions, changed
identity, dependencies, provider failures, partial outcomes, malformed/oversized
worker output, real owned-child timeout and blocked stdin transfer. Tests never
call real service/task providers on the development host.

No real application targets or MECM lab were supplied. Actual Windows provider
types, permissions, policy distribution, MECM import/approval/output capture,
timing and application recovery remain unvalidated. An authorized single-device
lab pilot must verify them before broader use. No release or operational
execution is established by a passing parser/mock/CI result.

## Microsoft behavior references

- [Win32_Service](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-service) describes configuration and state metadata.
- [StartService](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/startservice-method-in-class-win32-service) documents request return values; this script separately verifies state.
- [Starting a service](https://learn.microsoft.com/en-us/windows/win32/services/starting-a-service) illustrates waiting for the service's reported Running state.
