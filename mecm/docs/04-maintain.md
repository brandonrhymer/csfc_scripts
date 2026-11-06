# 4. Routine operations

## Create the starter collections

In **Connect via Windows PowerShell**, replace `LAB` with your site code and run:

```powershell
C:\Admin\mecm\scripts\create-collections.ps1 -SiteCode 'LAB' -WhatIf
C:\Admin\mecm\scripts\create-collections.ps1 -SiteCode 'LAB'
```

This creates `LAB - Pilot`, `LAB - Servers`, and `LAB - Workstations`, limited to All Systems unless you supply another `-LimitingCollectionId`. They start empty. Existing collections with those names are left alone; inspect their membership and deployments because they may not be empty. Add a few direct members first. These collections use **manual refresh**: membership is not reevaluated on a recurring schedule. After changing membership rules, select the collection and choose **Update Membership**, wait for evaluation, then check **Show Members** again. Before using query-based membership, review the query and an appropriate full membership update schedule in **Properties > Membership Rules**. Enable that reviewed schedule explicitly; do not assume this script sets one.

## Add an MSI application

An application holds software information. Its deployment type holds install commands, content, and detection rules. Use a permanent UNC source folder readable by the site server, with only that application's MSI and companion files. Protect its write access.

```powershell
$msi = Read-Host 'Full UNC path to the MSI'
C:\Admin\mecm\scripts\add-msi-application.ps1 -MsiPath $msi
C:\Admin\mecm\scripts\add-msi-application.ps1 -MsiPath $msi -SiteCode 'LAB' -Create -WhatIf
C:\Admin\mecm\scripts\add-msi-application.ps1 -MsiPath $msi -SiteCode 'LAB' -Create
```

The first command reads the MSI database without installing the product. The last creates the application and an MSI deployment type. Review the generated commands, product-code detection, installation context, architecture requirements, dependencies, return codes, reboot handling, and uninstall behavior before distributing or deploying it. The script does not infer transforms, vendor prerequisites, licensing, or EXE switches. Per-user MSIs need particular attention; this script does not force system installation.

A failed deployment-type creation can leave an application without a deployment type. Inspect that object and finish it in the console, or remove it manually only after confirming it is unused. The script checks visible and hidden applications, treats wildcard characters in the name literally, and stops on an exact duplicate name rather than modifying existing software.

For an EXE, use the vendor's documented silent install/uninstall commands and a tested file/registry detection rule in the console. There is no universal EXE query that supplies these safely.

For a new software version, retain the old source and create/review the new version. Test install, upgrade, detection, and uninstall on a disposable pilot. Configure supersedence only after deciding whether the old version must be removed. Distribute content, confirm success, then make a manual Available deployment to Pilot. Expand scope only after reviewing results.

## Maintenance windows and deployments

In **Assets and Compliance > Device Collections**, open the intended collection's **Properties > Maintenance Windows**. Add a named window with an explicit time zone, recurrence, start, duration, and type (software updates or all deployments). Record the owner's reboot agreement. See [maintenance windows](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/manage/collections/use-maintenance-windows).

Inspect every collection containing the pilot: multiple windows can expand its permitted time. A maintenance window is not a deployment and does not guarantee that a user cannot initiate an Available installation outside it. For Required deployments, review the deadline and the settings allowing installation/restart outside maintenance windows. Leave overrides off unless explicitly approved. Allow enough time for the update's maximum runtime and restart. Test the effective schedule before applying it to servers.

## Regular checklist

| When | Work and evidence |
| --- | --- |
| Before each patch cycle | Review target membership, source coverage, free space, transfer logs, and last successful scan. Repeat stage 3 with a new transfer folder. |
| After each pilot | Review install/reboot results and compliance failures; record the decision before expanding deployment. |
| Weekly | Review Site/Component Status, synchronization, content distribution, client health, SQL and content disk growth. Investigate repeated errors. |
| Backup schedule | Verify the configured site/database backups and separately protect package sources, content, certificates and required recovery material. Test restoration in isolation; a VM snapshot alone is not a recovery plan. |
| Monthly/change window | Review local SUP cleanup and SQL maintenance with their owners. Use the version's supported maintenance procedures. Do not run generic delete/decline scripts or touch the shared connected WSUS. |
| Before site servicing | Check support and prerequisites; use the service connection tool's documented offline workflow and stage/pilot the update. WSUS export does not service Configuration Manager itself. |
| Before evaluation expires | Arrange licensed SQL/ConfigMgr conversion with the owners; record dates and supported conversion steps. |

If a deployment causes trouble, stop expansion and disable/remove the affected deployment after review. That does not uninstall software already installed or necessarily cancel work already executing. Use the vendor's supported recovery/uninstall process and verify each affected client.
