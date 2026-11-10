# Windows administration scripts

The Windows utilities have different purposes and execution scopes. Read the
individual runbook rather than treating them as a combined deployment suite.

**Current phase: code review. Testing and lab validation remain deferred.**
Read [start here](../docs/operator-start-here.md) before preparing a private copy.

| Tool | Purpose | Where it acts | Runbook |
| --- | --- | --- | --- |
| `defender/Invoke-CSfCDefenderUpdate-MVP.ps1` | Stage and run an approved offline Defender security-intelligence package | Approved remote Windows targets, sequentially | [Defender](defender/README.md) |
| `nessus/download-plugins.ps1` | Download an approved plugin archive | Writes one local file; no plugin import | [Nessus](nessus/README.md) |
| `splunk/install-forwarder.ps1` | Install a staged Universal Forwarder MSI | Current computer only | [Splunk](splunk/README.md) |
| `splunk/uninstall-forwarder.ps1` | Remove registered Universal Forwarder MSI products | Current computer only | [Splunk](splunk/README.md) |

## Shared preparation

Use the PowerShell version documented for that utility. Defender requires an
elevated 64-bit Windows PowerShell 5.1 controller; the smaller Windows scripts
declare Windows PowerShell 5.1 as their minimum. The [text sanitizer](../obfuscation/README.md)
is separate and requires PowerShell 7.4 or later.

Do not change execution policy, TrustedHosts, security settings, or certificate
validation to get past a failure. Resolve prerequisites through the approved
administration process. These utilities do not establish those prerequisites.

Keep actual hostnames, endpoint values, download links, packages, credentials,
and output evidence outside the repository. Use a dedicated private working
location. `-WhatIf` is a preview, not proof that an installation or remote action
will succeed. Its scope differs between tools and is described in each runbook.
