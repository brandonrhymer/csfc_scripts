# MECM: start here

Microsoft Configuration Manager (also called MECM) manages computers, applications, and Microsoft updates. This toolkit is for administrators learning both Configuration Manager and PowerShell.

## Work through these stages

| Stage | Guide | Done when |
| --- | --- | --- |
| 1 | [VM and offline prerequisites](docs/01-prepare.md) | The VM and version-matched installation files are ready; prerequisite checks pass. |
| 2 | [Create the site](docs/02-install.md) | Native Setup finishes and the site is created. |
| 3 | [Configure and transfer the first patches](docs/03-first-patches.md) | A pilot client can scan, download, install, and report a Microsoft update. |
| 4 | [Routine operations](docs/04-maintain.md) | Each change has a recorded result and a tested recovery plan. |

**Examples only:** `LAB` is a placeholder site code, `C:\ConfigMgr` is an example installation path, and `files.example.invalid` is a reserved example hostname. Replace them with approved local values at run time. Keep the completed environment worksheet outside Git. If your site already exists, start with stage 2 verification; do not reinstall it to follow this guide. No stage has been validated against a Windows lab.

This guide assumes a site with no internet connection. The connected WSUS server already serves another disconnected network. Export only its existing data. Do not change its products, languages, classifications, approvals, synchronization, or cleanup jobs for this toolkit. If required content is missing, arrange a separate download source with its owner.

## Detailed procedures

For the full operating lifecycle, use the [Configuration Manager operating guides](https://github.com/brandonrhymer/csfc_guides/blob/main/guides/mecm/README.md) in `csfc_guides`. The thirteen source-reviewed drafts cover architecture, operator access, collection targeting, client settings and health, content, production patching, applications, client lifecycle, reporting, site operations, inventory and conditional PKI maintenance. Installation and script-specific instructions remain here. Both sets require target-system validation before operational use.

| Task | Guide |
| --- | --- |
| Confirm required software and setup rights | [Role prerequisites](docs/01-prepare.md#match-prerequisites-to-each-host) and [SQL/accounts](docs/sql-and-accounts.md) |
| Prepare AD's System Management container | [AD publishing](docs/ad-publishing.md); this is separate from device discovery |
| Configure role security | [PKI HTTPS or Enhanced HTTP](docs/communication-security.md) and [WSUS/SUP setup](docs/wsus-sup-setup.md) |
| Discover and install one client | [Boundaries, discovery and onboarding](docs/client-onboarding.md) |
| Acquire missing patches and diagnose progress | [Content acquisition](docs/offline-content-acquisition.md) and [verification checkpoints](docs/verification-checkpoints.md) |
| Protect and update the site | [Backup/recovery](docs/backup-recovery.md) and [offline site servicing](docs/offline-site-servicing.md) |
| Check role maintenance readiness | [Distribution point](../docs/maintenance/distribution-point.md) and [WSUS/SUP](../docs/maintenance/wsus-sup.md) |
| Use the optional client maintenance products | [Client maintenance index](client-maintenance/README.md), including its Run Scripts walkthrough |

**Individual ZIPs:** this index describes the full repository. An individual
product package contains its selected script/runbook and required common guides;
links to other scripts or client-maintenance products are optional sibling
products and may not be present. Start with the package's selected runbook and
obtain sibling products separately. Markdown links do not automatically include
their targets in a package. The source guides were reviewed against Microsoft
documentation on **2026-11-25**; recheck version-specific support before execution.

## Run a script

1. Copy this directory to your approved administration workstation. Read the script and its guide first.
2. Use **Windows PowerShell 5.1**. The PowerShell 7 requirement elsewhere in this repository applies to the separate redaction script.
3. For collection/application scripts, open the console menu and select **Connect via Windows PowerShell**. Confirm the prompt shows `LAB:\`. Use an absolute script path because that prompt is a site drive, not a disk folder.
4. Read help: `Get-Help C:\Admin\mecm\scripts\create-collections.ps1 -Full`.
5. Run the preview command in the guide. Review its output before creating anything.

A parameter is a named input such as `-MsiPath`. Quotes keep a path with spaces together. `-WhatIf` describes proposed changes. It cannot predict permissions, connectivity, or a successful installation. If policy blocks a script, use your team's signing/approval process; do not disable organization policy.

## Scripts

| Script | Run on | Effect |
| --- | --- | --- |
| [get-site-status.ps1](scripts/get-site-status.ps1) | Your site server | Reads services, SQL service, provider registration, and WSUS settings. |
| [wsus-export.ps1](scripts/wsus-export.ps1) | Connected WSUS, elevated | Exports metadata and copies existing content into a new transfer folder. |
| [create-collections.ps1](scripts/create-collections.ps1) | Console/site drive | Creates three empty collections; no deployment. |
| [add-msi-application.ps1](scripts/add-msi-application.ps1) | Console workstation | Reads MSI properties; creates an application only with `-Create`. |

A collection is a group of computers. A limiting collection sets its maximum possible membership. A deployment tells clients to install something. Creating a collection or an application does not deploy it.

Read [validation requirements](docs/validation.md) before lab use. These are small starting tools, not an unattended site installer. Keep passwords, licenses, exported catalogs, installers, and internal logs out of Git.

## Repository privacy

Never commit passwords, keys, tokens, credentials, actual hostnames, IP addresses, domain names, internal logs, or completed environment worksheets. Use labeled placeholders or reserved examples. Review the full staged diff and the commits being published before each push. Keep source media and transfer bundles outside the repository. Public Microsoft documentation links are references, not local environment names.
