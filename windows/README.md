# Windows administration scripts

Use Windows PowerShell 5.1 and your approved script-signing/execution process.
All actual endpoints, inventories, packages, reports, and credentials belong in
a private working directory outside Git. Reserved `example.invalid` names in
documentation must be replaced at runtime. Do not use a placeholder as a target.

| Directory | Purpose |
| --- | --- |
| [defender](defender/README.md) | Sequential offline Defender security-intelligence deployment using Kerberos remoting |
| [nessus](nessus/README.md) | Download a plugin archive from an operator-supplied HTTPS URL; does not import it |
| [splunk](splunk/README.md) | Install or uninstall Universal Forwarder locally |

Each runbook is kept beside its scripts. See [validation](../docs/attachment-validation.md).
