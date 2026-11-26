# Back up the site and rehearse recovery

This procedure selects the supported **Backup Site Server** maintenance task
for a standalone primary site. A DBA-managed SQL backup design is another
supported branch, but must also protect matching site/recovery material and use
Microsoft's corresponding database-recovery option; a database file alone is
not the recovery plan. See [site backup](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/manage/backup-and-recovery).

## Configure and verify backup

1. Record the approved recovery point/time objectives, schedule, protected
   destination, storage capacity, retention count/period, off-host archive owner
   and failure-alert recipient. Use the objectives to set the interval;
   Microsoft recommends no more than five days between site backups.
2. Pre-create the protected destination outside package/content source trees.
   For UNC storage, give the **site-server computer account** Write on both
   share and NTFS. If SQL is remote, its computer account also needs that access.
   For colocated site/SQL using **Local drive on site server for site data and
   database**, grant Local System Write NTFS access. For remote SQL using
   **Local drives on site server and SQL Server**, pre-create both local folders
   and grant the respective server's **computer account** Write NTFS access on
   its folder. These are different destination modes; verify the selected mode's
   rights. Restrict other access because backups contain sensitive configuration
   and data; the task does not encrypt them.
3. In **Administration > Site Configuration > Sites**, select the site, then
   **Site Maintenance** (maintenance tasks). Select **Backup Site Server > Edit**,
   enable it, and use **Set Paths** to configure the chosen supported destination.
4. Set the approved schedule and alert on failure. Check the time basis: when
   configuring from the site server, the task uses local time; from a remote
   console, it uses UTC. Record the actual resulting schedule.
5. Let an approved scheduled run complete. Inspect fresh output timestamps,
   `<site-install>\Logs\Smsbkup.log` and **Monitoring > System Status > Component
   Status > SMS_SITE_BACKUP** status messages. **5035** indicates completion.
   Investigate failures and alert delivery; a folder's existence is insufficient.
6. After verified completion, archive that entire backup set to separately
   retained dated storage. Verify copy integrity and readability. The built-in
   task removes/replaces its previous snapshot at the next run; it does not
   supply multi-generation retention. Implement archival scheduling only after
   the backup/archive owners agree ordering and failure behavior.

## Protect what the task does not recover by itself

| Material | Required protection |
| --- | --- |
| Site recovery media | Preserve the backup's matching **CD.Latest** and prerequisite files; built-in site backup includes CD.Latest |
| Content library and package sources | Separate backups preserving original paths/access; these are excluded from the site backup task |
| Certificates and private keys | Approved protected PKI backup/reissuance process, passwords separately controlled; trust/CRL and IIS binding record |
| SQL/WSUS and role configuration | Record topology, instance/ports, version/CU, storage, service identities and role rebuild instructions with owners |
| Other recovery material | Approved account-secret recovery, custom reports, scripts, configuration and out-of-band fixes as applicable |

After in-console site servicing, old baseline media does not replace the
matching recovery media. **CD.Latest is for recovery and supported expansion,
not a fresh first site in a new hierarchy.** See
[CD.Latest](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/manage/the-cd.latest-folder).

## Rehearse in an isolated lab

Use a backup **created inside the approved isolated lab**. This project's lab
design does not permit importing production backups. Do not restore a duplicate
site identity onto an operational network. The following is a standalone-primary
rehearsal; hierarchies, passive site servers and SQL HA require their matching
recovery procedure.

1. Agree the isolated network, restore target, failure rollback and observation
   window. Use a fresh isolated target without an existing ConfigMgr site; if
   reusing a server, complete Microsoft's linked scenario-specific recovery
   cleanup procedure first. Do not use generic registry/database deletion.
   Build supported Windows/SQL prerequisites and restore permissions.
   Preserve the original lab site's hostname/FQDN, site code and database name.
   SQL must use the same edition; use a version supported for the recovery design
   (a supported newer SQL version can be permitted). Do not assume an arbitrary
   OS/SQL upgrade is part of recovery.
2. Verify the selected backup's integrity and timestamp. Copy its matching
   **CD.Latest** to a folder outside the intended site installation directory.
   Run its `SMSSETUP\BIN\X64\setup.exe` with the approved recovery account and
   choose **Recover a site**. In disconnected recovery, select the preserved
   version-matched prerequisite files. `CD.Latest\Redist` might not exist before
   the first in-console update; in that case use the retained prerequisite
   directory from the matching baseline installation.
3. For this built-in-backup branch, select recovery of the site server from the
   backup set and recovery of the site database from that backup. Supply the
   approved backup paths and original site/database details. Follow the supported
   wizard selections for the actual failure scenario. Restoring over an existing
   database fails; do not delete an unexpected database to get past that check.
   Stop and reconcile the target with the DBA.
4. Complete prerequisite checks and recovery. Retain `ConfigMgrSetup.log` and
   review `C:\ConfigMgrPostRecoveryActions.html`. For a standalone primary, site
   changes since the backup are lost; reconcile them against the private change
   record rather than assuming another site supplies them.
5. Perform each applicable post-recovery action: reenter account secrets through
   the approved private process, restore content/package sources to their original
   locations, restore HTTPS certificate bindings, recover/reinstall roles as
   instructed and reapply applicable out-of-band fixes.
6. Verify site/build and console/provider access, required role health, a lab
   client receiving policy, then one update scan/download/install/report cycle
   using the [checkpoints](verification-checkpoints.md). Record elapsed recovery
   time and recovered data timestamp against the objectives.

Use Microsoft's [site recovery procedure](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/manage/recover-sites)
for the exact failure scenario. A successful backup message establishes backup
completion; only the recorded isolated restore exercise establishes recoverability
for the tested configuration. No recovery exercise has been completed by this
documentation change.
