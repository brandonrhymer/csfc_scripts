# Security and limitations

## Validation status

The tool has been successfully used in production on multiple occasions,
as confirmed by the maintainer. Automated repository checks additionally cover
parsing, a selected PSScriptAnalyzer ruleset, mocked Pester tests, inert JSON
fixtures, and source review against Microsoft documentation.

Automated checks show local control flow and mock call boundaries. The following
remain environment-specific operational considerations:

- real Domain Admin or directory permissions;
- ADWS, LDAP, RPC/LSA policy, DNS, time, KDC, or `dcdiag` behavior;
- `Sync-ADObject` convergence or deleted-object replication in the enclave;
- GPO application, custom password filters, authentication policies/silos, or
  Protected Users behavior;
- application and end-user authentication impact;
- event retention, application allowlisting, code signing, or receipt ACL
  behavior under enclave policy;
- forest recovery and incident-response procedures, which are outside scope.

The responsible AD authority defines change approval, environment-specific
validation, manual client smoke tests, evidence classification/retention,
and recovery/escalation procedures.

## Open source issue

The original repository has an unresolved report of a Test-flow failure.
Its cause and applicability to this imported revision have not been confirmed.
Do not treat this migration as resolution of that report. If Test fails, stop
and use the troubleshooting guide; do not bypass it to run a reset.

## Intended boundary

The product supports routine rotation in one fixed profile only: one air-gapped
single domain, exactly two writable Windows Server 2022 DCs, 10-hour maximum TGT
lifetime, local attended execution on the same DC for both resets, and the
current interactive Domain Admin token.

It is not appropriate for suspected compromise, confirmed compromise, forest
recovery, more/fewer DCs, RODCs, offline DCs, remote forests, trusts that require
remote operation, Entra/cloud Kerberos, Microsoft Entra Domain Services, older
Windows Server, PowerShell 7, delegated/alternate credentials, Local System, or
unattended operation.

## Network behavior

The tool makes only the in-enclave connections inherently required to read both
DCs, run targeted DC diagnostics/time queries, reset the selected object, and
force its single-object replication. Depending on Windows/AD configuration,
those Microsoft tools use DNS, LDAP/ADWS, Kerberos, RPC, and related AD protocols.
The effective Kerberos interval check opens each DC's LSA policy with read-only
`POLICY_VIEW_LOCAL_INFORMATION` access; it does not set or refresh policy.

The product contains no Internet/cloud endpoint, web request, dependency
download, SMTP/mail, Microsoft Graph, telemetry, update check, remote forest,
PowerShell remoting, or notification behavior. Operators must not add such a
path at change time.

## Credential and password handling

- Only the current signed-in token is used; there is no credential parameter.
- Elevation and current-domain Domain Admin token membership are read-only gates.
- Local System and automatic elevation are rejected.
- A cryptographic RNG creates a 64-character value with upper, lower, digit, and
  symbol classes; it is copied directly into `SecureString`, the temporary
  character array is cleared, and no password is logged or placed in a receipt.
- Windows/AD ultimately controls key material and password acceptance.

`SecureString` reduces accidental exposure but is not a general secrecy boundary
against an administrator controlling the process.

## Target and mutation controls

- LDAP discovery must return exactly one `sAMAccountName=krbtgt` user on each DC.
- SID must equal the current domain SID plus RID 502.
- GUID lookup, SID, DN within the current naming context, disabled state, and
  metadata must agree on both DCs.
- Each production invocation has one call site for `Set-ADAccountPassword` and
  one call site for post-write `Sync-ADObject`.
- Source metadata must advance exactly one version and both DCs must match its
  originating invocation ID, USN, change time, and version.
- Five-minute convergence and cleanup deadlines and the 11-hour wait are fixed;
  public parameters expose no bypass.
- Failure stops the next stage; no rollback or corrective write is attempted.

## WhatIf and Preflight

Preflight and production `-WhatIf` make no AD-changing call and do not force
replication. They do write mandatory local evidence to the System event log and
protected receipt directory. `-WhatIf` still requires current Preflight/Test
receipts because it previews the gated production path; it never creates proof
for either prerequisite.

## Evidence integrity limits

The one-time setup disables inherited receipt-directory ACLs and allows local
Administrators and SYSTEM. This protects against ordinary nonadministrative
editing, not a malicious or compromised administrator. Receipts are structured
and schema-versioned but not cryptographically signed. Classic event logs and
local files remain subject to operating-system and enclave retention controls.

Never delete, edit, compress, or automatically purge evidence. Treat it as
potentially classified operational security data.

Published SHA-256 hashes detect accidental/corrupt air-gap transfer when the
manifest is obtained through a trusted path. An attacker able to replace both
the files and manifest defeats that check. Code signing is not provided.

## No ordinary rollback

There is no safe ordinary password rollback because the operator does not
possess prior KRBTGT keys as a password that can be set back. Recovery focuses on
stopping, preserving evidence, restoring/assessing AD health under approved
procedures, renewing affected sessions where directed, and invoking the
responsible AD recovery or incident-response authority.
