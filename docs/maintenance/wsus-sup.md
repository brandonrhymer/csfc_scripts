# WSUS and SUP maintenance readiness

This runbook prepares [issue #26](https://github.com/brandonrhymer/csfc_scripts/issues/26).
No live inventory, maintenance or pilot has been performed. It identifies what
must be established privately before selecting another maintenance script.
SUP means Configuration Manager's Software Update Point; SUSDB is the WSUS
database. This is server administration, separate from client Run Scripts.

The repository's [disconnected transfer guide](../../mecm/docs/03-first-patches.md)
uses an existing shared connected WSUS. Its synchronization, products,
classifications, languages, approvals and cleanup remain under that server
owner's control. A gap on the disconnected side is not authority to change the
shared source. Exporting existing content is separate from maintaining it.

## Native coverage comes first

For Configuration Manager 1906 and later, the SUP component's WSUS Maintenance
settings offer decline according to supersedence policy, index creation and
obsolete-update removal after synchronization. Index creation is not recurring
reindexing. Remote SUPs using WID cannot receive the native index/obsolete-update
tasks through a remote database connection. Obsolete removal has a 30-minute
run limit and resumes after a subsequent synchronization. Native cleanup does
not run inactive-computer or unneeded-file cleanup. Confirm actual results in
`wsyncmgr.log`; a selected option alone is insufficient evidence.
These are documented feature boundaries, not a claim that a 1906-era build is
currently supported. [Microsoft's versioned maintenance reference](https://learn.microsoft.com/en-us/intune/configmgr/sum/deploy-use/software-updates-maintenance)

Microsoft recommends the native SUP maintenance options for modern versions,
with separate SUSDB backup and reindex schedules. For a separately approved
manual procedure, its guide describes bottom-up cleanup, top-down superseded
declines, and avoiding synchronization overlap. Those ordering rules do not
authorize changing another owner's schedule. [Microsoft's maintenance guide](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/wsus-maintenance-guide)

Microsoft also supplies manual and automated database procedures. They include
mutating operations and can run for a long time; the presence of a Microsoft
script is not evidence that its full sequence is appropriate for this site.
Use the installed-version and topology review before selecting any subset.
[Manual and automatic SUSDB maintenance](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/wsus-automatic-maintenance)

## Private inventory worksheet

Copy this table into an approved private record. Keep actual hosts, topology,
logs, account details and completed worksheets outside Git. Record **Unknown**
when evidence is unavailable; do not turn it into a default setting.

| Field | Evidence to record |
| --- | --- |
| Boundaries and ownership | Each SUP/WSUS and owner; connected acquisition versus disconnected site; standalone/replica arrangement; shared consumers |
| Versions | ConfigMgr build/support status, Windows/WSUS build, SQL or WID version and patch level |
| Database map | SUSDB location/instance; shared database relationships; remote SUP versus site server; WID or full SQL; private connection details |
| Current native configuration | Each maintenance option and supersedence setting, captured without changing it; observation time |
| Actual native outcomes | Recent sync and maintenance timestamps/results; relevant private logs; errors, backlog and repeat behavior |
| Other maintenance | Existing SQL/WSUS jobs, owner, scope, schedule and overlap; backup/reindex history; retention/recovery evidence |
| Health baseline | Agreed measures such as sync/scan duration, failure counts, database/content growth and free space, with collection method and units |
| Operational constraints | Sync/maintenance windows, outage and resource limits, downstream dependencies, approvals and escalation owner |
| Proposed gap | Specific unmet result, evidence native/existing jobs do not meet it, candidate supported procedure and expected outcome |
| Disposition | Native coverage sufficient / configuration fault / additional workflow justified / insufficient evidence |

The coverage review below is a starting point for that record. Every local
status remains **Unknown** until supplied by the responsible owner.

| Area | First question | Possible disposition after evidence |
| --- | --- | --- |
| Decline/obsolete cleanup | Are applicable native options enabled and completing? | Resolve the recorded configuration/permission fault before proposing duplication |
| Indexes | Is native creation applicable to the actual database topology? | Existing supported procedure may suffice; remote WID needs local-owner review |
| Backup/reindex | Does the database owner already run and verify them? | Use existing coverage or design the missing owned schedule |
| Inactive computers/unneeded files | Is retention or disk growth actually a problem, and who owns the data? | Propose a scoped native procedure only for an evidenced need |
| Shared connected source | Does the requested change affect other consumers? | Route to its owner; this repository's disconnected workflow cannot authorize it |

These are candidate gaps, not findings that this environment needs cleanup.

## Decision before implementation

For each candidate, the owner records the evidence, affected servers/databases,
retention policy, expected measurable result and supported native procedure.
Select a custom tool only when that record identifies an unmet behavior and
an isolated test can distinguish success from a false success. A permission
error, disabled setting or missing owner is not automatically a software gap.

An example disposition is: **Insufficient evidence: native settings and the
database owner's existing jobs have not been inventoried. No new cleanup
script is selected.** This is synthetic and does not describe a real server.

## Later approved pilot and recovery

1. Resolve ownership and exact installed versions; approve the procedure and
   scope privately. Verify backup retention and restoration evidence for each
   affected SUSDB and agree how content/settings are recovered as well.
2. Establish an isolated baseline with representative synthetic updates and
   clients. Review expected retained/deleted objects and changes to approvals
   before execution. A generic WSUS cleanup invocation is not a dry run.
3. Arrange the maintenance/synchronization window through each owner. Keep
   other environments and shared sources outside the approved scope. Capture
   the original settings privately if an approved procedure must change them.
4. Run only that approved procedure. Record start/end, exact version, parameters,
   affected objects, errors and partial completion. Time/resource limits are
   observation and escalation rules; cancellation does not guarantee rollback.
   Stop expansion on unknown state or unexpected effects; do not blindly retry.
5. Reconcile retained/deleted metadata and content, approved settings and
   downstream state. Verify synchronization, client scan and an approved update
   download/install, plus the original measurable requirement. Restore any
   authorized temporary settings and verify their actual value.

Declining updates, deleting metadata/files and database maintenance have
different recovery needs. Re-enabling synchronization or restoring a database
alone is not a demonstrated recovery of the entire hierarchy. Require the
database/site owners' tested restore or content reacquisition plan and keep
failure evidence before deciding whether to resume. Do not copy broad SQL
delete, shrink or cleanup examples into an unattended job without that review.

The next gate is an owner-approved inventory and demonstrated unmet need.
Operational pilot acceptance remains open in #26 and
[lab issue #29](https://github.com/brandonrhymer/csfc_scripts/issues/29).
Passing GitHub source checks cannot establish WSUS, SQL or client behavior.

References were checked on November 13, 2026. Recheck them against the installed
version before approving an operational plan.
