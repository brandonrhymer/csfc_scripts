# MECM validation requirements

These scripts have toolkit-specific interfaces. Compatibility with other scripts
of the same name has not been established; review the supplied help rather than
assuming identical parameters or behavior.

## Recorded isolated checks

- All four operational scripts parsed without syntax errors using portable PowerShell 7.4.13 on Linux.
- `tests/check-collections.ps1` used fake ConfigMgr commands to check preview/no writes, the three collection names, repeat-run behavior, and wrong-site rejection. All four cases passed. This tests control flow, not ConfigMgr API behavior.
- Relative Markdown links and Git whitespace checks passed.
- Cmdlet usage reviewed against Microsoft documentation: [New-CMDeviceCollection](https://learn.microsoft.com/en-us/powershell/module/configurationmanager/new-cmdevicecollection), [New-CMApplication](https://learn.microsoft.com/en-us/powershell/module/configurationmanager/new-cmapplication), and [Add-CMMsiDeploymentType](https://learn.microsoft.com/en-us/powershell/module/configurationmanager/add-cmmsideploymenttype). Deployment content is passed as the MSI file path.
- Manual review confirmed no script creates deployments, changes shared WSUS settings/approvals, runs cleanup, installs a site, changes Group Policy, or embeds credentials.

To repeat local checks, start a fresh PowerShell process for each test:

```powershell
powershell.exe -NoProfile -File .\mecm\tests\check-syntax.ps1
powershell.exe -NoProfile -File .\mecm\tests\check-collections.ps1
```

The tests do not contact a site. Run them in a fresh shell because the collection test substitutes command names for its test only.

## Required Windows lab checks

| Check | Expected result | Status |
| --- | --- | --- |
| Windows PowerShell 5.1 parser and help | Scripts parse and help/examples display | Not run |
| Site-status script on LAB | Provider and service/WSUS results correlate with console and logs | Not run |
| WSUS export preview | No folder or export is created | Not run |
| WSUS export with spaces in paths | New metadata, export log and complete additive content copy | Not run |
| Export failures | Existing target rejected; export failure stops copy; Robocopy code >=8 reports failure | Reviewed only |
| Collections on test site | Empty collections with correct limiting scope; repeat leaves them unchanged | Mock tested only |
| MSI preview | Properties match a known lab MSI; file remains unchanged; no app created | Not run |
| MSI create/duplicate/failure | Correct generated deployment type; duplicate rejected; partial app reported | Not run |
| Disconnected patch pilot | Scan, internal download, installation/reboot and console compliance succeed | Not run |

No production systems were contacted or changed. Syntax checks on Linux do not validate Windows COM, WSUS utilities, Windows PowerShell 5.1 runtime behavior, permissions, or installed ConfigMgr module compatibility.

## Environment requirements and limits

- Confirm installed ConfigMgr build, Windows build, SQL edition/CU/evaluation expiry, and intended ADK/WinPE needs before choosing an exact offline dependency list.
- Confirm provider and SUP hosts, WSUS post-install state/database/content path/ports/TLS, client boundaries, source-share permissions, and certificate design.
- Confirm the shared connected WSUS's existing product/classification/language coverage and downloaded-file coverage with its owner. The export cannot create missing content.
- Agree on a separate connected acquisition workflow if the existing files are insufficient, particularly for UUP. Do not change the shared server as a workaround.
- MSI-only application creation is intentionally limited; vendor transforms, EXE installers, dependencies, deployment scheduling and detection exceptions need human review.
- VM creation and prerequisite installation remain documented operator tasks until hypervisor, versions and sizing are known. Import, deployments and maintenance windows are deliberate console/operator tasks rather than automatic actions.

The guides describe completion evidence; they do not certify any stage as complete. Any existing site requires local health and patch-capability verification.

## Additional coverage and limits

The application duplicate lookup uses `-ShowHidden -DisableWildcardHandling` and retains exact name comparison, following [Get-CMApplication](https://learn.microsoft.com/en-us/powershell/module/configurationmanager/get-cmapplication). Five isolated tests execute that guard with a fake query: visible duplicate, hidden duplicate, literal wildcard name, similar name, and absent name. All pass. They verify the query arguments and decisions, not the live provider's matching behavior or the MSI COM path.

```powershell
powershell.exe -NoProfile -File .\mecm\tests\check-application-duplicates.ps1
```

The status script states in its help and output that SQL checking covers only the local default instance. The install guide directs operators to inspect named/remote instances separately. Collection help and the maintenance guide explain manual refresh, Update Membership, and a reviewed schedule before query-based membership.

The recorded checks used PowerShell 7.4.13 on Linux. No Windows PowerShell 5.1, Windows services, MSI COM, WSUS or real MECM execution was performed. These results do not establish lab or deployment readiness.
