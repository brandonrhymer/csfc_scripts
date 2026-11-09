# Local Splunk Universal Forwarder installation and removal

- `install-forwarder.ps1` runs one locally staged MSI on the **current computer**.
- `uninstall-forwarder.ps1` finds registered Universal Forwarder MSI products on
  the **current computer** and removes the selected products through Windows Installer.

These scripts are sanitized replacements for the supplied `exec.ps1` and
`uninstall.ps1`. They do not provide remoting or process a computer inventory.
The original installer loop did not perform remote installation; this version
makes that local scope explicit.

**Current phase: code review. Testing and lab validation remain deferred.**
The commands below describe a later approved workflow. No installation, removal,
or forwarding outcome is established by preparing the repository content.

## Requirements and decisions

Use an elevated Windows PowerShell 5.1-or-later console on the intended machine.
On 64-bit Windows, run removal from 64-bit PowerShell. The removal script refuses
a 32-bit process so registry redirection cannot hide the 64-bit installation.
Before a later installation, prepare:

- The approved Universal Forwarder MSI for the intended Windows architecture/version.
- Its independently approved integrity/publisher evidence.
- The receiving indexer and deployment-server values, in `hostname:port` form.
- Approval for the software license and the intended installation/change window.
- A separate plan for supported package options, service identity, input
  configuration, TLS/certificates, and forwarding verification.

The install script handles only the supplied MSI, license acceptance, receiving
indexer, and deployment server. It does not configure certificates, create
forwarding inputs, select an organization-specific service identity, manage
Splunk application credentials, or establish that every MSI release can use
these same unattended options. Those decisions remain part of the later review.

Do not change execution policy or other security settings to get past a failure.
Do not run removal until forwarding/migration and log-retention impact are understood.

## 1. Prepare private installation values

```powershell
# Run from the directory containing install-forwarder.ps1.
# Keep the real package and endpoint values in a private working location.
$settings = @{
    MsiPath          = 'C:\PrivatePackages\forwarder.msi'
    ReceivingIndexer = 'indexer.example.invalid:9997'
    DeploymentServer = 'deployment.example.invalid:8089'
}
```

The endpoint values above are reserved placeholders and are deliberately
rejected by the script. Substitute approved private values before a later use.
The script accepts hostname/IPv4-style endpoints with ports 1–65535, not IPv6
literal syntax. The MSI path must identify an existing `.msi` file without quote
characters. Choose a locally staged file rather than relying on a remote share.

Package signature/hash approval is a prerequisite, not an automatic check
performed by this small installer wrapper. A filename alone does not establish
that the MSI is the intended product or approved package.

## 2. Preview and install only when approved

```powershell
# After the license has been reviewed and accepted, preview the local action.
# -AcceptLicense is an explicit license acknowledgement required by this wrapper.
.\install-forwarder.ps1 @settings -AcceptLicense -WhatIf

# Later, with change approval: one local unattended installation.
# PowerShell may ask for confirmation because the operation has high impact.
.\install-forwarder.ps1 @settings -AcceptLicense
```

`-WhatIf` checks parameter values and the package path and displays the intended
action. It does not execute MSI, prove package trust, test forwarding, or verify
compatibility. The real command waits for `msiexec.exe` to finish and requests no
automatic restart.

Only MSI exit `0` and `3010` are accepted. `3010` means a restart is required;
coordinate it separately. Other codes raise an error. A completed MSI operation
is not proof that the service is healthy or logs are arriving at the intended
receiver. Record those outcomes separately in the later approved workflow.

## 3. Plan removal separately

The removal utility searches the normal 64-bit and 32-bit Windows uninstall
registry locations for Universal Forwarder product names. It requires a valid
MSI product code rather than executing an arbitrary stored uninstall command.

```powershell
# Preview matching local products without stopping the service or running MSI.
.\uninstall-forwarder.ps1 -WhatIf

# Later, only after forwarding/migration and removal are approved.
.\uninstall-forwarder.ps1
```

When confirmed, the script stops the `SplunkForwarder` service if needed and runs
the MSI uninstall without an automatic restart. If no matching product is found,
it prints that result and returns without an uninstall operation.

Removal can interrupt logging. If MSI fails after the service is stopped,
forwarding may remain stopped. There is no automatic reinstall, service recovery,
configuration backup, or rollback. Preserve required configuration/evidence and
prepare the recovery decision before removal. A successful uninstall does not
prove that all product data or external registrations have been removed.

## Results and troubleshooting

| Result | Meaning / next step |
| --- | --- |
| MSI `0` | Installer reported success; later operational checks remain separate. |
| MSI `3010` | Installer reported success with restart required; do not reboot without approval. |
| Other MSI exit | Stop and inspect the approved Windows Installer/product logs privately. |
| Product not found | No matching registry product was selected; this is not a complete filesystem inventory. |
| Invalid product code | No uninstall is performed for that entry; reconcile registration manually. |
| Removal failed after stop | Forwarding may be stopped; reconcile service/install state before any retry. |

These wrappers do not create a dedicated MSI log or enforce a whole-installation
timeout. A still-running installer is not an invitation to start a second copy.
Use the normal approved Windows Installer investigation process if it stalls.

Keep MSI files, endpoints, product logs, and recovery evidence outside Git. See
[preparation record](../../docs/attachment-validation.md) for the deferred full
test and lab phase.
