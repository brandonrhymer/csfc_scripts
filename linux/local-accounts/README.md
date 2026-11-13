# Local account discovery and remediation

These tools work together but are separate commands:

- `local_admin_discovery.py` collects preliminary account and policy evidence.
- `local_admin_remediation.py` defaults to a remote preflight. Only `--apply`
  creates or changes the account selected by an approved private runtime policy.

**Full runtime and lab validation are incomplete.**
The examples below are not evidence of a completed lab test or permission to
change operational systems.

## Prepare one private runtime policy

Both commands require `--policy /path/to/private/account-policy.json`. Copy the
synthetic [policy.example.json](policy.example.json) outside the repository and
have the responsible owner supply approved values there. Pass that same file to
discovery and remediation. No source-code edits are needed. Keep
`account_policy.py` beside either script; it is their shared policy validator.

The example contains `example_admin`, UID/GID `20000`, `/home/example_admin`, and
`/bin/bash`, with `wheel` membership, home mode `0700`, aging 60/1/14/60 days and
optional faillock deny 3/unlock 900 seconds. These are synthetic placeholders,
not a CSfC requirement or an organization-approved policy. Never put passwords,
private inventories, actual deployment policy or reports in the repository.

Every field in the example is required. Unknown fields, duplicate JSON keys,
non-finite numbers, booleans used as integers, and implicit conversions are
refused. Policies are limited to 16 KiB. Supported values are:

| Fields | Validation |
| --- | --- |
| `schema_version` | Integer `1`. |
| `account`, `group`, `privileged_group` | Lowercase Linux names of 1–31 characters: first a letter/underscore, then letters, digits, underscores or hyphens. `root`, `nobody`, and `nfsnobody` are refused. The private group must differ from the supplementary privileged group. |
| `uid`, `gid` | Integers 1000–2147483647, excluding reserved ID 65534. Existing identity safety checks still apply. |
| `home` | An absolute child path under `/home` or `/srv`, using letters, digits, underscores and hyphens. No dot components, repeated/trailing slash, symlink or shared/foreign home is accepted. |
| `home_mode` | String `"0700"` or `"0750"`. |
| `shell` | `/bin/bash`, `/bin/sh`, `/usr/bin/bash`, or `/usr/bin/sh`; it must be executable on the target. |
| `comment` | 1–128 printable ASCII characters without a colon. Shell characters remain literal data. |
| `password_max_days` | Integer 1–99999. |
| `password_min_days`, `password_warn_days` | Integers 0–99999, no greater than `password_max_days`. |
| `password_inactive_days` | Integer 0–99999. |
| `faillock_deny` | Integer 1–100. |
| `faillock_unlock_time_seconds` | Integer 1–604800. |

Both commands display the complete selected policy and its SHA-256 digest
before asking for credentials or contacting a target. Reports contain the same
normalized policy and digest. This digest identifies policy contents; it does
not establish approval. The privileged supplementary group must already exist;
these tools do not create it or configure sudoers privileges.

## Requirements

Launch from Linux with Python 3, OpenSSH, and util-linux `setsid`. The SSH process
uses its own controlling terminal so password prompts reach the script's PTY.
Targets must be approved RHEL 9
systems with trusted SSH host keys and an existing authorized SSH/sudo account.
The same current password is assumed to work for SSH and sudo on each target;
it may differ between targets. Key-only authentication and interactive MFA flows
are not implemented.

Local root privileges are required for the current report locations. The account
that launches the command must already have the approved host-key records.
These utilities do not configure SSH, sudo, host-key trust, or remote access.

## 1. Prepare the private inventory

Use CSV containing **exactly two fields per row with no header**: target and
existing SSH username. Blank lines and full-line comments are allowed.

```text
# Reserved examples only; replace privately before later use.
host1.example.invalid,example_operator
host2.example.invalid,another_operator
```

Passwords never belong in this file. Keep it outside Git. List each actual
machine once. Remediation rejects repeated hostnames, including case/trailing-dot
variants, but it does not resolve aliases to determine whether two names are the
same computer.

## 2. Prepare discovery first

These are separate commands. Use discovery only on approved targets:

```bash
# Help does not contact targets.
python3 local_admin_discovery.py --help

# Discovery reads remote account/policy evidence and writes a local report.
sudo python3 local_admin_discovery.py \
  --inventory /path/to/private/inventory.csv \
  --policy /path/to/private/account-policy.json

# Capture immediately after the script returns.
result=$?
printf 'Discovery exit code: %s\n' "$result"
```

The script prompts separately for each existing SSH/sudo password. It does not
change target accounts. Discovery may retry a failed read-only collection once.
Its report is `/var/log/local_admin_assessment/latest.json`.

`BASELINE_MATCHES_DISCOVERY` describes the attributes actually compared. It does
not certify password, lockout, sudo, or overall security policy. Those additional
items include collected evidence that requires a later human review.
`READY_FOR_REMEDIATION` means selected policy attributes differ, not that a change
has been approved. `UID_GID_CONFLICT` must be resolved before remediation.

