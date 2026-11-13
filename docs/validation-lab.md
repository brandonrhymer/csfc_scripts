# Isolated validation lab blueprint

**Status: design only; no lab has been provisioned and no pilot has passed.**
This is the preparation deliverable for [issue #29](https://github.com/brandonrhymer/csfc_scripts/issues/29).
GitHub Actions remains the primary source integration and synthetic-test gate.
The environment described here supplies the real provider, transport and recovery
evidence that CI cannot supply. Provisioning and each state-changing pilot need
their own approved scope. Sources were reviewed on November 13, 2026; recheck
support and license terms when selecting media.

## Design and boundaries

Use disposable VMs with synthetic accounts, applications and content. Keep the
lab independent of operational AD, DNS, DHCP, Configuration Manager and WSUS.
Do not import production backups, credentials, GPO exports or client inventories.
Do not join lab clients to an operational site or expose discovery/client-push
boundaries beyond the lab.

The proposed Windows topology is one new single-domain forest, exactly two
writable Windows Server 2022 DCs, one standalone Configuration Manager primary
site, a separate DP, and two Windows clients. The site can host SQL, SMS Provider,
management point and local WSUS/SUP after version-specific prerequisite review.
Keeping the test DP separate is deliberate: Microsoft's cleanup tool does not
support the site server's content library, including a colocated DP. See
[Content Library Cleanup requirements](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/hierarchy/content-library-cleanup-tool).

Use a separate Linux management VM and RHEL 9 target for actual SSH and terminal
behavior. Two endpoints are necessary for the transport tests; a local mocked
subprocess does not exercise the remote session. Start with one approved target.

| Stage | Guest roles | Initial guest allocation, each |
|---|---|---|
| Linux transport | Linux manager and RHEL 9 target | 2 vCPU, 4 GiB RAM, 40 GiB disk |
| AD | Two Server 2022 DCs | 2 vCPU, 4 GiB RAM, 80 GiB disk |
| Client acceptance | Two supported Windows clients, also used for authentication smoke tests | 2 vCPU, 4 GiB RAM, 80 GiB disk |
| MECM site | One primary site with SQL and local SUP | 4 vCPU, 16–24 GiB RAM, 400 GiB total OS/database/content working storage |
| DP acceptance | One dedicated member-server DP | 2 vCPU, 4 GiB RAM, 280 GiB total OS/content storage |

These are **engineering planning allowances**, not vendor minimums or measured
capacity. All eight guests together allocate 44–52 GiB RAM and about 1,080 GiB
disk before backup/checkpoint headroom. A 64 GiB host and 1.5 TiB available fast
storage are an initial planning option, not a purchase recommendation or promise
of adequate performance. Verify host overhead, free storage, virtualization
support and contention first; run stages separately if necessary. Update/content
selection can substantially increase storage. Microsoft's
[lab hardware guidance](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/recommended-hardware#lab-deployments)
is only a starting point; selected guest OS requirements also apply.

An optional connected acquisition or dedicated WSUS-export source is additional
to this budget. Use a separate approved VM/network and media-transfer procedure;
do not bridge the test domain into another environment to obtain updates.

## Media, licensing and cost decisions

| Component | Preparation required before provisioning |
|---|---|
| Hypervisor and host | Record supported hypervisor/version, host capacity, use rights, storage/backup location, owner and operating budget. No cloud resources or purchases are assumed. |
| RHEL 9 | A qualifying individual may enroll in the self-supported, no-cost Developer Subscription for Individuals, covering up to 16 physical/virtual nodes. It requires an account and accepted terms; it is not an organization/team entitlement or an entitlement obtained merely by downloading an image. Record eligibility, subscription term/renewal and selected RHEL minor release privately. See the [Red Hat FAQ](https://developers.redhat.com/articles/faqs-no-cost-red-hat-enterprise-linux) and [program terms](https://developers.redhat.com/terms-and-conditions). |
| RHEL on WSL2 | Red Hat permits RHEL 9 on WSL2 for development/learning, but still requires an active subscription, which can be a qualifying no-cost subscription. WSL is optional development capacity; this plan requires a full RHEL VM for representative target acceptance. See [Red Hat's WSL policy](https://access.redhat.com/articles/7115538). |
| Windows Server 2022 | Use authorized licensed or evaluation media. Microsoft's evaluation lasts 180 days and requires Internet activation within the first 10 days to avoid automatic shutdown. Resolve activation in an approved staging phase before isolation, or select appropriate licensed media. Record the actual expiry and rebuild/licensing decision. See [Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022). |
| Windows clients | Select a supported edition/build for the chosen ConfigMgr release, with valid use rights or evaluation terms and expiry. Do not assume the host's license covers every guest. |
| Configuration Manager | Select authorized current-branch baseline media matching the intended compatibility target. Microsoft's [licensing FAQ](https://learn.microsoft.com/en-us/intune/configmgr/core/understand/product-and-licensing-faq#does-a-non-production-environment-for-testing-or-development-require-an-explicit-license) says 180 days for a temporary evaluation, while its [evaluation-upgrade article](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/upgrade-an-evaluation-install-to-a-full-install) says the console becomes read-only after 360 days. Resolve the selected media's terms and actual expiry with the owner; do not assume the longer period grants use rights. Technical Preview results do not establish current-branch compatibility. |
| SQL and dependencies | Select an edition, build/CU, collation and compatibility level supported by the chosen ConfigMgr version. SQL Developer's development/test licensing alone does not establish ConfigMgr support. See [SQL support](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/support-for-sql-server-versions) and [SQL edition terms](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2022). Record entitlement/evaluation expiry and offline prerequisite sources. |

Keep downloaded media, subscription credentials, activation keys and installed VM
images outside GitHub. Individual subscription services are not transferable
team entitlements; do not bundle or redistribute them with script releases.
Review each software license separately for any intended redistribution. No-cost
software eligibility does not eliminate hardware, storage, power, support or
cloud charges.

WSL2 uses a Microsoft-maintained kernel in a managed VM. Consequently, passing
WSL tests is useful development evidence but is not this plan's evidence for a
RHEL kernel, service, firewall or hardening configuration. This is the plan's
acceptance boundary, based on the [WSL architecture](https://learn.microsoft.com/en-us/windows/wsl/compare-versions).

## Reproducible build record

Complete a private build sheet before executing any setup. Unknown values remain
unknown rather than receiving production-looking examples.

| Record | Required fields |
|---|---|
| Ownership | Lab owner, AD/MECM/WSUS/Linux approvers, operator, maintenance window, spend limit and teardown date |
| Version lock | Git commit/product version/package SHA-256; OS builds; ConfigMgr baseline/build; SQL edition/CU; ClamAV package source/version and signature version; hypervisor version |
| Installation inputs | Original source URL, publisher verification, SHA-256, acquisition date, approved transfer record, entitlement and expiry for each image/package |
| Topology | Private network/subnets, lab-only DNS/DHCP/time sources, role-to-role firewall rules, client boundaries, certificate/trust design and no-production-route verification |
| Recovery | Rebuild recipe, supported backup/recovery owner, storage capacity, retained evidence location and stop conditions |
| Test cases | Product, exact inputs/policy hash, initial fixture state, expected change, independent observation, timeout, recovery steps and acceptance owner |

Use the existing [MECM preparation](../mecm/docs/01-prepare.md) and
[installation](../mecm/docs/02-install.md) guides with Microsoft's
[supported configurations](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/supported-configurations).
This blueprint does not select unknown build versions or supply setup commands.

1. Approve the build sheet and media before creating VMs.
2. Stage updates, prerequisites and any required activation through approved
   acquisition. Never place subscription credentials in reusable images.
3. Build the isolated network; verify no routes/trusts to operational systems.
   Keep host management separate from lab guest routing. Allow only the reviewed
   intra-lab protocols; do not disable endpoint controls to make tests pass.
4. Establish baseline health: AD replication/DNS/time, client authentication,
   ConfigMgr provider and client communication, content delivery, and local SUP
   state. Evidence must predate each fault-injection case.
5. Capture a reproducible clean baseline and perform one approved case at a time.
   Record setup changes separately from effects of the script under test.
6. Preserve results before restoring or discarding disposable fixtures. Rebuild
   the isolated domain as a coherent unit for destructive fault exercises; do
   not treat reverting one DC or a VM checkpoint as KRBTGT password rollback.
   Checkpoints alone are not a tested AD/SQL/site recovery plan.

During disconnected acceptance, remove temporary acquisition access and verify
it is absent. Native domain/DNS/time communication remains permitted inside the
lab. A connected acquisition VM must not route traffic into the isolated domain.

## Acceptance matrix: all rows outstanding

| Area | Required cases and independent evidence |
|---|---|
| ClamAV transport | Actual RHEL 9, OpenSSH and sudo/password PTYs; approved and changed/unknown host-key behavior; correct/wrong credentials; empty configuration lists and paths with spaces; missing/multiple sockets and log permissions; benign scanner success, timeout, forced termination, partial output and nonzero SSH exit. Confirm retained partial evidence and no automatic retry after an uncertain collection. Observe remote process state separately: local SSH termination does not prove remote completion. Use the [ClamAV runbook](../linux/clamav/README.md) deadlines. No malware fixture is required. |
| KRBTGT | Exactly two writable Server 2022 DCs, fixed 10-hour TGT policy, interactive elevated current-domain Domain Admin, local Windows PowerShell 5.1, same execution DC, protected evidence policy. Verify Preflight/WhatIf AD-write boundaries and local evidence writes; approved Test lifecycle/replication/deletion; failures and receipt rejection; authentication smoke tests. Any reset exercise is separately authorized and preserves the fixed 11-hour wait and every prerequisite. Never weaken a gate or run Test merely to fill historical evidence. Follow the [operator runbook](../windows/reset-krbtgt/docs/operator-runbook.md) and [security boundary](../windows/reset-krbtgt/docs/security-and-limitations.md). |
| Cache cleanup and CcmEval | Real client cache API/CIM metadata, persistent/in-use/concurrent content and actual reclaimed space; standard task identity, overdue/recent/active/missing/disabled states and native CcmEval logs/remediation effects. Preview changes nothing; request acceptance is distinct from health recovery. |
| Service start, agent restart and task enablement | Exact approved application binary/account/startup/dependency or task-definition identity; stopped/running/disabled/missing/changed targets, partial failure and timeout. No dependency cascades or MECM self-restart. Existing task triggers may fire after enablement. |
| Computer policy, DNS cache, time sync and DNS registration | MECM/SYSTEM parameter and output behavior; correct failure/timeout results; no forced reboot/logoff or configuration change. Independently verify actual policy, name resolution, time synchronization and DNS records. Obtain DNS/DHCP ownership and adapter-scope approval before registration. |
| Staging cleanup and configuration restore | Real approved policies and hashes, disposable files, exclusions, age/activity/concurrency, path/link/ACL restrictions, Preview, repeat runs and partial failure. Restore currently supports only `MaintenanceDisplay/v1` with a valid pinned original; verify backup/destination bytes and permissions, and the documented non-atomic recovery path. Other application schemas need reviewed support. |
| MECM integration across all eleven products | Use the complete [pilot checklist](../mecm/client-maintenance/pilot-checklist.md), not this summary alone. Check script import/approval, Windows PowerShell 5.1 execution context, all parameters, 4 KB output handling, deadlines, repeat behavior and independently observed side effects on a narrow fixed collection. Synthetic examples do not approve real policies. |
| WSUS export and disconnected updates | Dedicated authorized source, known products/classifications/languages/files, direct local export paths, preview/no output, fresh export, additive copy and failure preservation; transfer/hash checks, import, scan/download/install/reboot and compliance. Do not change an existing shared source to fill missing coverage. Follow [MECM validation](../mecm/docs/validation.md). |
| DP and SUP maintenance | First complete native capability and ownership reviews in issues [#25](https://github.com/brandonrhymer/csfc_scripts/issues/25) and [#26](https://github.com/brandonrhymer/csfc_scripts/issues/26). Use one dedicated DP for native preview and separately approved deletion; verify retained content and deployments. SUP changes need inventory, a demonstrated gap and recovery approval. A lab's availability does not itself justify a custom cleanup script. |

## Evidence and exit gate

For every case record `Not run`, `Pass`, `Fail`, or `Deferred with reason`, plus
expected/observed state, before/after observations, exact source/package versions,
platform versions, execution context, inputs, timestamps, exit/result, logs and
recovery outcome. Retain raw evidence privately; publish only deliberately
reviewed synthetic or sanitized summaries. An unexercised case cannot be marked
passed. Hashes and passing CI establish source/package properties, not real
provider behavior.

Stop a pilot on an unexpected write, target mismatch, uncertain timeout outcome,
failed evidence capture, permission drift or failed recovery. Preserve evidence
and resolve the failure before deciding whether a repeat is safe. Never replay a
KRBTGT reset or blindly retry a partially completed maintenance action.

The next decision requires a lab owner, approved host/resources, selected media
and entitlements, a version-locked build sheet, private isolation/transfer design,
and accepted recovery/test scopes. Real application policies remain a separate
input. Issue #29 and all client pilot requirements stay open until those decisions
and the actual acceptance evidence exist. Release promotion and operational
rollout follow their own review after applicable pilots pass.
