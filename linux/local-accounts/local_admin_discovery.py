#!/usr/bin/env python3
"""
Read-only example_admin readiness discovery for RHEL 9.

Illustrative baseline only; review and adapt privately before use:
  Account:        example_admin
  UID:            20000
  Private group:  example_admin
  GID:            20000
  Home:           /home/example_admin
  Home mode:      0700
  Shell:          /bin/bash
  Comment:        Local Administrative Account
  Privilege:      member of wheel
  Password age:   max 60, min 1, warn 14, inactive 60
  Lockout:        deny 3, unlock_time 900 seconds

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


ACCOUNT = "example_admin"
TARGET_UID = 20000
TARGET_GID = 20000
TARGET_HOME = "/home/example_admin"
TARGET_SHELL = "/bin/bash"
TARGET_COMMENT = "Local Administrative Account"

REPORT_DIR = Path("/var/log/example_admin_assessment")
REPORT_FILE = REPORT_DIR / "latest.json"

SSH_TIMEOUT = 60
RETRIES = 1
MARKER = "@@EXAMPLE_ADMIN@@"


REMOTE_SCRIPT = r"""#!/bin/bash
# Read-only script. This entire script runs with sudo privileges.
set +e

emit() {
    local key="$1"
    local value="$2"
    value="$(printf '%s' "$value" | base64 | tr -d '\n')"
    printf '@@EXAMPLE_ADMIN@@\t%s\t%s\n' "$key" "$value"
}

emit "hostname" "$(hostname -f 2>/dev/null || hostname 2>/dev/null)"
emit "collection_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
emit "os_release" "$(cat /etc/os-release 2>/dev/null || true)"
emit "kernel" "$(uname -r 2>/dev/null || true)"

# Required discovery data.
emit "uid_zero_accounts" "$(awk -F: '$3 == 0 {print $1 ":" $3 ":" $4 ":" $6 ":" $7}' /etc/passwd 2>/dev/null)"
emit "wheel_group" "$(getent group wheel 2>/dev/null || true)"
emit "example_admin_passwd" "$(getent passwd example_admin 2>/dev/null || true)"
emit "example_admin_group" "$(getent group example_admin 2>/dev/null || true)"
emit "uid_20000_owner" "$(getent passwd 20000 2>/dev/null || true)"
emit "gid_20000_owner" "$(getent group 20000 2>/dev/null || true)"
emit "example_admin_id" "$(id example_admin 2>/dev/null || true)"
emit "example_admin_passwd_status" "$(passwd -S example_admin 2>/dev/null || true)"
emit "example_admin_chage" "$(chage -l example_admin 2>/dev/null || true)"
emit "example_admin_sudo" "$(sudo -l -U example_admin 2>/dev/null || true)"

if [ -e /home/example_admin ]; then
    emit "example_admin_home_stat" "$(stat -c '%n|owner=%U|uid=%u|group=%G|gid=%g|mode=%a|type=%F' /home/example_admin 2>/dev/null)"
else
    emit "example_admin_home_stat" "MISSING"
fi

# Return an ownership count only; do not enumerate file names.
current_uid="$(id -u example_admin 2>/dev/null || true)"
if [ -n "$current_uid" ]; then
    emit "example_admin_owned_file_count" "$(
        timeout 30 find / -xdev -uid "$current_uid" -printf '.' 2>/dev/null | wc -c
    )"
else
    emit "example_admin_owned_file_count" "NOT_APPLICABLE"
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

emit "sudoers_example_admin_references" "$(
    grep -R -n -E '(^|[^[:alnum:]_])example_admin([^[:alnum:]_]|$)' \
        /etc/sudoers /etc/sudoers.d 2>/dev/null || true
)"

