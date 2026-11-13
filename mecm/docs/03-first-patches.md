# 3. Configure the site and transfer the first patches

Goal: one approved pilot computer scans, installs a Microsoft update from LAB, and reports the result. Keep a record of the update, client, deployment, timestamps, and logs.

## Configure LAB

1. Verify the SMS Provider and console access using stage 2. Verify WSUS is installed and its post-install configuration completed on the intended update-point host. Record its database, content directory, ports, and TLS settings. Do not guess them from the site installation folder.
2. In **Administration > Site Configuration > Servers and Site System Roles**, add or verify the **Software update point (SUP)** role on that WSUS host. The SUP supplies update scan metadata. Match its ports/TLS settings to WSUS. For the disconnected standalone site, select **Do not synchronize from Microsoft Update or upstream data source**. Configure this site's SUP through Configuration Manager, not through independent WSUS approvals. See [SUP configuration](https://learn.microsoft.com/en-us/intune/configmgr/sum/get-started/install-a-software-update-point).
3. Configure boundaries (client network locations) and a boundary group for the pilot subnet. Assign LAB and the intended distribution point. Avoid overlapping site assignment. Verify distribution-point content access.
4. Enable discovery only for the intended scope; install the Configuration Manager client on one approved pilot using your approved client-install method. Verify the client is assigned to LAB and receives policy.
5. In **Administration > Client Settings**, verify software updates are enabled for the pilot. Inspect existing Windows Update policies (`gpresult /h C:\Temp\pilot-policy.html`) if scans go elsewhere. Resolve a specific conflicting policy with its owner. Do not apply a blanket servicing-policy GPO.
6. Create the starter collections (stage 4). Add only the selected client to Pilot with a direct membership rule. Inspect **Show Members** before any deployment.

## Export without changing the shared connected WSUS

Coordinate a quiet export window with its owner. Read its last synchronization result and existing product/classification/language coverage. If it does not cover the pilot, record the gap and obtain an independent source; do not change this shared server to make the export work.

Run elevated **locally on connected WSUS**. Replace the example content path with its recorded WSUSContent folder. Choose a new transfer folder outside that source tree:

Both paths must use absolute local drive-letter names, such as
`D:\WSUS\WsusContent`, with their actual long directory names. The destination's
parent must already exist, and the destination itself must not exist. Spaces
and a trailing backslash are supported. Relative paths, `.`/`..` segments,
UNC/device/provider paths, mapped or SUBST drives, custom PowerShell drives,
short-name aliases, wildcard syntax, reserved device names, and trailing dots
or spaces in directory names are rejected.

The script checks native local-volume identities and existing path components
before comparing the source and destination trees. It rejects an equal path,
an ancestor or descendant, and any junction, symbolic link or mounted-folder
reparse point along either path. It also scans all source directories and rejects
reparse points anywhere in the source contents before creating output. This
read-only inventory can take time on a large content tree; an inaccessible
directory stops export. These checks do not resolve arbitrary aliases into
supported paths. Supply the direct local paths instead.

Keep the source and destination parent protected from concurrent changes for
the whole export window. Preflight does not lock the filesystem or prevent a
different process from replacing a directory after it has been checked. Follow
the [Windows path naming rules](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file)
and [.NET path format guidance](https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats)
when selecting paths.

```powershell
C:\Admin\mecm\scripts\wsus-export.ps1 -ContentPath 'D:\WSUS\WsusContent' -Destination 'F:\LAB-transfer-2026-11-06' -WhatIf
C:\Admin\mecm\scripts\wsus-export.ps1 -ContentPath 'D:\WSUS\WsusContent' -Destination 'F:\LAB-transfer-2026-11-06'
```

The script invokes Microsoft's `WsusUtil.exe`; **wsus-export.ps1 is not built in**. It exports catalog metadata and copies files already present. It neither downloads missing updates nor exports a ready-to-deploy Configuration Manager package. Copying all existing content may be large. Preserve the export/copy logs and follow the approved media scan/hash procedure.

