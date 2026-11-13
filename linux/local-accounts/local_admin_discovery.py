#!/usr/bin/env python3
"""
Read-only local-account readiness discovery for RHEL 9.
Supply an approved private JSON policy with --policy; never edit source values.

Inventory format:
  hostname_or_ip,existing_ssh_username

Reserved examples (replace outside Git):
  host1.example.invalid,example_operator_1
  host2.example.invalid,example_operator_2

Operational notes:
  - Prompts individually for each current SSH/sudo password.
  - Assumes each existing SSH password is also valid for sudo.
  - Uses the local OpenSSH client and Python standard library only.
  - Requires known/trusted SSH host keys. It does not accept new host keys.
  - Makes no changes on remote targets.
  - Run locally as root or through sudo to write the JSON report under /var/log.
"""

import argparse
import base64
import csv
import datetime as dt
import getpass
import json
import os
import pty
import re
import select
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from account_policy import load_policy, policy_digest, policy_summary, shell_assignments, validate_policy


REPORT_DIR = Path("/var/log/local_admin_assessment")
REPORT_FILE = REPORT_DIR / "latest.json"

SSH_TIMEOUT = 60
RETRIES = 1
MARKER = "@@LOCAL_ADMIN@@"


REMOTE_SCRIPT = r"""#!/bin/bash
# Read-only script. This entire script runs with sudo privileges.
set +e
__POLICY_ASSIGNMENTS__

emit() {
    local key="$1"
    local value="$2"
    value="$(printf '%s' "$value" | base64 | tr -d '\n')"
    printf '@@LOCAL_ADMIN@@\t%s\t%s\n' "$key" "$value"
}

# Count only on the root filesystem. pipefail must cover find/timeout AND wc;
# otherwise a failed traversal can be hidden by wc's successful exit status.
collect_ownership_count() {
    local uid="$1" count status
    if [[ "$uid" =~ ^[0-9]+$ ]]; then
        count="$(set -o pipefail; timeout --kill-after=5s 30s find / -xdev -uid "$uid" -printf '.' 2>/dev/null | wc -c)"
        status=$?
    else
        status=1
    fi
    if [ "$status" -eq 0 ] && [[ "$count" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
        emit "account_owned_file_count" "$(printf '%s' "$count" | tr -d '[:space:]')"
        emit "ownership_scan_status" "COMPLETE"
        return 0
    fi
    emit "account_owned_file_count" "UNAVAILABLE"
    if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
        emit "ownership_scan_status" "TIMEOUT"
    else
        emit "ownership_scan_status" "FAILED"
    fi
    emit "ownership_scan_exit_code" "$status"
    return 1
}

emit "hostname" "$(hostname -f 2>/dev/null || hostname 2>/dev/null)"
emit "collection_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
emit "os_release" "$(cat /etc/os-release 2>/dev/null || true)"
emit "kernel" "$(uname -r 2>/dev/null || true)"

# Required discovery data.
emit "uid_zero_accounts" "$(awk -F: '$3 == 0 {print $1 ":" $3 ":" $4 ":" $6 ":" $7}' /etc/passwd 2>/dev/null)"
emit "privileged_group" "$(getent group "$PRIVILEGED_GROUP" 2>/dev/null || true)"
account_record="$(getent passwd "$ACCOUNT" 2>/dev/null || true)"
emit "account_passwd" "$account_record"
emit "account_group" "$(getent group "$GROUP" 2>/dev/null || true)"
emit "target_uid_owner" "$(getent passwd "$TARGET_UID" 2>/dev/null || true)"
emit "target_gid_owner" "$(getent group "$TARGET_GID" 2>/dev/null || true)"
emit "account_id" "$(id "$ACCOUNT" 2>/dev/null || true)"
emit "account_passwd_status" "$(passwd -S "$ACCOUNT" 2>/dev/null || true)"
emit "account_chage" "$(chage -l "$ACCOUNT" 2>/dev/null || true)"
emit "account_sudo" "$(sudo -l -U "$ACCOUNT" 2>/dev/null || true)"

if [ -e "$TARGET_HOME" ]; then
    emit "account_home_stat" "$(stat -c '%n|owner=%U|uid=%u|group=%G|gid=%g|mode=%a|type=%F' "$TARGET_HOME" 2>/dev/null)"
else
    emit "account_home_stat" "MISSING"
fi

# Return an ownership count only; do not enumerate file names.
collection_status="COMPLETE"
if [ -n "$account_record" ]; then
    current_uid="$(id -u "$ACCOUNT" 2>/dev/null || true)"
    collect_ownership_count "$current_uid" || collection_status="INCOMPLETE"
else
    emit "account_owned_file_count" "NOT_APPLICABLE"
    emit "ownership_scan_status" "NOT_APPLICABLE"
fi

# Password policy and lockout evidence. The script reports but does not alter it.
emit "login_defs_password_policy" "$(
    grep -E '^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE)[[:space:]]+' \
        /etc/login.defs 2>/dev/null || true
)"
emit "faillock_conf" "$(cat /etc/security/faillock.conf 2>/dev/null || true)"
emit "faillock_pam_references" "$(
    grep -R -E '^[[:space:]]*auth.*pam_faillock\.so|^[[:space:]]*account.*pam_faillock\.so' \
        /etc/pam.d 2>/dev/null || true
)"

# Report current SSH password authentication state only.
# No SSH configuration or root policy is modified.
if command -v sshd >/dev/null 2>&1; then
    emit "sshd_effective_password_auth" "$(sshd -T 2>/dev/null | grep -E '^passwordauthentication ' || true)"
else
    emit "sshd_effective_password_auth" "sshd command not found"
fi

emit "sudoers_account_references" "$(
    grep -R -n -E "(^|[^[:alnum:]_])${ACCOUNT}([^[:alnum:]_]|$)" \
        /etc/sudoers /etc/sudoers.d 2>/dev/null || true
)"

emit "collection_complete" "$collection_status"
[ "$collection_status" = "COMPLETE" ]
"""


