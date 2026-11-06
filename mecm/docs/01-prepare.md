# 1. Prepare the VM and offline files

For an existing site, record these settings privately rather than recreating the VM. For a new build, complete this worksheet with the virtualization, directory, and network administrators before installing software.

| Record | Value to obtain |
| --- | --- |
| VM | Hypervisor, hostname, supported Windows Server version, CPU, memory, disk capacity |
| Network | Address, DNS servers, domain, time source, client subnets, permitted ports |
| Storage | OS volume, SQL data/log/tempdb locations, site folder, content and backup capacity |
| Versions | Configuration Manager baseline/build, Windows build, SQL edition/build/CU, ADK and WinPE version if used |
| Accounts | Named setup operator, SQL administrator, approved service identities; no passwords in this sheet |
| Roles | Site server, SQL, SMS Provider, management point, distribution point, WSUS/software update point hosts |

Use Microsoft's [supported configurations](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/supported-configurations) and [site prerequisites](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/prerequisites-for-installing-sites) for the exact selected build. Size storage for the products, languages, clients, SQL growth, update content, and backups you actually need. This guide does not assume a hypervisor or invent a VM size.

## Gather files on an approved connected workstation

Keep a manifest with filename, version, source URL, SHA-256, download date, and purpose. Gather:

- Licensed Windows Server installation media and servicing updates; matching optional-feature source files if needed.
- Configuration Manager **baseline** media for a new site, plus prerequisite files downloaded with that media's `SMSSETUP\BIN\X64\setupdl.exe`. Run Setup Downloader and choose an empty output folder. Copy the complete output, not selected files.
- A supported SQL installer and cumulative update, plus an offline management tool if needed. If using evaluation software, record its expiry and licensing plan privately.
- Version-required .NET and Visual C++ dependencies. Obtain full offline packages, not web bootstrap installers.
- A supported Windows ADK and separate WinPE add-on if the selected setup/roles need them. Use their offline-download option; operating-system deployment is beyond this first patching goal.
- Any approved certificates, certificate chain and offline revocation arrangements required by the chosen HTTPS design.

Use [Setup Downloader](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/setup-downloader). A ConfigMgr servicing update is not automatically new-site baseline media.

## Transfer and prepare

1. Scan the files using the team's approved transfer procedure. Retain signatures and publisher download records.
2. Calculate hashes on the connected machine and again after transfer. Example: `Get-FileHash 'C:\Staging\installer.exe' -Algorithm SHA256`. Compare the entire hash. A matching hash proves the copy matches, not that its source is trustworthy.
3. Provision Windows on the VM, configure DNS/time, and join the approved domain. Apply the approved Windows updates and reboot when required.
4. Install only Windows roles/features required by the selected site roles. Use the version-specific prerequisite page; do not enable every IIS feature or change a blanket servicing-policy GPO.
5. Prepare SQL with the supported collation, authentication, memory, and database compatibility settings. Verify the selected SQL version against [SQL support](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/support-for-sql-server-versions). Do not infer the instance name from its disk path; a default instance uses the server name.
6. Have the directory administrator review schema extension and System Management container permissions where applicable. Have the network administrator allow the documented role-to-role and client-to-role ports. Do not disable firewalls.
7. Run Setup's prerequisite checker and resolve each error. Record each warning and its disposition.

**Stage evidence:** completed worksheet, file manifest, matching transfer hashes, and prerequisite-check log. Missing build numbers prevent us from specifying a dependable package/version list today.