emit "collection_complete" "COMPLETE"
exit 0
"""


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


def collect_host(host, username, password):
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
        "sudo -S -p 'EXAMPLE_ADMIN_SUDO_PROMPT:' bash -c " + shlex.quote(REMOTE_SCRIPT),
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
                if process.poll() is not None:
                    break
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
                and "example_admin_sudo_prompt:" not in text
            ):
                os.write(master_fd, (password + "\n").encode("utf-8"))
                ssh_password_sent = True

            # Submit same password to sudo, the script is already in the remote command.
            if not sudo_password_sent and "example_admin_sudo_prompt:" in text:
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
    elif "example_admin_sudo_prompt:" in lower:
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


def assess_host(host, username, collection):
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
        return result

    data = collection["data"]
    result["evidence"] = data

    if not is_rhel9(data.get("os_release", "")):
        result["overall_status"] = "UNAUTHORIZED_OR_UNSUPPORTED_OS"
        result["findings"].append({
            "control": "OS_VALIDATION",
            "status": "UNAUTHORIZED_OR_UNSUPPORTED_OS",
            "detail": "Target did not identify as RHEL 9.",
        })
        return result

    account = split_passwd(data.get("example_admin_passwd", ""))
    uid_owner = split_passwd(data.get("uid_20000_owner", ""))
    gid_owner = data.get("gid_20000_owner", "").strip()

    conflicts = []
    remediation_items = []

    # UID 20000 may only be owned by example_admin.
    if uid_owner and uid_owner["name"] != ACCOUNT:
        conflicts.append(
            f"UID {TARGET_UID} is already assigned to account '{uid_owner['name']}'."
        )

    # Group record format is name:password:GID:members.
    if gid_owner:
        gid_name = gid_owner.split(":", 1)[0]
        if gid_name != ACCOUNT:
            conflicts.append(
                f"GID {TARGET_GID} is already assigned to group '{gid_name}'."
            )

    if not account:
        remediation_items.append("example_admin account is absent and can be created if no UID/GID conflict exists.")
    else:
        if account["uid"] != str(TARGET_UID):
            remediation_items.append(
                f"Account UID is {account['uid']}; required UID is {TARGET_UID}."
            )
        if account["gid"] != str(TARGET_GID):
            remediation_items.append(
                f"Account primary GID is {account['gid']}; required GID is {TARGET_GID}."
            )
        if account["comment"] != TARGET_COMMENT:
            remediation_items.append("Account comment does not match the required standard.")
        if account["home"] != TARGET_HOME:
            remediation_items.append("Account home directory does not match the required standard.")
        if account["shell"] != TARGET_SHELL:
            remediation_items.append("Account login shell does not match the required standard.")

        home_stat = data.get("example_admin_home_stat", "")
        if home_stat == "MISSING":
            remediation_items.append("Required home directory is missing.")
        elif "mode=700" not in home_stat:
            remediation_items.append("Home directory mode is not 0700.")

        wheel = data.get("wheel_group", "")
        wheel_members = wheel.split(":")[-1].split(",") if wheel else []
        if ACCOUNT not in wheel_members:
            remediation_items.append("Account is not listed as a wheel-group member.")

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
                "control": "EXAMPLE_ADMIN_BASELINE",
                "status": "REMEDIATION_REQUIRED",
                "detail": item,
            })
    else:
        result["overall_status"] = "BASELINE_MATCHES_DISCOVERY"
        result["findings"].append({
            "control": "EXAMPLE_ADMIN_BASELINE",
            "status": "PASS",
            "detail": "Account attributes match the defined example_admin baseline.",
        })

    # Password policy and faillock data are evidence only in this discovery phase.
    result["findings"].append({
        "control": "PASSWORD_AND_LOCKOUT_POLICY",
        "status": "INFORMATIONAL",
        "detail": (
            "Discovery collected password-aging and faillock evidence. "
            "Later remediation should enforce max=60, min=1, warn=14, "
            "inactive=60, deny=3, unlock_time=900."
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
        description="Read-only example_admin readiness discovery for RHEL 9."
    )
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
        inventory = read_inventory(args.inventory)
    except Exception as exc:
        print(f"ERROR: Inventory error: {exc}", file=sys.stderr)
        return 2

    report = {
        "report_type": "example_admin_readiness_discovery",
        "generated_utc": utc_now(),
        "target_baseline": {
            "account": ACCOUNT,
            "uid": TARGET_UID,
            "group": ACCOUNT,
            "gid": TARGET_GID,
            "home": TARGET_HOME,
            "home_mode": "0700",
            "shell": TARGET_SHELL,
            "comment": TARGET_COMMENT,
            "wheel_membership_required": True,
            "password_max_days": 60,
            "password_min_days": 1,
            "password_warn_days": 14,
            "password_inactive_days": 60,
            "faillock_deny": 3,
            "faillock_unlock_time_seconds": 900,
        },
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
            last_collection = collect_host(host, username, password)
            if last_collection["transport_status"] == "SUCCESS":
                break
            if attempt <= RETRIES:
                time.sleep(2)

        host_result = assess_host(host, username, last_collection)
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
    }

    return 1 if any(h["overall_status"] in nonzero for h in report["hosts"]) else 0


if __name__ == "__main__":
    sys.exit(main())