def build_remote_script(policy):
    return REMOTE_SCRIPT.replace("__POLICY_ASSIGNMENTS__", shell_assignments(policy))


def utc_now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def validate_target(host, username):
    """Reject whitespace, shell metacharacters and option-like inventory values."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]*", host):
        raise ValueError("Invalid inventory target; use a hostname or IP literal.")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*[$]?", username):
        raise ValueError("Invalid SSH username.")


def read_inventory(path):
    """Read hostname,username records from a simple CSV inventory."""
    entries = []

    with open(path, "r", encoding="utf-8", newline="") as handle:
        for number, row in enumerate(csv.reader(handle), start=1):
            if not row or not row[0].strip() or row[0].strip().startswith("#"):
                continue

            if len(row) != 2 or not row[1].strip():
                raise ValueError(
                    f"Inventory line {number} must contain exactly: hostname,ssh_username"
                )

            validate_target(row[0].strip(), row[1].strip())

            entries.append({
                "host": row[0].strip(),
                "username": row[1].strip(),
            })

    if not entries:
        raise ValueError("Inventory contains no valid host records.")

    return entries


def decode_records(output):
    """Parse base64-encoded key/value records emitted by the remote shell script."""
    records = {}

    for line in output.replace("\r", "").splitlines():
        if not line.startswith(MARKER + "\t"):
            continue

        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue

        _, key, encoded = parts
        try:
            records[key] = base64.b64decode(encoded).decode(
                "utf-8", errors="replace"
            )
        except Exception:
            records[key] = ""

    return records


def collect_host(host, username, password, policy):
    """
    Connect using a local SSH client through a pseudo-terminal.

    The password is sent only after SSH or sudo asks for it. It is never passed
    in an argument, environment variable, inventory, report, or temporary file.
    """
    ssh_binary = shutil.which("ssh")
    setsid_binary = shutil.which("setsid")
    if not ssh_binary or not setsid_binary:
        return {
            "transport_status": "ERROR",
            "error": "OpenSSH 'ssh' and util-linux 'setsid' must be available in PATH.",
            "data": {},
        }

    command = [
        # Give SSH this PTY as its controlling terminal, including /dev/tty.
        setsid_binary, "--ctty", "--wait",
        ssh_binary,
        "-tt",
        "-o", "BatchMode=no",
        "-o", "StrictHostKeyChecking=yes",
        "-o", f"ConnectTimeout={SSH_TIMEOUT}",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "PreferredAuthentications=keyboard-interactive,password",
        "-o", "PubkeyAuthentication=no",
        f"{username}@{host}",
        "sudo -S -p 'LOCAL_ADMIN_SUDO_PROMPT:' bash -c " + shlex.quote(build_remote_script(policy)),
    ]

    master_fd, slave_fd = pty.openpty()
    output = bytearray()

    try:
        process = subprocess.Popen(
            command,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
    except Exception as exc:
        os.close(master_fd)
        os.close(slave_fd)
        return {
            "transport_status": "ERROR",
            "error": f"Unable to start SSH: {exc}",
            "data": {},
        }

    os.close(slave_fd)

    ssh_password_sent = False
    sudo_password_sent = False
    deadline = time.monotonic() + SSH_TIMEOUT

    try:
        # Read until terminal EOF, not merely process exit. SSH can exit while
        # its final result is still buffered in the pseudo-terminal.
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                return {
                    "transport_status": "UNREACHABLE",
                    "error": f"Connection or collection timed out after {SSH_TIMEOUT} seconds.",
                    "data": {},
                }

            readable, _, _ = select.select([master_fd], [], [], min(1, remaining))
            if not readable:
                continue

            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break

            if not chunk:
                break

            output.extend(chunk)
            text = output.decode("utf-8", errors="replace").lower()

            # Submit existing account SSH password only after an SSH password prompt.
            if (
                not ssh_password_sent
                and "password:" in text
                and "local_admin_sudo_prompt:" not in text
            ):
                os.write(master_fd, (password + "\n").encode("utf-8"))
                ssh_password_sent = True

            # Submit same password to sudo, the script is already in the remote command.
            if not sudo_password_sent and "local_admin_sudo_prompt:" in text:
                os.write(master_fd, (password + "\n").encode("utf-8"))
                sudo_password_sent = True

        process.wait(timeout=5)

    except Exception as exc:
        process.kill()
        return {
            "transport_status": "ERROR",
            "error": f"SSH collection error: {exc}",
            "data": {},
        }
    finally:
        try:
            os.close(master_fd)
        except OSError:
            pass

    raw_output = output.decode("utf-8", errors="replace")
    records = decode_records(raw_output)

    if records.get("collection_complete") == "COMPLETE" and process.returncode == 0:
        return {
            "transport_status": "SUCCESS",
            "error": None,
            "data": records,
        }

    if records.get("collection_complete") == "INCOMPLETE":
        records["account_owned_file_count"] = "UNAVAILABLE"
        return {
            "transport_status": "INCOMPLETE",
            "error": "Ownership traversal failed or timed out; the count and collection are incomplete.",
            "data": records,
        }

    if records:
        return {
            "transport_status": "ERROR",
            "error": "Incomplete discovery response or unsuccessful SSH exit; do not use partial evidence.",
            "data": {},
        }

    lower = raw_output.lower()

    if "host key verification failed" in lower:
        error = "SSH host-key verification failed."
        status = "UNREACHABLE"
    elif "could not resolve hostname" in lower:
        error = "DNS/name resolution failed."
        status = "UNREACHABLE"
    elif "connection refused" in lower or "no route to host" in lower:
        error = "SSH connection failed."
        status = "UNREACHABLE"
    elif "permission denied" in lower:
        error = "SSH authentication failed or account is not authorized."
        status = "UNREACHABLE"
    elif "local_admin_sudo_prompt:" in lower:
        error = "sudo authentication failed or the account lacks sudo privileges."
        status = "INSUFFICIENT_PRIVILEGE"
    else:
        error = "No structured discovery response returned by target."
        status = "ERROR"

    return {
        "transport_status": status,
        "error": error,
        "data": {},
    }


def is_rhel9(os_release):
    return bool(
        re.search(r'^ID="?rhel"?$', os_release, re.MULTILINE | re.IGNORECASE)
        and re.search(r'^VERSION_ID="?9(?:\.[0-9]+)*"?$', os_release, re.MULTILINE)
    )


def split_passwd(value):
    parts = value.strip().split(":")
    if len(parts) != 7:
        return None
    return {
        "name": parts[0],
        "uid": parts[2],
        "gid": parts[3],
        "comment": parts[4],
        "home": parts[5],
        "shell": parts[6],
    }


def assess_host(host, username, collection, policy):
    policy = validate_policy(policy)
    result = {
        "host": host,
        "ssh_username_used": username,
        "assessment_time_utc": utc_now(),
        "overall_status": "ERROR",
        "findings": [],
        "evidence": {},
    }

    if collection["transport_status"] != "SUCCESS":
        result["overall_status"] = collection["transport_status"]
        result["findings"].append({
            "control": "REMOTE_ACCESS",
            "status": collection["transport_status"],
            "detail": collection["error"],
        })
        if collection["transport_status"] == "INCOMPLETE":
            result["evidence"] = dict(collection.get("data", {}))
            result["evidence"]["account_owned_file_count"] = "UNAVAILABLE"
        return result

    data = collection["data"]
    result["evidence"] = data

    scan_status = data.get("ownership_scan_status")
    count = data.get("account_owned_file_count", "")
    scan_valid = (
        scan_status == "COMPLETE" and re.fullmatch(r"[0-9]+", count) is not None
    ) or (
        scan_status == "NOT_APPLICABLE" and count == "NOT_APPLICABLE"
        and not data.get("account_passwd")
    )
    if data.get("collection_complete") != "COMPLETE" or not scan_valid:
        result["overall_status"] = "INCOMPLETE"
        result["evidence"] = dict(data, account_owned_file_count="UNAVAILABLE")
        result["findings"].append({
            "control": "OWNERSHIP_TRAVERSAL", "status": "INCOMPLETE",
            "detail": "A successful complete ownership scan was not established; no full count is available.",
        })
        return result

    if not is_rhel9(data.get("os_release", "")):
        result["overall_status"] = "UNAUTHORIZED_OR_UNSUPPORTED_OS"
        result["findings"].append({
            "control": "OS_VALIDATION",
            "status": "UNAUTHORIZED_OR_UNSUPPORTED_OS",
            "detail": "Target did not identify as RHEL 9.",
        })
        return result

    account = split_passwd(data.get("account_passwd", ""))
    uid_owner = split_passwd(data.get("target_uid_owner", ""))
    gid_owner = data.get("target_gid_owner", "").strip()

    conflicts = []
    remediation_items = []

    # The requested UID may only be owned by the selected account.
    if uid_owner and uid_owner["name"] != policy["account"]:
        conflicts.append(
            f"UID {policy['uid']} is already assigned to account '{uid_owner['name']}'."
        )

    # Group record format is name:password:GID:members.
    if gid_owner:
        gid_name = gid_owner.split(":", 1)[0]
        if gid_name != policy["group"]:
            conflicts.append(
                f"GID {policy['gid']} is already assigned to group '{gid_name}'."
            )

    if not account:
        remediation_items.append(f"{policy['account']} account is absent and can be created if no UID/GID conflict exists.")
    else:
        if account["uid"] != str(policy["uid"]):
            remediation_items.append(
                f"Account UID is {account['uid']}; required UID is {policy['uid']}."
            )
        if account["gid"] != str(policy["gid"]):
            remediation_items.append(
                f"Account primary GID is {account['gid']}; required GID is {policy['gid']}."
            )
        if account["comment"] != policy["comment"]:
            remediation_items.append("Account comment does not match the required standard.")
        if account["home"] != policy["home"]:
            remediation_items.append("Account home directory does not match the required standard.")
        if account["shell"] != policy["shell"]:
            remediation_items.append("Account login shell does not match the required standard.")

        home_stat = data.get("account_home_stat", "")
        home_fields = dict(item.split("=", 1) for item in home_stat.split("|") if "=" in item)
        if home_stat == "MISSING":
            remediation_items.append("Required home directory is missing.")
        elif home_fields.get("mode") != policy["home_mode"].lstrip("0"):
            remediation_items.append(f"Home directory mode is not {policy['home_mode']}.")

        privileged = data.get("privileged_group", "")
        privileged_members = privileged.split(":")[-1].split(",") if privileged else []
        if policy["account"] not in privileged_members:
            remediation_items.append(f"Account is not listed as a {policy['privileged_group']}-group member.")

    if conflicts:
        result["overall_status"] = "UID_GID_CONFLICT"
        for conflict in conflicts:
            result["findings"].append({
                "control": "IDENTITY_CONSISTENCY",
                "status": "UID_GID_CONFLICT",
                "detail": conflict,
            })
        return result

    if remediation_items:
        result["overall_status"] = "READY_FOR_REMEDIATION"
        for item in remediation_items:
            result["findings"].append({
                "control": "LOCAL_ADMIN_BASELINE",
                "status": "REMEDIATION_REQUIRED",
                "detail": item,
            })
    else:
        result["overall_status"] = "BASELINE_MATCHES_DISCOVERY"
        result["findings"].append({
            "control": "LOCAL_ADMIN_BASELINE",
            "status": "PASS",
            "detail": f"Account attributes match the selected {policy['account']} policy.",
        })

    # Password policy and faillock data are evidence only in this discovery phase.
    result["findings"].append({
        "control": "PASSWORD_AND_LOCKOUT_POLICY",
        "status": "INFORMATIONAL",
        "detail": (
            "Discovery collected password-aging and faillock evidence. "
            f"Selected policy: max={policy['password_max_days']}, min={policy['password_min_days']}, "
            f"warn={policy['password_warn_days']}, inactive={policy['password_inactive_days']}, "
            f"deny={policy['faillock_deny']}, unlock_time={policy['faillock_unlock_time_seconds']}. "
            "Faillock changes require the separate --manage-faillock option."
        ),
    })

    return result


def write_report(report):
    REPORT_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(REPORT_DIR, 0o700)

    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=REPORT_DIR,
        prefix=".latest.",
        suffix=".json",
        delete=False,
    ) as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")
        temporary_report = handle.name

    os.chmod(temporary_report, 0o600)
    os.replace(temporary_report, REPORT_FILE)


def main():
    parser = argparse.ArgumentParser(
        description="Read-only policy-driven local-account discovery for RHEL 9."
    )
    parser.add_argument("--policy", required=True, help="Approved private JSON policy; see policy.example.json and README.md.")
    parser.add_argument(
        "--inventory",
        required=True,
        help="CSV file containing: hostname_or_ip,existing_ssh_username",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        print(
            f"ERROR: Run with sudo/root to write {REPORT_FILE}.",
            file=sys.stderr,
        )
        return 2

    try:
        policy = load_policy(args.policy)
        inventory = read_inventory(args.inventory)
    except Exception as exc:
        print(f"ERROR: Input error: {exc}", file=sys.stderr)
        return 2

    print(policy_summary(policy))

    report = {
        "report_type": "local_admin_readiness_discovery",
        "schema_version": 2,
        "generated_utc": utc_now(),
        "policy": policy,
        "policy_sha256": policy_digest(policy),
        "execution": {
            "inventory": os.path.abspath(args.inventory),
            "remote_actions": "READ_ONLY",
            "internet_access": "NOT_ATTEMPTED",
            "ssh_host_key_policy": "STRICT_HOST_KEY_CHECKING",
            "retry_count": RETRIES,
            "connect_timeout_seconds": SSH_TIMEOUT,
        },
        "hosts": [],
        "summary": {},
    }

    for entry in inventory:
        host = entry["host"]
        username = entry["username"]

        print(f"\n--- {host} ({username}) ---")
        password = getpass.getpass(
            f"Password for {username}@{host} "
            "(also used for sudo; held in memory only): "
        )

        if not password:
            report["hosts"].append({
                "host": host,
                "ssh_username_used": username,
                "assessment_time_utc": utc_now(),
                "overall_status": "NOT_ASSESSED",
                "findings": [{
                    "control": "REMOTE_ACCESS",
                    "status": "NOT_ASSESSED",
                    "detail": "No password was supplied for this target.",
                }],
                "evidence": {},
            })
            continue

        last_collection = None
        for attempt in range(1, RETRIES + 2):
            print(f"Collecting read-only evidence (attempt {attempt})...")
            last_collection = collect_host(host, username, password, policy)
            if last_collection["transport_status"] == "SUCCESS":
                break
            if attempt <= RETRIES:
                time.sleep(2)

        host_result = assess_host(host, username, last_collection, policy)
        host_result["collection_attempts"] = attempt
        report["hosts"].append(host_result)

        # Remove local reference as soon as the host is complete.
        password = None

    report["hosts"].sort(key=lambda item: item["host"])

    counts = {}
    for item in report["hosts"]:
        status = item["overall_status"]
        counts[status] = counts.get(status, 0) + 1

    report["summary"] = {
        "target_count": len(report["hosts"]),
        "status_counts": counts,
        "report_path": str(REPORT_FILE),
    }

    try:
        write_report(report)
    except Exception as exc:
        print(f"ERROR: Could not write report: {exc}", file=sys.stderr)
        return 2

    print(f"\nReport written to: {REPORT_FILE}")
    print(json.dumps(report["summary"]["status_counts"], indent=2))

    # Discovery identifies readiness; nonzero indicates anything not already baseline-matching.
    nonzero = {
        "READY_FOR_REMEDIATION",
        "UID_GID_CONFLICT",
        "UNREACHABLE",
        "UNAUTHORIZED_OR_UNSUPPORTED_OS",
        "INSUFFICIENT_PRIVILEGE",
        "NOT_ASSESSED",
        "ERROR",
        "INCOMPLETE",
    }

    return 1 if any(h["overall_status"] in nonzero for h in report["hosts"]) else 0


if __name__ == "__main__":
    sys.exit(main())
