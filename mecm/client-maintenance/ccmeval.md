# Overdue CcmEval recovery

`Invoke-MecmCcmEval.ps1` previews or requests a run of the existing Configuration
Manager health evaluation task on the local client. It is a local pilot candidate:
synthetic tests exercise its decisions and process timeout, but a real MECM pilot
has not been completed. Do not use a broad collection before that pilot.

## Scope and prerequisites

- Windows PowerShell 5.1 with the Windows `ScheduledTasks` module, running as
  LocalSystem through MECM Run Scripts, or an authorized elevated local operator.
- The existing task must be `\Microsoft\Configuration Manager\Configuration Manager Health Evaluation`.
  The script neither creates a missing task nor repairs its definition.
- The task must have one executable action, with no arguments, pointing to the
  existing `%windir%\CCM\CcmEval.exe`. Its working directory must be empty or the
  CCM directory, and its principal must be SYSTEM. Nonstandard installation paths
  and customized actions are skipped for administrator review.
- For an overdue task, demand start must be enabled and the existing multiple
  instances policy must be `IgnoreNew`. The script does not change these settings.
- No downloads, third-party modules, credentials, remote sessions or source edits
  are required. The script starts an owned local PowerShell worker; application
  control or constrained language policies that prohibit it need pilot review,
  not a policy exception added by this script.

The script does not directly restart the MECM client or other services. CcmEval
itself performs Configuration Manager health checks and can remediate services.
Approving its execution therefore permits those existing client health actions.

## Parameters

MECM Run Scripts supports integer, string and list parameters. Supply these inputs
through the console; the script does not ask questions on collection members.

| Parameter | Type / allowed values | Default | Meaning |
| --- | --- | --- | --- |
| `Mode` | String: `Preview`, `Apply` | `Preview` | Only Apply can enable or request a task start. |
| `EnableDisabled` | String: `No`, `Yes` | `No` | Yes permits enabling an existing **overdue** disabled task in Apply. It does not override identity or policy checks. |
| `OverdueHours` | Integer: 1–8760 | 72 | Minimum elapsed hours since the last run. Exactly the threshold is overdue. |
| `TimeoutSeconds` | Integer: 5–120 | 60 | Shared worker input/execution budget. Keep below the MECM execution limit configured for the pilot. |

The default 72 hours follows Microsoft's client check criterion of a run within
the previous three days. It is a scheduling criterion, not a claim that the last
run succeeded or that the client is healthy. The pilot owner must approve any
different interval.

A pre-2000 timestamp is considered never-run only when `LastTaskResult` is the
documented `SCHED_S_TASK_HAS_NOT_RUN` value, `0x00041303` (267011). Other old,
missing, inconsistent or unreadable metadata is skipped. A timestamp more than
five minutes in the future is skipped for clock investigation. A more recent
future timestamp is treated as recent within that clock tolerance.

## Operator sequence

1. Import and approve the exact candidate through the site's normal MECM script
   author/approver process. Select only the approved pilot collection.
2. Run `Mode=Preview`, `EnableDisabled=No`, and the approved `OverdueHours`.
   Review each result and the existing task definition. Investigate unknown,
   customized, missing or disabled tasks before allowing a change.
3. Run `Mode=Apply` with the same interval only on eligible pilot devices.
   Select `EnableDisabled=Yes` only when the pilot owner has approved re-enabling
   that existing task; otherwise keep `No`.
4. Check the task's actual run, completion and result, then review `CcmEval.log`
   and MECM client health. An accepted start request is not a successful health
   evaluation. Repeat Preview and preserve the before/after evidence.
5. Stop on failure or timeout and follow the reconciliation steps below before
   another Apply. Do not automatically retry an unresolved request.

Equivalent local commands for an already approved pilot client:

```powershell
.\Invoke-MecmCcmEval.ps1 -Mode Preview -OverdueHours 72
.\Invoke-MecmCcmEval.ps1 -Mode Apply -OverdueHours 72
# Only after approval to re-enable an existing overdue task:
.\Invoke-MecmCcmEval.ps1 -Mode Apply -EnableDisabled Yes -OverdueHours 72
```

## Decisions and results

The script returns one compact JSON result below the MECM 4 KB output limit.
MECM associates it with the reporting device. Invalid parameters are rejected by
PowerShell before a worker starts; those binding errors can use normal PowerShell
error output rather than this JSON contract.

