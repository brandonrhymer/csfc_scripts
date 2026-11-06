# ClamAV discovery on RHEL 9

`clamav_rhel9_discovery.py` collects packages, services, signature ages,
configuration, scheduled scan evidence, and benign scan results. It does not
update definitions or run freshclam. Requires Python 3, OpenSSH, trusted target
host keys, and the same SSH/sudo password on the chosen targets.

Run `python3 clamav_rhel9_discovery.py --help`. Supply `--inventory` (one target
per line), `--user`, and optionally `--workers` (1–5). Keep the inventory outside
Git. `host1.example.invalid` is a reserved example only; replace it privately.
Local root privileges are required to write `/var/log/clamav_assessment/latest.json`.
Each run replaces this report. It uses mode 0600 in a mode-0700 directory.

Reports may contain identities, endpoints, service definitions, and scheduled
commands, including potentially sensitive configuration. Keep them outside Git.
The script does not sanitize reports. Scanner invocations may write normal logs.

Schedule recognition is heuristic, and the freshness threshold is illustrative.
No package compliance certification or malware detection test is provided.
SSH/sudo transport and actual scans need an approved lab pilot before use.
See [validation](../../docs/attachment-validation.md).
