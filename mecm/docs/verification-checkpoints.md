# Verify setup and the first patch cycle

Before starting, record a change window, expected duration and escalation owner
for each stage. There is no universal timeout for setup, synchronization or
distribution: scale and content vary. Record start/end times and the last progress
event. If the agreed window expires or a blocking error appears, preserve the
evidence and stop advancing; do not repeatedly reinstall, resynchronize or deploy.

Paths use the actual site installation directory, not necessarily `C:\ConfigMgr`.
Remote role logs use that role host's ConfigMgr log directory (commonly
`C:\SMS\Logs`); record the actual path when installing the role.
Read logs with CMTrace. Keep device names, logs and screenshots in the private
change record. Representative failures below are diagnostic categories, not an
exhaustive error-code catalogue.

| Checkpoint and execution host | Observable pass and evidence | Failure / next action |
| --- | --- | --- |
| Site Setup: site server, system-drive root `ConfigMgrSetup.log` and `ConfigMgrPrereq.log` | Setup reaches final completion; prerequisite errors resolved, warnings dispositioned; intended site/build visible under Administration > Site Configuration > Sites | SQL/role/prerequisite failure or continuing setup activity: investigate the failing component; an opened console can be read-only while Setup continues |
| Provider/site health: Provider `SMSProv.log`, site's `Logs` and Monitoring > System Status | Console can read intended site; required components/roles report healthy after initialization; record relevant status messages | Access/namespace/SQL failure: verify identity and host before concluding the site is absent; do not reinstall from a status-script failure |
| SUP configuration: site server `Logs\WCM.log` | Intended WSUS FQDN, actual port and SSL choice configured successfully; approved connection identity works | Connection, port or certificate error: return to WSUS/SUP setup; do not disable SSL to bypass it |
| WSUS health: SUP host's role log directory, `WSUSCtrl.log` | Current WSUS connection/health check succeeds for that endpoint | HTTP/TLS/authentication/database failure: check IIS binding, trust, WSUS service/database and site-server console connectivity |
| Metadata synchronization: site server `Logs\wsyncmgr.log` | Import log completed on SUP; ConfigMgr synchronization completes both WSUS processing and site-database synchronization; intended updates visible | Import error, repeated sync failure or only partial progress: retain both logs; verify source coverage and SUP settings before retrying |
| Client assignment/policy: client `%windir%\CCM\Logs\LocationServices.log`, `ClientIDManagerStartup.log`, `PolicyAgent.log` | Correct site/MP, registration and machine policy received; intended SUP URL supplied | Wrong site/SUP or absent policy: fix assignment, boundary-group role association, trust and conflicting policy before scan diagnosis |
| Update scan: client `WUAHandler.log`, `ScanAgent.log` | A current scan completes successfully against intended SUP; record scan time/result | WUA HRESULT or scan failure: preserve code; check SUP endpoint, TLS, policy and metadata rather than assuming no updates apply |
| Package/DP: console host `%TEMP%\PatchDownloader.log`; Monitoring > Distribution Status > Content Status | Download wizard succeeds for all selected updates; package distribution succeeds on the intended DP | Missing file, signature/hash error, access failure or pending distribution: reconcile acquisition/source rights and inspect site `distmgr.log`/`PkgXferMgr.log` and DP status |
| Client content: client `CAS.log`, `ContentTransferManager.log`, `DataTransferService.log` | Selected update content downloads successfully from an approved internal source, with source and completion recorded | No location, failed transfer or unavailable content: verify DP association/status and content-source policy; internet fallback cannot solve disconnected content |
| Installation/restart: client `UpdatesDeployment.log`, `UpdatesHandler.log` and Software Center | Selected update installs; required restart completed; fresh scan confirms installed/compliant state | Failed/pending update or restart: retain error and follow supported update recovery; do not expand deployment |
| Reporting: Monitoring > Deployments, intended update-group deployment | The same pilot reports compliance after installation/restart; reconcile update ID and timestamps | Unknown/old state: inspect client state messages (`StateMessage.log`) and reporting flow; local success alone does not close reporting |

Use the logs together; no one file proves the full cycle. An update may be
**Not Required** on a client, so select an applicable pilot update when proving
installation. A completed scan with no applicable updates proves scanning only.

Sources: [Setup wizard completion](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/setup-wizard-central-primary),
[SUP verification examples](https://learn.microsoft.com/en-us/intune/configmgr/sum/get-started/software-update-point-ssl#verify-functionality-with-configuration-manager),
[log-file reference](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/hierarchy/log-files)
and [software update troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/troubleshoot-software-update-deployments).

**Acceptance record:** site/client build, selected update IDs, target collection
membership, deployment settings, actual source endpoints, per-stage timestamps,
result/log references, restart evidence and final reported compliance. These are
required lab observations, not results already established by this repository.
