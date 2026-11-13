# Client-maintenance pilot checklist

This checklist tracks outstanding operational validation. It is not authorization
to run the scripts. Source integration and GitHub CI can complete before a test
environment exists; neither source merge nor a candidate ZIP completes this pilot.

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

## Application service and task cases

- Approve exact local policy contents and their hashes using [policies.md](policies.md).
  Confirm binary, account, startup mode, dependency restrictions and task identity
  against the real application. Synthetic examples are not approved policies.
- Service start: cover stopped, running, disabled, missing, identity-changed,
  access-denied and timeout states. Confirm no startup configuration changes or
  unintended service starts; independently verify the final state.
- Agent restart: cover the permitted single agent, protected targets, prerequisites
  and dependents, failed stop/start and timeout. Confirm no cascading service
  operation, no MECM self-restart and no blind retry after an uncertain outcome.
- Task enablement: cover disabled, enabled, missing, changed definition and timeout.
  Verify only enablement changes. Enabling a task can let its existing triggers
  fire; assess those triggers and the maintenance window before approval.

## Policy, DNS and time cases

- Computer policy: test request acceptance/failure/timeout and independently
  inspect effective policy and policy-processing logs. Verify no forced reboot
  or logoff; the request result is not policy-completion evidence.
- DNS cache: confirm the local cache operation and test affected name resolution
  separately. Confirm resolver and adapter configuration are unchanged.
- Time: record configured source/service settings before and after, test accepted
  and failed resync requests, then independently verify time accuracy and actual
  synchronization. Captured status and request acceptance alone are insufficient.
- DNS registration: obtain DNS/DHCP owner approval and assess all eligible adapters.
  Keep DHCP-owned registration outside the client-owned Apply path. Inspect DNS
  records and registration logs separately; no resolver, DHCP or adapter changes
  are authorized by this script.

## Application file cases

- Staging cleanup: approve exact disposable staging scope, patterns, minimum age,
  exclusions and inactivity evidence. Use recoverable synthetic files to test
  eligible/young/active/log/evidence files, reparse points, hardlinks, locked files,
  concurrent changes, repeat runs, partial failure and timeout. Confirm every
  protected file remains intact and the application remains functional.
- Configuration restore: approve the supported nonsecret schema, exact source
  and destination hashes, backup location and recovery procedure. Cover Preview,
  identical content, intended restore, changed/invalid source or destination,
  lock/path rejection, backup failure, partial write and timeout. Independently
  verify original backup bytes, destination bytes and ACL preservation. Restore
  manually from the retained backup if the result is uncertain; do not blind-retry.

## Exit criteria and release decision

Retain before/after evidence, expected versus observed results, failures and
recovery actions privately. Pass requires all applicable cases, no unexplained
side effects, and confirmed MECM parameter/output compatibility. If a case cannot
be exercised, document the limit and obtain a scoped decision; do not call it
passed.

After the pilot, review any fixes and repeat affected tests. Then make the
separate release and rollout decision for this batch. Issues and Milestone 2
remain open while accepted pilot validation is outstanding. Record development
and GitHub CI completion separately from pilot completion. Missing operational
application policies also remain explicit prerequisites for use.
