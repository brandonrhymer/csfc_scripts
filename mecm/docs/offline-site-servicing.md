# Service Configuration Manager without site internet access

This updates **Configuration Manager itself**, separately from WSUS metadata and
Windows update files. Use Microsoft's
[Service Connection Tool](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/manage/use-the-service-connection-tool)
and [in-console update procedure](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/manage/install-in-console-updates).
Examples below use synthetic local paths; replace them from the approved change.

## Prepare the change and data-transfer approval

1. Record the installed site build, intended supported update/hotfix, support
   status, prerequisites, maintenance window, responsible owners and recovery
   decision. Verify a current [backup/recovery set](backup-recovery.md), including
   matching CD.Latest; a VM snapshot alone is insufficient.
2. Verify the service connection point (SCP) is installed in **offline** mode.
   Use the entire `SMSSETUP\TOOLS\ServiceConnectionTool` directory from the
   **matching installed ConfigMgr version**, including its supporting files.
   Do not mix an arbitrary downloaded executable with another version's libraries.
3. Prepare both the SCP host and approved connected host: supported x64 Windows,
   applicable .NET, x86/x64 VC++ dependencies and, for 2309 onward, x64 ODBC
   Driver 18 at the selected release's supported version. Check the
   [ODBC exclusions](01-prepare.md#match-prerequisites-to-each-host). Run elevated;
   the SCP operator also needs site-database Read access.
4. Create protected staging folders and enough space for usage data and update
   packs. Confirm approved connected-host proxy/endpoint access and transfer
   media. Keep these directories and outputs outside the repository.
5. **The Connect operation uploads hierarchy usage data to Microsoft.** It is
   not download-only. Export a reviewable CSV, have the authorized data owner
   approve the actual outbound transfer, and only then move the CAB to the
   connected host. Reviewing the CSV does not sanitize the CAB. If outbound usage
   data cannot be approved, stop and resolve the servicing approach with the
   security/site owner; do not silently upload it.

## Export, prepare, connect and import

Run from the copied tool directory in an elevated command prompt. Paths must
exist as applicable, and the update-pack destination should be new/empty.
After **each** command, inspect its outcome and preserve `ServiceConnectionTool.log`
before the next invocation because the tool replaces that log.

On the **offline SCP host**, export the review CSV and prepare the transfer CAB:

```bat
ServiceConnectionTool.exe -export -dest D:\Transfer\UsageData.csv
ServiceConnectionTool.exe -prepare -usagedatadest D:\Transfer\UsageData.cab
```

Verify files are nonempty/current and logs show completion. Approve release of
the data, scan it and record hashes. Transfer the matching tool directory and
approved CAB to the connected host; compare hashes there. The `-usagedatasrc`
argument below is the **folder containing the CAB**, not the CSV or CAB filename.

On the **approved connected host**:

```bat
ServiceConnectionTool.exe -connect -usagedatasrc D:\Transfer -updatepackdest D:\Transfer\UpdatePacks
```

This uploads the usage CAB and downloads applicable update packs. Preserve the
tool log and connected host's `ConfigMgrSetup.log`; inspect download/hash results
and verify the intended update was acquired. The default download selection does
not include hotfixes; when the approved change requires updates/hotfixes for the
current site version, review the documented **`-downloadsiteversion`** option and
use it explicitly rather than assuming the default downloaded the hotfix.

Transfer the **complete** update-pack directory inward using the approved scan
and hash process. On the **offline SCP host**:

```bat
ServiceConnectionTool.exe -import -updatepacksrc D:\Transfer\UpdatePacks
```

Verify import completion and retain logs. Missing files, hash failures or tool
errors are stop points. Reconcile the source/transfer; do not use unsupported
database edits to force an update to appear. Import makes updates available to
the console; it does not install them.

## Install and verify the selected update

1. Open **Administration > Updates and Servicing**, refresh and identify the
   exact intended update/version. Read its release-specific checklist and known
   issues; verify disk, SQL/ADK/.NET/ODBC and restart prerequisites across roles.
2. Run the update's **prerequisite check**. Inspect its result and
   `ConfigMgrPrereq.log`; resolve blocking errors and document warning decisions.
   Do not bypass failures to meet a change-window deadline.
3. In the approved window, choose **Install Update Pack**, review the wizard's
   feature/client options and use a designated preproduction client collection
   for client testing where applicable. Accept licensing terms only as authorized.
   Follow the update's restart guidance; dependencies can require role restarts.
4. Monitor **Monitoring > Updates and Servicing Status** and site-server
   `CMUpdate.log` through completion. Investigate failed stages before any retry.
   Record update identity, start/end, result and affected component versions.
5. Update/reopen the console as prompted. Verify site/console builds, required
   role health, pilot client upgrade and the first-patch/policy checkpoints.
   Promote the client only after the approved pilot acceptance.
6. Capture a fresh verified backup and matching CD.Latest, archive the servicing
   evidence and update the private build worksheet. If update/recovery fails,
   use the supported recovery process with the site owner; do not assume uninstall
   or snapshot rollback is a supported universal reversal.

**Acceptance:** imported package identity, completed prerequisite/install stages,
site/console/pilot versions, functioning roles and a fresh recovery set. These
are required observations for the actual environment, not results established
by this guide.
