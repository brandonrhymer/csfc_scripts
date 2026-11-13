# First client-maintenance pilot

This checklist describes the next decision gate. It is not authorization to run
the scripts. The local batch ends before client execution or source publication.

## Approve a bounded pilot

Record privately the owner, approved test clients and client versions, collection
membership, maintenance window, package hashes, script versions, parameters,
expected changes, and stop conditions. Use disposable or recoverable clients with
synthetic test content. Do not target a broad operational collection.

Choose the cache retention period explicitly after reviewing pending deployments
and persisted/offline content needs. Review the CcmEval overdue interval and
whether enabling an existing disabled task is permitted. A recent task run is
not evidence that the client is healthy.

Ensure the scripts run as Windows PowerShell 5.1 in the intended MECM execution
context. Confirm parameter import, allowed values, output parsing, exit codes,
execution deadline and endpoint controls. Do not weaken security controls to
make the pilot pass. Ensure the script's timeout is shorter than the approved
outer execution limit, leaving time for cleanup and reporting.

## Cache cases

- Prepare old unused, recent, persistent and in-use content; record the cache
  interface metadata and actual disk usage before running anything.
- Run Preview and independently compare the planned items and estimated size.
  Assert that file contents and cache metadata are unchanged.
- Apply only the approved retention policy. Confirm only eligible entries were
  removed, protected content remains usable, cache metadata stays consistent and
  related deployments still work. Compare actual free space separately from the
  script's metadata-based size estimates.
- Repeat Apply and verify it introduces no further changes for the same state.
- Exercise provider failure, unavailable or inconsistent metadata, a concurrent
  download/use change and the execution deadline on disposable clients. Confirm
  uncertain outcomes stop further action and are inspected before retry.

## CcmEval cases

- Verify the existing task's path, action, account, settings and installed client
  executable against the product's checks. A rejected identity is a reason to
  investigate, not to relax checks in production.
- Cover overdue enabled, recent, active/queued, missing and disabled tasks.
  Preview must leave every case unchanged. Missing tasks must not be created.
- Apply to an overdue enabled task; inspect Task Scheduler history and CcmEval
  logs for actual execution. The script's accepted start request is not proof
  that client health checks or repairs succeeded.
- Keep enabling disabled tasks unapproved first, then test explicit approval on
  a disposable client. Verify a partial failure reports any enablement already
  performed and does not blindly retry the task.
- Repeat while active and after a recent run; confirm no duplicate start. Test
  access denial and timeout. Record native CcmEval remediation effects: CcmEval
  itself may change services even though this wrapper does not restart them.

## Exit criteria and publication decision

Retain before/after evidence, expected versus observed results, failures and
recovery actions privately. Pass requires all applicable cases, no unexplained
side effects, and confirmed MECM parameter/output compatibility. If a case cannot
be exercised, document the limit and obtain a scoped decision; do not call it
passed.

After the pilot, review any fixes and repeat affected tests. Then make the
separate publication decision for this batch. Issues remain open until their
accepted validation and publication work is complete; the other Milestone 2
products remain queued.