Collection requires its completion record and successful SSH exit. A partial
response is an error rather than usable complete evidence.
The ownership scan is limited to the root filesystem (`find / -xdev`), with a
30-second timeout and a further five-second termination grace period. A successful
scan may legitimately count zero files. Permission/traversal/counting errors or a
timeout produce `INCOMPLETE`, `ownership_scan_status` of `FAILED`/`TIMEOUT`, and
`account_owned_file_count` of `UNAVAILABLE`; a partial numeric count is discarded.
An absent account produces `NOT_APPLICABLE`. These counts never cover separate
mounts and are not a migration plan.

## 3. Prepare remediation preflight

```bash
# Default mode connects to targets and checks eligibility, but does not change accounts.
# It still uses sudo and writes a local report.
sudo python3 local_admin_remediation.py \
  --inventory /path/to/private/inventory.csv \
  --policy /path/to/private/account-policy.json
```

`DRY_RUN_READY` means the implemented preflight completed. It does not verify that
all later commands would succeed or that the selected policy is approved.

The preflight refuses conflicts at the desired UID/GID and refuses unsafe
existing identities, including protected/system IDs, shared source IDs, or
identities that are not uniquely local. It also refuses symbolic-link or
non-directory home-path components. If an existing account uses a different
home path, reconcile that migration manually before using this tool.
An existing group must already have the requested GID; this tool does not migrate
groups. An existing home must belong to the existing account, and no other
account returned by `getent passwd` may use the same or an overlapping home path.
If the account is absent but its intended home exists, the script stops.

These checks deliberately stop rather than guessing how to repair an unusual
identity or home directory. Do not bypass them to make a preflight appear green.

## 4. Apply only after the later review and approval

```bash
# MUTATING COMMAND: use only after the review/test phase and change approval.
sudo python3 local_admin_remediation.py \
  --inventory /path/to/private/inventory.csv \
  --policy /path/to/private/account-policy.json \
  --apply
```

Apply mode requires typing `APPLY`, entering and confirming the new account's
vault-managed password, and supplying each current SSH/sudo password. The script
creates/normalizes the account and private group, adds the selected privileged-group membership, sets
home ownership/mode, changes the password and aging values, and unlocks the
account. It does not configure sudoers to grant the group privileges.

If separately authorized, `--manage-faillock` additionally edits
`/etc/security/faillock.conf`. **This is a system-wide change**, not an
account-only change. The utility does not configure or prove the associated PAM
policy is active. Keep this option absent unless that broader change is intended.

## Ownership changes and recovery limits

An approved UID change can migrate ownership on the root filesystem. Files on
separate mounts are not migrated. The ownership pass preserves each file's group;
it does not perform a blanket file-group migration. A migration or account-unlock
failure is reported as failure rather than success.

Changes are not transactional. A failed command can leave earlier changes in
place, including group/account updates. There is no automatic rollback.
The script does not move an existing account from a different home directory;
that needs a separate, deliberate migration plan.

Apply mode does **not** retry automatically. A timeout does not prove the remote
operation stopped. Do not rerun blindly. Reconcile actual account/group/home
state, ownership, and private evidence with the responsible operator first.

## Reports and exit codes

Both report directories use mode 0700 and their files use mode 0600. Each run
replaces its own `latest.json`; preserve needed evidence privately beforehand.
The remediation report is `/var/log/local_admin_remediation/latest.json`.
Report schema version `2` uses account-neutral evidence keys, `policy`, and
`policy_sha256`; consumers of older hardcoded-account keys must be updated.
Reports contain identity and policy evidence and are not sanitized for sharing.
Remediation saves an `IN_PROGRESS` report before the first target and updates it
after each host returns. It stops if a report write fails. `COMPLETE` means the
loop finished, not that every host succeeded. If interrupted, finished host
results remain, but the active host may have changed without a saved result.
Reconcile that host manually before any retry; this is not a resumable job system.
Discovery still writes its report only when the whole run finishes.

| Remediation status | Meaning |
| --- | --- |
| `DRY_RUN_READY` | The non-mutating preflight completed for this target. |
| `REMEDIATED` | The script reported its expected apply result and SSH exited successfully. |
| `UID_GID_CONFLICT` | The requested numeric identity belongs to another identity. |
| `UNSUPPORTED_OS` | The target did not identify as RHEL 9. |
| `FAILED` | A remote check or operation failed; partial changes may exist. |
| `UNVERIFIED` | Completion evidence was absent, unexpected, or contradicted by the SSH exit. |
| `TIMEOUT` / `ERROR` | Transport or execution did not complete reliably. |
| `NOT_ASSESSED` | No current credential was supplied for that target. |

Remediation exits `0` only when every target has the expected result for the
selected mode (or when the operator cancels at the initial confirmation without
making changes). Any other target result returns `1`. Input/report failures
return `2`. Discovery likewise returns nonzero for findings that do not already
match its selected policy; inspect the report rather than assuming a
nonzero code always means the script itself crashed.

See the [validation guide](../../docs/validation.md). Actual SSH/sudo behavior
and RHEL account changes still require approved lab validation.
