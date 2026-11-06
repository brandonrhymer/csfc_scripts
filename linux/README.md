# Linux administration examples

These attachment-derived scripts require Python 3, a local OpenSSH client, and
RHEL 9 targets. They use known SSH host keys and prompt for SSH/sudo passwords.
Use a private inventory outside the repository. Reports contain system identities,
policy evidence, schedules, and possibly sensitive configuration text; never commit
them. The scripts do not establish classification or automatically sanitize reports.

| Script | Purpose | Target effect |
| --- | --- | --- |
| [ClamAV discovery](clamav/README.md) | Inventory packages, signatures, services, schedules, and scan results | Collects evidence and invokes benign scans; scanners may write their normal logs |
| [Account discovery](local-accounts/README.md) | Compare an account with an illustrative baseline | Reads account and policy evidence |
| [Account remediation](local-accounts/README.md) | Create or normalize the illustrative account | Preflight by default; `--apply` changes accounts, ownership, passwords, and aging |

Each tool has its runbook beside its scripts. See [validation](../docs/attachment-validation.md).
