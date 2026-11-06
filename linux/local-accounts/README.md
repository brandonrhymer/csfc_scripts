# Local account discovery and remediation

Scripts: `local_admin_discovery.py` and `local_admin_remediation.py`.
Requires Python 3, OpenSSH, trusted host keys, and RHEL 9 targets.
Keep reports and inventories private: they contain identity and policy evidence.

Run `python3 SCRIPT --help` for options. Account inventory is CSV with two fields and no header:

```text
# Reserved example only; replace privately before use.
host1.example.invalid,example_operator
```

Both account scripts use **example_admin**, UID/GID **20000**, and
`/home/example_admin` as illustrative replacement values. Their policy values
are examples, not a required organizational baseline. Review and adapt the paired
scripts together in a private working copy before use. Never put actual account
names, inventories, or deployment-specific policy into this public repository.

The Linux scripts require local root privileges to write reports under `/var/log`.
Report directories use mode 0700 and report files use 0600; each run replaces
`latest.json`. Archive evidence privately if needed. SSH and sudo are assumed to
use the same current password; key-only authentication and interactive MFA flows
are not implemented. Validate this transport in an approved lab first.

Remediation `--apply` requires an interactive confirmation and a new password.
`--manage-faillock` additionally changes system-wide lockout settings. Changes are
not transactional: a failure can leave partial changes, and an SSH timeout does
not prove remote work stopped. Apply mode does not retry automatically. Inspect
account state before any retry. UID changes may reassign ownership across the
root filesystem; separate mounts are not migrated. No rollback is provided.

Success requires the expected final result and a zero SSH exit code. Partial,
unknown, or contradictory completion evidence is `UNVERIFIED`; it never counts
as successful remediation. Any status other than the expected success for the
selected mode makes the script exit nonzero.

Discovery is preliminary evidence, not certification of compliance. Account discovery does not enforce or fully validate password/lockout policy.
See [validation](../../docs/attachment-validation.md).
