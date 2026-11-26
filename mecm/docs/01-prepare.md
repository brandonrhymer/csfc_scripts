# 1. Prepare the VM and offline files

For an existing site, record these settings privately rather than recreating the VM. For a new build, complete this worksheet with the virtualization, directory, and network administrators before installing software.

| Record | Value to obtain |
| --- | --- |
| VM | Hypervisor, hostname, supported Windows Server version and installation mode, CPU, memory, disk capacity |
| Network | Address, DNS servers, domain, time source, client subnets, permitted ports |
| Storage | OS volume, SQL data/log/tempdb locations, site folder, content and backup capacity |
| Versions | Configuration Manager baseline/build, Windows build, SQL edition/build/CU, ADK/WinPE, ODBC, .NET and redistributable versions per host |
| Accounts | Named setup operator, SQL administrator, approved service identities; no passwords in this sheet |
| Roles | Site server, SQL, SMS Provider, management point, distribution point, WSUS/software update point hosts |

Use Microsoft's [supported configurations](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/supported-configurations) and [site prerequisites](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/prerequisites-for-installing-sites) for the exact selected build. Size storage for the products, languages, clients, SQL growth, update content, and backups you actually need. This guide does not assume a hypervisor or invent a VM size.

## Gather files on an approved connected workstation

Keep a manifest with filename, version, source URL, SHA-256, download date, and purpose. Gather:

- Licensed Windows Server installation media and servicing updates; matching optional-feature source files if needed.
- Configuration Manager **baseline** media for a new site, plus prerequisite files downloaded with that media's `SMSSETUP\BIN\X64\setupdl.exe`. Run Setup Downloader and choose an empty output folder. Copy the complete output, not selected files.
- A supported SQL installer and cumulative update, plus an offline management tool if needed. If using evaluation software, record its expiry and licensing plan privately.
- The supported **x64 Microsoft ODBC Driver for SQL Server** installer. Install it on the connected Setup Downloader host before running `setupdl.exe`, and on every applicable role host below; it is not supplied/maintained as a complete ongoing prerequisite by the downloader.
- Version-required .NET and Visual C++ dependencies. Obtain full offline packages, not web bootstrap installers.
- A supported Windows ADK and separate WinPE add-on, using their offline-download options. The primary site and SMS Provider require ADK components even when the first goal is patching rather than OS deployment. Map components to hosts below.
- Any approved certificates, certificate chain and offline revocation arrangements required by the chosen HTTPS design.

Use [Setup Downloader](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/setup-downloader). A ConfigMgr servicing update is not automatically new-site baseline media.

Use the exact baseline's downloader, give its operator Full Control on the
output folder, and retain `C:\ConfigMgrSetup.log`. Its `/VERIFY` option checks
an existing prerequisite folder. Collect the complete offline installers for
separate dependencies; a web bootstrapper will not work inside the enclave.

## Match prerequisites to each host