| Status | Meaning | Operator response |
| --- | --- | --- |
| `Changed` | A start request was accepted, or an approved enable completed and another run became active/recent. | Verify actual task completion and client health separately. |
| `Already correct` | The enabled task ran within the selected interval. | No start requested; investigate a failed last result separately if necessary. |
| `Skipped` | Preview, active/queued task, recent disabled task, missing task, unapproved enable, unsafe/unknown metadata, or another copy of this script is active. | Read `Reason` and `ProposedAction`; approve or escalate as applicable. |
| `Failed` | Provider, worker, verification or protocol failure; changes may be partial. | Inspect before retry. |

Important fields are `Reason`, `ProposedAction`, `Phase`, `EnabledByScript`,
`StartRequested`, `MutationAttempted`, `OutcomeUncertain`, `LastRunUtc`,
`LastTaskResult`, and `TimedOut`. Some early worker failures cannot supply last-run
metadata. `EnabledByScript=true` records that the enable call returned successfully;
the subsequent check still can fail. `StartRequested=true` records acceptance by
the task provider, not proof of execution. `LastTaskResult` is the scheduler's
reported value and is not reinterpreted as a client-health verdict.

Exit codes: `0` for a completed decision (including preview/skip), `1` for failure,
and `2` for timeout. A nonzero result must not be treated as a successful repair.

Before each change the task is re-read. After enabling, a new active or recent run
prevents a redundant start. A named mutex prevents overlapping copies of this
script on one machine; the existing `IgnoreNew` policy prevents an overlapping
running instance if a native scheduler trigger races with the final request.
Neither mechanism locks out an administrator changing the task definition, and
`IgnoreNew` does not prevent a later request after a prior instance finishes.
Avoid changing task policy during the pilot; investigate any inconsistent state.

## Failure and timeout reconciliation

The input transfer and provider execution share one worker deadline. On timeout,
the parent terminates only its owned PowerShell worker. It allows up to five
seconds to confirm worker exit and five seconds to collect output. It does not
terminate CcmEval or undo actions already accepted by Task Scheduler. An enable
can remain in effect after a failed or timed-out start.

For `OutcomeUncertain=true`, `MutationAttempted=true` with failure, or any timeout:

1. Inspect the existing task's enabled state, queued/running state, last run and
   last result using the approved administration tools.
2. Review task history and `CcmEval.log` for an accepted run and any remediation.
   Also review the MECM script result and `Scripts.log` where relevant.
3. If the task is active, allow normal completion. Do not re-trigger it to clear a
   failed script result. If only the enable completed, keep the actual state in
   the incident record and let the owner decide whether further action is needed.
4. Resolve provider/policy/clock problems, then run Preview. Retry Apply only when
   the prior request has been reconciled and the task remains eligible.

No failure path recreates the task, changes its action or concurrency policy,
disables it as a rollback, restarts CcmExec, or retries a mutation automatically.

## Local tests and pilot evidence

From the repository root, use a fresh Windows PowerShell 5.1 process:

```powershell
powershell.exe -NoProfile -NonInteractive -File mecm\tests\check-ccmeval.ps1
```

The harness makes temporary AST-derived copies with synthetic provider functions
inside the real worker. It exercises the production parameter binding, process
launcher, serialization, timeout and result handling without calling real task
providers. It covers safe defaults, eligibility and definition checks, repeat
behavior, changed state before mutation, partial enable/start failure, malformed
worker results, blocking provider calls, a child that never reads input, and the
overlap guard. There is no runtime test switch in the shipped script.

Before broader use, the approved pilot must verify actual task property types,
the task path/action/principal and `IgnoreNew` policy, last-run and never-run
representations, LocalSystem/module access, child-process restrictions, console
parameter mapping/output/exit handling, enable behavior and actual CcmEval
completion/logs. A synthetic run does not establish any of these live interfaces.
Use the included `pilot-checklist.md` for evidence and stop conditions.

## Primary references

- [Configuration Manager client health checks](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/manage/client-health-checks): three-day recent-run criterion and native remediation behavior.
- [MECM Run Scripts](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-deploy-scripts): supported parameter types, system execution and output size.
- [Microsoft's task path example](https://learn.microsoft.com/en-us/defender-endpoint/live-response-command-examples): Configuration Manager Health Evaluation identity.
- [Start-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/start-scheduledtask?view=windowsserver2025-ps): asynchronous start semantics.
- [Task Scheduler result constants](https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-error-and-success-constants): never-run and running status values.
- [RegisteredTask.Run](https://learn.microsoft.com/en-us/windows/win32/taskschd/registeredtask-run): demand-start limitation.
- [Task instance policy](https://learn.microsoft.com/en-us/windows/win32/api/taskschd/ne-taskschd-task_instances_policy): `IgnoreNew` behavior.
