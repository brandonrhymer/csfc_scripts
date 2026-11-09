# ClamAV discovery on RHEL 9

`clamav_rhel9_discovery.py` collects preliminary evidence from approved RHEL 9
targets. It inventories ClamAV packages/binaries, services, selected configuration,
signature-file timestamps, schedules, and results of benign scans of `/etc/hosts`.

It does not install ClamAV, update definitions, change remote configuration, or
run freshclam updates. Scanner invocations may create normal local logs on targets.

**Current phase: content preparation. Full testing and review are deferred.**
Commands below describe the later approved workflow; do not treat them as a
completed test or as deployment authorization.

## Requirements and scope

Launch from a Linux management computer with Python 3 and OpenSSH. Targets must
already have trusted host keys and approved SSH/sudo access. The same username
and password are used across this script's target set, and that password must
also work for sudo. Interactive MFA/key-only workflows are not implemented.

The current report path requires local root privileges. When launching with
`sudo`, make sure the executing account already has the approved host-key records.
The script will not accept an unknown or changed host key for you.

## 1. Prepare a private inventory

Create a UTF-8 text file outside Git with **one target per line**. Blank lines
and full-line comments beginning with `#` are ignored. Do not add a CSV header,
username column, inline comment, or password.

```text
# Reserved example only; replace in your private working copy.
host1.example.invalid
host2.example.invalid
```

Use the smallest approved target set. Keep actual addresses and names private.

## 2. Prepare the command

Run from the directory containing the script. `--help` displays parameter help
without contacting a target. Collection is a separate command for the later
approved test/execution phase.

```bash
# Display options only.
python3 clamav_rhel9_discovery.py --help

# Later, when approved: collect from the private inventory.
# Replace the example paths and username outside the repository.
# --workers 1 processes one target at a time.
sudo python3 clamav_rhel9_discovery.py \
  --inventory /path/to/private/inventory.txt \
  --user example_operator \
  --workers 1

# Save the exit code immediately after the collection command.
result=$?
printf 'Collection exit code: %s\n' "$result"
```

The script prompts for the SSH/sudo password without putting it in command-line
arguments. `--workers` accepts 1 through 5; its default is 5. An inventory selects
the targets exactly; the script does not discover an entire network for you.

## 3. Understand the report

Output is `/var/log/clamav_assessment/latest.json`. The directory uses mode 0700
and the report uses mode 0600. Each run replaces `latest.json`; preserve needed
evidence privately before starting another run.

Reports can contain identities, endpoints, service definitions, scheduled
commands, paths, and potentially sensitive configuration. They are **not
sanitized output** and must not be committed or pasted into a public issue.

| Status | Meaning |
| --- | --- |
| `NOT_INSTALLED` | No matching package/binary evidence was found. |
| `NONCOMPLIANT` | One or more illustrative operational checks failed. This label is not an organizational compliance decision. |
| `PARTIAL` | Some configuration or supporting evidence was missing. |
| `NOT_ASSESSED` | Operational checks did not establish an approved package/version compliance baseline. |
| `UNAUTHORIZED_OR_UNSUPPORTED_OS` | The response did not identify as RHEL 9. |
| `UNREACHABLE` / `INSUFFICIENT_PRIVILEGE` / `ERROR` | Collection could not be completed reliably. |

A collection response needs its completion record and successful SSH exit.
Partial structured output is not accepted as a completed collection.

Exit `2` indicates an input/report/preflight failure. Exit `1` means at least one
target was not fully assessed by the script's current rules. In particular, this
version intentionally does not turn an operational discovery into a compliance
certification, so a collected `NOT_ASSESSED` result is nonzero.

## Limits and interruption handling

- Signature age uses the newest discovered signature file's modification time.
  A copied file can have a recent timestamp without containing recent definitions.
  Compare private evidence with the approved signature-import record later.
- Schedule detection is heuristic. Finding text that looks like a schedule does
  not establish that it ran, succeeded, or covers the intended filesystem.
- A successful benign scan is not a malware-detection test. No EICAR artifact is
  supplied or executed.
- Remote collection has a 60-second controller deadline. A slow scanner or SSH
  exchange can exceed it. No partial response is accepted as a completed result.
- Read-only collection can retry once. Scanner checks may therefore run again.
- A timeout does not prove a remote scanner stopped. Inspect the situation before
  planning another run; do not change security settings to force completion.

See the [preparation record](../../docs/attachment-validation.md) for the later
full test/review work, which is currently deferred.
