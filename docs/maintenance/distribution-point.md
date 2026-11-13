# Distribution-point cleanup readiness

This runbook prepares the decision in [issue #25](https://github.com/brandonrhymer/csfc_scripts/issues/25).
It does not approve cleanup or establish a need for a new script. No DP pilot
has been run. Complete the worksheet privately; use only synthetic examples in
GitHub. This is a server-administration workflow, separate from client Run Scripts.

## Start with the native tool

Microsoft supplies `ContentLibraryCleanup.exe` under
`CD.Latest\SMSSETUP\TOOLS\ContentLibraryCleanup`. It targets one DP and requires
Configuration Manager Full Administrator-equivalent permissions. Omitting
`/delete` selects a non-deleting assessment; both modes write logs. `/delete`
enables prompted deletion; `/q` suppresses prompts. A secondary-site DP requires
its parent primary's FQDN and site code through `/ps` and `/sc`.

The tool excludes the site server's content library, including a site server
that also hosts a DP, and content-enabled cloud management gateways. Version
2010 added orphaned DP WMI-record cleanup. With failed/incomplete content, older
versions can stop; the documented 2107 behavior warns and continues without
reliable orphan identification. Treat such warnings as a stop for this workflow,
not permission to delete. These are feature-history distinctions, not supported
version recommendations. See Microsoft's [tool scope, modes and known issue](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/hierarchy/content-library-cleanup-tool).

The native tool already covers target selection, preview, confirmation and logs.
A wrapper needs a demonstrated remaining requirement; saving a few command-line
arguments alone does not establish one.

## Private decision worksheet

Copy this table into the approved private change record. Leave unknown values
as **Unknown** and stop before an operational preview when required ownership
or scope is unresolved. Do not put the completed worksheet in this repository.

| Field | Required evidence |
| --- | --- |
| Owner and request | Responsible site/DP owner; reason for cleanup; change record |
| Exact target | One DP FQDN; owning site; primary/secondary relationship; role inventory proving this is not the site-server library or a cloud target |
| Version | Installed ConfigMgr build; tool source/version/hash; support status confirmed by the owner |
| Native behavior | Exact arguments proposed; expected log destination; no `/delete` or `/q` in the first assessment |
| Current health | Timestamped content/distribution status; active transfers, failed packages or warnings; disk-space baseline |
| Scope protection | Agreed quiet window and concurrent-change controls; users/deployments potentially affected |
| Recovery | Known required content; retained source or approved recovery material; owner and steps for recovery; evidence that recovery is possible |
| Evidence custody | Private log location, access controls, retention and reviewer |
| Decision | Native workflow sufficient / demonstrated gap / insufficient evidence, with reasons |

An example decision is: **Insufficient evidence: the installed build and DP
role relationship are unknown. No target scan or cleanup is approved.** This
example is a decision format, not a finding about any environment.

## Later approved pilot

The following sequence is the proposed acceptance plan. It has not been executed.

1. The owner verifies the worksheet and authorizes an assessment of the single
   target. Review distribution health first. Resolve incomplete-content warnings
   through the site's supported process before considering cleanup.
2. Run the installed native tool without deletion or quiet mode, using the
   recorded target and a private log directory. Preview contacts the site/DP
   and writes a local log; it is not an offline simulation. Keep the complete
   arguments, tool hash, start/end times and log.
3. A reviewer reconciles the candidate objects, warnings and proposed scope
   against the site record. Record candidate counts and any available estimates
   with their units. An estimate is not measured reclaimed space. Unknown
   ownership, unreliable enumeration, a changed target or an incomplete log
   stops progression.
4. Obtain explicit approval for this reviewed target and cleanup window.
   A new or changed candidate list requires renewed review. Retain the native
   per-item confirmations; this runbook does not approve unattended `/q`
   deletion or a multi-DP loop.
5. During an approved cleanup, stop further targets on an error or unexpected
   result. Preserve partial results; do not retry automatically. Record the
   log's actual outcome, then separately measure disk space and verify required
   content, DP health and an approved client download.

Choose an observation/maintenance-window limit in the change record. Exceeding
it is an escalation condition, not a promise that killing a process reverses
work. Reconcile its state with the owner before another attempt.

## Recovery and acceptance

Treat deletion as irreversible by this workflow. It has no rollback command.
For required objects, Configuration Manager supports content validation and
redistribution. Use the affected object's supported recovery path only after
the owner confirms that source content remains available. Redistribution does
not reconstruct an orphaned object whose source and site definition no longer
exist. See [Microsoft's content management procedures](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/configure/deploy-and-manage-content).

Pilot acceptance requires a reviewed single-target preview, explicit approval,
complete/partial outcome accounting, no unexplained loss of required content,
successful content/client checks, and a rehearsed recovery decision. Free disk
space alone does not establish success. Keep the pilot outstanding in #25 and
the [lab issue #29](https://github.com/brandonrhymer/csfc_scripts/issues/29).

## When to propose code

Record a concrete unmet behavior, a sanitized example, the installed native
tool's observed limitation, expected result, owner and isolated test plan.
If native controls meet the requirement, use this runbook and close only the
design question; do not describe the unrun pilot as complete. No custom cleanup
product is selected by this readiness work.

References were checked on November 13, 2026. Recheck them against the installed
version before approving an operational plan.
