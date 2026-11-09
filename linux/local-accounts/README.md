# Local account discovery and remediation

These tools work together but are separate commands:

- `local_admin_discovery.py` collects preliminary account and policy evidence.
- `local_admin_remediation.py` defaults to a remote preflight. Only `--apply`
  creates or changes the illustrative local administrator account.

**Current phase: content preparation. Full testing and review are deferred.**
The examples below describe a later approved workflow. They are not evidence of
a completed lab test or permission to change operational systems.

## Illustrative baseline, not organizational policy

Both scripts use `example_admin`, UID/GID `20000`, `/home/example_admin`, and
`/bin/bash`. The example account is added to `wheel`, uses home mode `0700`, and
has password aging values max/min/warn/inactive of 60/1/14/60 days. Optional
faillock values are deny 3 and unlock time 900 seconds.

These values are placeholders, not a required CSfC or organizational baseline.
Have the responsible owner select the intended policy before use. Adapt both
scripts together in a private working copy, including their embedded Bash and
reported baseline. Changing a Python constant alone does not change every
embedded shell value. Do not commit actual account names or deployment policy.

## Requirements

Launch from Linux with Python 3 and OpenSSH. Targets must be approved RHEL 9
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

These are separate commands to use when the later test/execution phase is approved:

```bash
# Help does not contact targets.
python3 local_admin_discovery.py --help

# Discovery reads remote account/policy evidence and writes a local report.
sudo python3 local_admin_discovery.py \
  --inventory /path/to/private/inventory.csv

# Capture immediately after the script returns.
result=$?
printf 'Discovery exit code: %s\n' "$result"
```

The script prompts separately for each existing SSH/sudo password. It does not
change target accounts. Discovery may retry a failed read-only collection once.
Its report is `/var/log/example_admin_assessment/latest.json`.

`BASELINE_MATCHES_DISCOVERY` describes the attributes actually compared. It does
not certify password, lockout, sudo, or overall security policy. Those additional
items include collected evidence that requires a later human review.
`READY_FOR_REMEDIATION` means illustrative attributes differ, not that a change
has been approved. `UID_GID_CONFLICT` must be resolved before remediation.

Collection requires its completion record and successful SSH exit. A partial
response is an error rather than usable complete evidence.

## 3. Prepare remediation preflight

```bash
# Default mode connects to targets and checks eligibility, but does not change accounts.
# It still uses sudo and writes a local report.
sudo python3 local_admin_remediation.py \
  --inventory /path/to/private/inventory.csv
```

`DRY_RUN_READY` means the implemented preflight completed. It does not verify that
all later commands would succeed or that the example baseline is appropriate.

The preflight refuses conflicts at the desired UID/GID and refuses unsafe
existing identities, including protected/system IDs, shared source IDs, or
identities that are not uniquely local. It also refuses symbolic-link or
non-directory home-path components. If an existing account uses a different
home path, reconcile that migration manually before using this tool.

These checks deliberately stop rather than guessing how to repair an unusual
identity or home directory. Do not bypass them to make a preflight appear green.

## 4. Apply only after the later review and approval

```bash
# MUTATING COMMAND: use only after the review/test phase and change approval.
sudo python3 local_admin_remediation.py \
  --inventory /path/to/private/inventory.csv \
  --apply
```

Apply mode requires typing `APPLY`, entering and confirming the new account's
vault-managed password, and supplying each current SSH/sudo password. The script
creates/normalizes the account and private group, adds `wheel` membership, sets
home ownership/mode, changes the password and aging values, and unlocks the
account. It does not configure sudoers to grant wheel privileges.

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
The remediation report is `/var/log/example_admin_remediation/latest.json`.
Reports contain identity and policy evidence and are not sanitized for sharing.

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
match its illustrative baseline; inspect the report rather than assuming a
nonzero code always means the script itself crashed.

See the [preparation record](../../docs/attachment-validation.md). Full testing
and review, including actual SSH/sudo and RHEL changes, remain deferred.