**Source review: 2026-11-25.** Before a build or upgrade, recheck Microsoft's
[role requirements](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/site-and-site-system-prerequisites),
[prerequisite checks](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/list-of-prerequisite-checks)
and [ADK support matrix](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/support-for-windows-adk)
against the chosen ConfigMgr release. Apply the union of requirements for
colocated roles. Do not install every feature on every server.
The [ADK feature requirements](https://learn.microsoft.com/en-us/intune/configmgr/osd/plan-design/infrastructure-requirements-for-operating-system-deployment#windows-adk-features)
map Deployment Tools/WinPE to site servers and Providers; USMT is not required
on a separate Provider.

| Role | Windows features and components to verify |
| --- | --- |
| Primary site | Supported Windows Server **Desktop Experience**; .NET Framework 3.5; Remote Differential Compression; supported ADK Deployment Tools and USMT, plus matching separate WinPE add-on; build-required .NET/VC++ and x64 ODBC |
| SMS Provider | Supported ADK Deployment Tools and separate WinPE add-on; IIS for administration-service certificate binding; build-required .NET and x64 ODBC |
| MP | BITS and its selected dependencies; IIS ISAPI Extensions, Windows Authentication, IIS 6 Metabase Compatibility, IIS 6 WMI Compatibility; build-required .NET/VC++ and x64 ODBC |
| DP | Remote Differential Compression; those four IIS components; applicable .NET/VC++; BITS IIS Server Extension is not required just for a DP |
| SUP | WSUS and completed post-install configuration; .NET Framework 3.5; default IIS components; build-required .NET and x64 ODBC |
| Offline service connection point | .NET Framework 3.5; build-required .NET and x64 ODBC |
| SQL host | Supported SQL and x64 ODBC; Remote Registry enabled for site installation |
| Site server with remote SUP | WSUS Administration Console matching the SUP's WSUS version |

Install the complete selected ADK feature set on a colocated site/Provider:
**Deployment Tools**, **User State Migration Tool (USMT)**, then the matching
separate **Windows PE add-on**. For separate hosts, record each role's required
components and prerequisite-check results. Do not select an ADK solely because
it is the newest. A Server Core DP is a separate supported-role scenario; it
does not make Server Core supported for the primary site.

For ConfigMgr **2403 and later**, .NET Framework **4.8 or later is required** on
the site server and applicable site systems even if a prerequisite check reports
only a warning. Install it in addition to the separate 3.5 Windows feature where
required; Setup does not automatically install 4.8. Reboot after
prerequisite installation when required, before launching site Setup. Use the
Windows media matching that host to enable 3.5 offline; retain the servicing
result rather than repeatedly changing a domain-wide repair-source policy.

As of the review date, Microsoft's ODBC check requires **18.4.1.1 or later for
ConfigMgr 2503–2603**, and **18.6.2.1 or later for 2609 onward**, subject to its
validated-version list and exclusions. **Do not install 18.6.1.1** for ConfigMgr;
**18.7.1.1 is incompatible with 2603 and earlier**. The minimum is not permission
to use every newer driver. Recheck the
[ODBC guidance](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/list-of-prerequisite-checks#odbc-driver-for-sql-server)
before acquisition, including when maintaining an older baseline.

On each host, use **Programs and Features** to record installed ADK/WinPE,
ODBC and redistributable versions. In **Server Manager > Manage > Add Roles and
Features**, inspect role services/features against the host's checklist. For
.NET 4.x, record the registry `Release` value and compare it with Microsoft's
[version-detection table](https://learn.microsoft.com/en-us/dotnet/framework/install/how-to-determine-which-versions-are-installed).
Retain actual values, pending-reboot disposition and prerequisite logs privately.

## Transfer and prepare

1. Scan the files using the team's approved transfer procedure. Retain signatures and publisher download records.
2. Calculate hashes on the connected machine and again after transfer. Example: `Get-FileHash 'C:\Staging\installer.exe' -Algorithm SHA256`. Compare the entire hash. A matching hash proves the copy matches, not that its source is trustworthy.
3. Provision Windows on the VM, configure DNS/time, and join the approved domain. Apply the approved Windows updates and reboot when required.
4. Install only Windows roles/features required by the selected site roles. Use the version-specific prerequisite page; do not enable every IIS feature or change a blanket servicing-policy GPO.
5. Complete the [SQL and setup-account checklist](sql-and-accounts.md), including its read-only checks. Record the actual instance identity; a default instance uses the server name.
6. Complete the approved [AD publishing branch](ad-publishing.md) and [communication-security branch](communication-security.md). Have the network administrator allow the documented role-to-role and client-to-role ports. Do not disable firewalls.
7. Run Setup's prerequisite checker and resolve each error. Record each warning and its disposition.

**Stage evidence:** completed version/host/identity worksheet, file manifest,
matching transfer hashes, selected security and publishing branches, SQL checks
and prerequisite-check log. Resolve every blocking error; document warnings and
their owner-approved disposition. Actual build numbers and capacity must be
supplied locally before execution; this repository does not prescribe them.
