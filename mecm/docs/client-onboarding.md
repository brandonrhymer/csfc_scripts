# Configure boundaries, discovery and one pilot client

Use this after [site installation](02-install.md) and
[SUP setup](wsus-sup-setup.md). Record one approved pilot computer, its current
address, OU, intended site/MP/DP/SUP, security mode and maintenance window.
Use a disposable lab client for acceptance; these instructions have not been
validated against a running site in this project.

## Associate the pilot's network with site systems

1. In **Administration > Hierarchy Configuration > Boundaries**, select
   **Create Boundary**. For a small pilot, choose **IP address range** and enter
   the approved start/end addresses covering the client's actual active address.
   Check VPN/multiple adapters with the network owner; do not invent a range from
   the site server's address.
2. In **Boundary Groups**, create or select the intended pilot group. On
   **General**, add that boundary. On **References**, enable site assignment and
   select the approved site, such as the placeholder `LAB`.
3. In **Site system servers**, add the server hosting the intended DP and the
   server hosting the intended SUP. Add each distinct host when roles are remote.
   A colocated DP/SUP is one server entry. Verify applicable MP association if
   the design uses preferred management points.
4. Review **Relationships**, neighbor-group fallback times and default-site-group
   behavior with the site owner. Do not enable broad fallback merely to pass the
   pilot. Avoid overlapping groups with conflicting automatic site assignments.
5. Record membership and role associations. A new site's SUP is not automatically
   placed in its default site boundary group. After the client gets policy,
   verify its actual SUP URL in `LocationServices.log` before troubleshooting scans.

Sources: [boundary-group procedures](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/configure/boundary-group-procedures)
and [SUP selection and fallback](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/configure/boundary-groups-software-update-points).

## Discover only the approved OU

Discovery creates resource records; it does not install the client. AD Forest
Discovery finds network locations and can create boundaries; it is not a
replacement for AD System Discovery of computers. Publishing under
`System Management` is a separate [AD task](ad-publishing.md).

1. Confirm the pilot's computer account exists in the approved OU and its DNS
   name resolves from the site server to a usable address. Give the chosen AD
   System Discovery account read access to that location. For the same-domain
   default, check the site-server computer account's access; do not grant Domain
   Admin merely for discovery.
2. Open **Administration > Hierarchy Configuration > Discovery Methods**.
   Select **Active Directory System Discovery** for the site and **Properties**.
3. On **General**, add the OU's LDAP path using the folder/new icon. Browse to
   confirm the intended domain and OU. Select recursion only if its children are
   approved; record exclusions. Leave discovery through group membership off
   unless its expanded scope is approved. Choose the account for this location.
4. Review **Polling Schedule** (full and delta discovery), **Options** (stale
   logon/password-age filters) and **Active Directory Attributes**. Keep default
   attributes unless additional data is needed; record filters that might exclude
   the pilot. Enable the method and save.
5. Right-click the method and select **Run Full Discovery Now**. Check
   `<site-install>\Logs\adsysdis.log` for the intended computer's discovery and
   DDR processing; investigate LDAP/DNS/access failures. Refresh **Assets and
   Compliance > Devices** and inspect the record's domain/name before using it.
   A discovered record with **Client = No** is expected before installation.

Sources: [configure discovery](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/configure/configure-discovery-methods),
[discovery methods](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/configure/about-discovery-methods)
and [account permissions](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/hierarchy/accounts).

## Manually install the pilot client

This branch uses a complete local copy of the site's client source and an
elevated session on the single pilot. It does not enable automatic client push.

1. Confirm supported client OS/build, DNS/time, permitted client-to-role ports
   and the selected [communication security](communication-security.md).
   For PKI, install and validate the intended client-authentication certificate,
   trusted chain and reachable offline revocation data first.
2. Copy the **complete** current `<site-install>\Client` folder through the
   approved internal delivery process to, for example, `C:\Staging\CMClient` on
   the pilot. Verify provenance/version and transfer hashes; a lone ccmsetup.exe
   is not a complete offline source. Use an account with local administrator
   rights on this pilot and open an elevated command prompt.
3. Substitute the approved values in one of these examples. All slash options
   must precede MSI properties. The names below are reserved examples.

For Enhanced HTTP with an HTTP client-facing MP:

```bat
C:\Staging\CMClient\ccmsetup.exe /source:"C:\Staging\CMClient" SMSMP=mp.example.invalid SMSSITECODE=LAB
```

For a PKI HTTPS MP and a valid client certificate:

```bat
C:\Staging\CMClient\ccmsetup.exe /source:"C:\Staging\CMClient" /UsePKICert SMSMP=https://mp.example.invalid SMSSITECODE=LAB
```

`/source` supplies setup files; `SMSMP` supplies the installed client's initial
management point; `SMSSITECODE` selects its assigned site. If a different approved
branch uses `/mp`, that switch locates setup download sources and **does not set
the installed client's assigned MP**. Multiple eligible PKI certificates need
the site's approved selection properties; do not guess or bypass CRL checking.

4. Wait for installation to finish in `%windir%\ccmsetup\Logs\ccmsetup.log`;
   command launch/return is not sufficient because setup can continue as a
   service. Final CCMSetup code **0** is success; **7** requires restart;
   **8** means setup is already running; **9** is a prerequisite failure; **10**
   is a manifest-hash failure. Check `client.msi.log` for MSI failures. Resolve
   the actual error and complete required restarts before retrying or continuing.
5. Open **Control Panel > Configuration Manager**. On **Site**, confirm the
   intended site code. On **Actions**, run **Machine Policy Retrieval & Evaluation
   Cycle**. Inspect `%windir%\CCM\Logs\ClientIDManagerStartup.log`,
   `LocationServices.log` and `PolicyAgent.log` for registration, correct MP/site
   and policy receipt. Confirm the console eventually reports the client.
6. Verify software updates are enabled in the pilot's effective client settings.
   Run **Software Updates Scan Cycle** and use the
   [first-patch checkpoints](verification-checkpoints.md) for SUP, scan and content
   verification. Stop if identity, site assignment or policy is wrong.

Record the configured wait/escalation window before execution. If it expires,
retain logs and timestamps; do not repeatedly reinstall an unresolved client.

Sources: [client installation methods](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/deploy/deploy-clients-to-windows-computers)
and [setup switches, properties and return codes](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/deploy/about-client-installation-properties).
