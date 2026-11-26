# Choose and verify client communication security

Record the site build, MP/DP hosts, certificate owner, trust chain, renewal owner
and disconnected revocation plan in the private build worksheet. Select one
approved branch before Setup; do not switch modes to conceal a failed check.

| Design | Site setting and role choices | Required preparation |
| --- | --- | --- |
| PKI HTTPS | Site **Communication Security** uses HTTPS-only when all roles/clients are ready; MP and DP client connections use HTTPS | Role-appropriate PKI certificates, private-key access, trusted roots/intermediates and reachable CRLs; validate client authentication certificates before rollout |
| Enhanced HTTP | Site **Communication Security** selects **HTTPS or HTTP** and **Use Configuration Manager-generated certificates for HTTP site systems**; the applicable MP/DP roles remain configured for HTTP | Supported clients and ConfigMgr-generated certificates; verify provisioning and authentication after setup |

Enhanced HTTP secures supported communication using site-generated certificates.
It does **not** mean all site traffic is HTTPS, and it does not configure WSUS TLS.
An HTTP role choice alone does not enable Enhanced HTTP. Current sites should not
be left using deprecated plain HTTP client communication.

## PKI branch

1. Have the PKI owner use Microsoft's
   [certificate requirements by role](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/network/pki-certificate-requirements)
   to issue the web-server certificates for HTTPS roles, client-authentication
   certificates for clients, and applicable DP certificate. Server Authentication
   and Client Authentication purposes are different; one generic certificate is
   not a substitute for the role matrix. An HTTPS MP also needs the documented
   client-authentication certificate for health monitoring, even without a
   ConfigMgr client installed on that server.
2. Check expiry, intended FQDN/SAN, private key, chain trust and revocation access
   from each role/client network. Disconnected clients must be able to validate
   the approved chain/CRLs without contacting an unavailable internet endpoint.
   Resolve trust/revocation failures with the PKI owner rather than disabling
   revocation checks.
3. Install the web-server certificate in the server's local computer Personal
   store. In IIS Manager on the role host, bind the intended certificate to the
   appropriate HTTPS site binding. In ConfigMgr, select HTTPS in the MP/DP role
   properties. Use the role host's real approved name, not these examples.
   Separately obtain the DP's **Client Authentication** certificate with an
   exportable private key. Export it to a password-protected **PKCS #12/PFX**
   through the approved PKI process. In **DP Properties > Communication**, choose
   **Import certificate from PKI**, select the PFX and enter its password in the
   protected console dialog. Do not put the PFX or password in Git or logs.
   This certificate authenticates DP status communication to HTTPS MPs; the IIS
   server-authentication binding does not replace it. See
   [DP communication settings](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/configure/install-and-configure-distribution-points#communication).
4. Review site **Properties > Communication Security**, including the trusted
   root certificates and client certificate selection settings. For an existing
   mixed site, use an approved transition plan before requiring HTTPS everywhere.
5. Verify MP health in `mpcontrol.log`, correct certificate/binding on the role,
   and successful registration/policy/content access on a pilot. A trusted browser
   connection alone does not prove client certificate authentication works.

## Enhanced HTTP branch

1. During Setup, select the supported HTTP/HTTPS communication option for this
   design. After installation, open **Administration > Site Configuration >
   Sites > Properties > Communication Security** and enable the generated-
   certificate option explicitly.
2. Keep the applicable MP/DP role client connection choice at HTTP; leave anonymous
   DP access disabled. Allow up to 30 minutes for MP certificate configuration.
   Inspect **Administration > Security > Certificates** for generated certificates.
   On the MP host, inspect the **SMS Role SSL Certificate** and the applicable
   IIS HTTPS binding; inspect `mpcontrol.log`
   rather than manually replacing a generated certificate with a guessed one.
3. On the pilot, verify registration, policy and internal content retrieval using
   the [onboarding](client-onboarding.md) and
   [checkpoint](verification-checkpoints.md) guides. Check all configured roles,
   not just the site-level checkbox.

Microsoft describes supported and unsupported flows in
[Enhanced HTTP](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/hierarchy/enhanced-http).
Use the separate [WSUS/SUP procedure](wsus-sup-setup.md) for update scan TLS.

**Evidence:** approved branch, certificate inventory without private keys,
site/role settings, MP health and pilot registration/policy/content results.
Stop on name, trust, expiry, CRL or role health failures.
