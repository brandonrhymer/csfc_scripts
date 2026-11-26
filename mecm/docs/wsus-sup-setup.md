# Configure WSUS and the software update point

Run this on the **disconnected** site's approved WSUS/SUP host. It does not
authorize changes to the shared connected export server. Record the actual
WSUS database, content root, IIS site, HTTP/HTTPS ports and host FQDN first.
See [software update prerequisites](https://learn.microsoft.com/en-us/intune/configmgr/sum/plan-design/prerequisites-for-software-updates).

## Install and check the role prerequisites

1. On the selected host, use **Server Manager > Add Roles and Features** to
   install Windows Server Update Services with the approved database option and
   management tools. Choose the approved content location; complete the WSUS
   post-install task successfully. Record the resulting database and content path.
   Do not launch an independent Microsoft Update synchronization or approve
   updates in WSUS for this ConfigMgr-managed disconnected SUP.
2. Apply the supported OS/WSUS servicing updates and required restarts. Record
   WSUS component versions and verify the WSUS service/IIS site are healthy.
   Where Windows 11 UUP applies, also complete the
   [UUP readiness checks](offline-content-acquisition.md#uup-readiness).
3. **Remote SUP:** if WSUS is not installed on the site server, install the WSUS
   Administration Console there (Server Manager's WSUS management tools).
   Its WSUS version must match the SUP's; check component/file versions on both
   hosts after servicing. This requirement concerns the site server and its SUP,
   not an assumed version rule for every external metadata-export source.
4. Verify the approved site-system installation identity can install the remote
   role. Keep that installation identity separate from the WSUS connection
   identity. If the site-server computer cannot perform WSUS-specific operations,
   configure the approved **WSUS Server Connection Account** in SUP settings
   and grant it membership in **both local Administrators and WSUS Administrators**
   on the WSUS host. Do not reuse a broad domain admin
   credential. Record firewall rules and test the configured endpoint from the
   site server. See [account requirements](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/hierarchy/accounts#software-update-point-connection-account).

## Configure the WSUS application pool

Before TLS configuration or the first synchronization, have the SUP owner review
**IIS Manager > Application Pools > WsusPool > Advanced Settings**. Record the
current values and approve the following Microsoft recommendations against the
host's available memory and colocated-role capacity:

| Setting | Microsoft recommendation |
| --- | --- |
| Queue Length | 2000 |
| Idle Time-out (minutes) | 0 |
| Ping Enabled | False |
| Private Memory Limit (KB) | 0, unlimited |
| Virtual Memory Limit (KB) | 0, unlimited |
| Regular Time Interval (minutes) | 0, disables periodic recycling |

Apply the approved settings in the change window and verify the pool remains
started. Unlimited memory limits require sufficient RAM and monitoring; they
are not a sizing calculation. Repeated pool recycling discards cached metadata
and can cause HTTP 503 scan failures. Retain before/after settings and inspect
pool/system events, memory usage and a pilot scan after configuration. Source:
[Microsoft WSUS application-pool guidance](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/windows-server-update-services-best-practices#disable-recycling-and-configure-memory-limits).

## Configure WSUS TLS before enabling SUP SSL

Use this branch when TLS is the approved design. With an approved non-TLS branch,
record that decision and use the actual HTTP port in the SUP; Enhanced HTTP does
not automatically secure WSUS.

1. On the WSUS host, install a valid Server Authentication certificate in the
   local computer store, with the WSUS FQDN in its identity and a trusted chain.
   Validate offline revocation access from the site server and pilot clients.
2. In **IIS Manager > Sites > WSUS Administration > Bindings**, add or verify
   the HTTPS binding on the approved port (commonly 8531) with that certificate.
   Preserve its HTTP binding (commonly 8530); WSUS still uses HTTP for some flows.
   Use the recorded values if this installation uses different ports/site names.
3. Enable **Require SSL**, with **Client certificates: Ignore**, on only these
   WSUS virtual directories: **ApiRemoting30**, **ClientWebService**,
   **DSSAuthWebService**, **ServerSyncWebService**, **SimpleAuthWebService**.
   Do not require SSL on the WSUS Administration root, Content, Inventory,
   ReportingWebService or SelfUpdate directories.
4. Run elevated **on the WSUS host**, replacing the reserved FQDN:

   ```powershell
   & "$env:ProgramFiles\Update Services\Tools\WsusUtil.exe" configuressl wsus.example.invalid
   if ($LASTEXITCODE -ne 0) { throw 'WSUS TLS configuration failed; review output.' }
   ```

5. In the WSUS console, connect to that FQDN and actual SSL port with **Use SSL
   to connect to this server** selected. Test from the WSUS host and, for a remote
   SUP, from the site server's WSUS console. Resolve certificate/connection errors
   before adding the SUP SSL setting. Do not make independent WSUS configuration
   changes through that console.

This sequence and the directory exceptions follow Microsoft's
[SUP SSL tutorial](https://learn.microsoft.com/en-us/intune/configmgr/sum/get-started/software-update-point-ssl).

## Add the SUP and set synchronization choices

1. In **Administration > Site Configuration > Servers and Site System Roles**,
   select the WSUS host and **Add Site System Roles** (or create the site system
   first). Select **Software update point**.
2. Match the actual WSUS HTTP/HTTPS ports. Select **Require SSL communication
   to the WSUS server** only for the tested TLS branch above. Verify the WSUS
   connection account/installation identity and local-versus-remote topology.
3. For the disconnected standalone primary, select **Do not synchronize from
   Microsoft Update or upstream data source**. Configure SUP settings in
   ConfigMgr; do not independently change WSUS approvals or synchronization.
4. **Before the first ConfigMgr sync**, choose every required **summary details
   language**. Separately select the languages needed for update files. Later
   summary-language changes apply to new/changed updates and do not backfill
   unchanged metadata. Record both selections in the transfer plan.
5. Select the approved products/classifications within the export source's
   coverage. Some categories appear only after an initial synchronization;
   revisit those product/classification selections afterwards and sync again.
   That is not a reason to defer summary-language planning.
6. Review supersedence/expiration and maintenance choices with the SUP owner;
   retain existing approved settings. Finish the wizard, then check `WCM.log`
   on the site server and `WSUSCtrl.log` on the SUP host for successful
   configuration/connection. Use their actual site/role log directories.
7. Associate the SUP's server with the pilot's
   [boundary group](client-onboarding.md#associate-the-pilots-network-with-site-systems).
   Continue with metadata/content transfer in [stage 3](03-first-patches.md).

Sources: [install a SUP](https://learn.microsoft.com/en-us/intune/configmgr/sum/get-started/install-a-software-update-point)
and [language planning](https://learn.microsoft.com/en-us/intune/configmgr/sum/plan-design/plan-for-software-updates#languages).

**Stop:** a completed role wizard is insufficient if configuration, WSUS health
or TLS tests fail. Record host, time, port, connection identity and log error;
resolve with the role/PKI/network owner before importing or deploying updates.