`-WhatIf` performs the path checks and source inventory without creating the
transfer directory or invoking export/copy. A real run uses additive copying
(`/E`, no `/MIR` or `/PURGE`) and retains `/XJ` as a copy-time junction exclusion.
An export or copy failure leaves its new folder for diagnosis; select another
new destination after reconciliation instead of overwriting an earlier transfer.

## Import on the disconnected SUP

Follow [Microsoft's disconnected synchronization procedure](https://learn.microsoft.com/en-us/intune/configmgr/sum/get-started/synchronize-software-updates-disconnected). Copy transferred WSUSContent into the destination's actual WSUSContent directory, preserving subfolders and license files. Use additive copying, never `/MIR` or `/PURGE`. Example, elevated on the disconnected SUP only:

```powershell
robocopy 'F:\LAB-transfer-2026-11-06\WsusContent' 'D:\WSUS\WsusContent' /E /COPY:DAT /R:2 /W:2
# Robocopy exit codes 8 and above mean failure. Check immediately.
if ($LASTEXITCODE -ge 8) { throw 'Content copy failed. Review the output.' }
& "$env:ProgramFiles\Update Services\Tools\WsusUtil.exe" import 'F:\LAB-transfer-2026-11-06\metadata.xml.gz' 'C:\Temp\LAB-import.log'
if ($LASTEXITCODE -ne 0) { throw 'Metadata import failed. Review LAB-import.log.' }
```

Create the log directory first. Review the import log even when the exit code is zero. In the ConfigMgr console run **Software Library > Software Updates > All Software Updates > Synchronize Software Updates**. Read `WCM.log`, `WSUSCtrl.log`, and `wsyncmgr.log` for configuration, WSUS health, and synchronization results. After initial catalog import, select the required products/classifications/languages in SUP properties and synchronize again. Keep them within the source's coverage.

## Prepare installation files and test

Metadata describes updates. Installation files contain the actual patch. They are separate. An update appearing in the console is not evidence that its files are available.

1. Select a small set of applicable updates for the pilot. Remove the default date filters if older updates are needed. Record the update IDs, architecture, languages, and required file list.
2. Use existing transferred files if complete. If files are missing, obtain **all** required files through a separately approved connected download workflow. Catalog downloads may not supply every file needed by a selected update, especially UUP/express content. Do not approve updates on the shared WSUS merely to force downloads. This toolkit does not automate missing-content acquisition.
3. Place verified files in a local network staging folder. In **Download Software Updates**, choose **Download software updates from a location on my network**. Create a deployment package with its own permanent UNC source folder, distinct from the staging folder and other package sources. Give the wizard operator and SMS Provider computer the documented write access. See [Download updates](https://learn.microsoft.com/en-us/intune/configmgr/sum/deploy-use/download-software-updates).
4. Check wizard completion and `PatchDownloader.log` on the machine running the console. Missing content is a stop point: obtain it and rerun the download. Distribute the package to the pilot's distribution point and confirm success under **Monitoring > Distribution Status > Content Status**.
5. Create a software update group (a named list of updates). Deploy it manually to the verified Pilot collection as **Available**, with agreed availability and reboot settings. Do not select all devices or create an automatic deployment rule. Confirm content is available locally; internet fallback cannot work here.
6. On the pilot, retrieve machine policy and run the Software Updates Scan Cycle and Deployment Evaluation Cycle from the Configuration Manager control panel. Install from Software Center during the approved window. Reboot if required.
7. Inspect client logs in `C:\Windows\CCM\Logs`: `LocationServices.log`, `WUAHandler.log`, `ScanAgent.log`, `UpdatesDeployment.log`, `UpdatesHandler.log`, `CAS.log`, and `ContentTransferManager.log`. Confirm installation locally and allow compliance reporting to reach **Monitoring > Deployments**.

**Stage done:** retain evidence of a successful scan, content download from the internal distribution point, installation/reboot, and reported compliance. Until then, first-patch capability remains unverified.
