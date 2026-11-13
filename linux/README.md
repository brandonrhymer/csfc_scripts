# Linux administration scripts

These Python tools are intended to be launched from a Linux management computer.
They use the installed OpenSSH client to reach approved RHEL 9 targets. Python
standard-library modules are used; no Python package installation is required.

**Full runtime and lab validation are incomplete.**
Read [start here](../docs/operator-start-here.md) before preparing a private copy.
Do not run the commands against operational targets until approved review and
lab testing are complete.

| Tool | Purpose | Remote changes | Runbook |
| --- | --- | --- | --- |
| `clamav/clamav_rhel9_discovery.py` | Preliminary ClamAV evidence collection | No configuration updates; benign scans can create ordinary logs | [ClamAV](clamav/README.md) |
| `local-accounts/local_admin_discovery.py` | Illustrative account/baseline discovery | No account changes | [Local accounts](local-accounts/README.md) |
| `local-accounts/local_admin_remediation.py` | Account preflight and optional remediation | Changes only with `--apply`; optional system-wide faillock changes | [Local accounts](local-accounts/README.md) |

## Shared requirements

- Python 3 and OpenSSH on the Linux management computer.
- Trusted target SSH host keys already installed for the executing account.
- Approved SSH/sudo access to each selected target.
- Local root privileges for the current `/var/log` report locations.
- A private inventory in the exact format required by the selected script.

The scripts do not approve new host keys, configure SSH, configure sudo, or
implement interactive MFA flows. The account used to execute them must already
have the required trusted host-key records; a normal user's records are not
necessarily used when launching a command with `sudo`.

ClamAV uses one shared credential for its target set. Account tools prompt for
each existing account's credential. Both assume each SSH password also works
for sudo. Do not put passwords in inventories, command-line arguments, or Git.

Reports are private evidence, not shareable sanitized output. Each tool writes
its own `latest.json` in a mode-0700 directory using mode 0600. Save a private
copy before another run if the earlier evidence must be retained.
