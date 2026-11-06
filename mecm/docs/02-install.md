# 2. Create the Configuration Manager site

**If your site already exists, use the verification section below.** The native installation wizard is the installation path; no earlier prototype script is required.

For a new standalone primary site, follow Microsoft's [Setup wizard procedure](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/setup-wizard-central-primary) with the completed stage 1 worksheet:

1. Sign in with the approved setup account and launch `SMSSETUP\BIN\X64\setup.exe` from the selected baseline media.
2. Choose installation of a primary site. Choose standalone unless the approved design explicitly requires a hierarchy.
3. Enter the approved license/evaluation choice. Accept terms only as authorized by your organization.
4. Choose **Use previously downloaded files** and select the complete prerequisite folder transferred in stage 1.
5. Enter the approved site code/name and installation folder. The examples use LAB and `C:\ConfigMgr`; do not reuse an existing site code for a second site.
6. Enter the SQL server's fully qualified name. For a default instance, do not enter a fabricated named instance. Confirm database and SQL file locations with the SQL administrator.
7. Choose the SMS Provider location. This component lets the console read and change the site.
8. Configure management-point and distribution-point roles and communication security according to the approved certificate design. A management point delivers client policy; a distribution point stores installation files. Do not downgrade security to bypass a failed check.
9. Choose the service connection point's **offline** mode for the disconnected site. This role handles site servicing; it is separate from WSUS patch imports.
10. Run the prerequisite check. Resolve errors, review warnings, then begin installation. Save the result and logs.

## Verify the existing installation

Run locally on the site server in Windows PowerShell:

```powershell
C:\Admin\mecm\scripts\get-site-status.ps1
```

Review `C:\ConfigMgrSetup.log` and `C:\ConfigMgrPrereq.log`. Open the console and confirm your site appears under **Administration > Site Configuration > Sites**. In **Monitoring > System Status**, inspect Site Status and Component Status. Use `C:\ConfigMgr\Logs` for site component logs and CMTrace to read them. If the provider query fails, inspect `SMSProv.log` on the provider host and verify namespace access before assuming the site is absent.

**Stage done:** Setup reports completion and your site exists. Record the date, build, setup result, and operator. A created site does not prove that WSUS works or clients can install updates. Provider registration and running services are diagnostic clues, not a full health test. Never rerun installation merely because a service check fails.
