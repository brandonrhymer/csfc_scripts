#!/usr/bin/env python3
"""
Remediate an illustrative temporary account: example_admin

Example identity/policy only. Review and adapt privately before use.

Inventory format:
    hostname_or_ip,existing_ssh_username

Reserved examples (replace outside Git):
    host1.example.invalid,example_operator_1
    host2.example.invalid,example_operator_2

Defaults to dry-run. Use --apply to make changes.
Use --manage-faillock only when authorized to change the system-wide
faillock configuration on every target.
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
UID = 20000
GID = 20000
HOME = "/home/example_admin"
SHELL = "/bin/bash"
COMMENT = "Local Administrative Account"

PASS_MAX_DAYS = 60
PASS_MIN_DAYS = 1
PASS_WARN_DAYS = 14
PASS_INACTIVE_DAYS = 60

FAILLOCK_DENY = 3
FAILLOCK_UNLOCK_SECONDS = 900

TIMEOUT_SECONDS = 60
RETRIES = 1

REPORT_DIR = Path("/var/log/example_admin_remediation")
REPORT_FILE = REPORT_DIR / "latest.json"

MARKER = "@@EXAMPLE_ADMIN_REMEDIATION@@"


REMOTE_TEMPLATE = r"""#!/bin/bash
set +e

ACCOUNT="example_admin"
TARGET_UID="20000"
TARGET_GID="20000"
TARGET_HOME="/home/example_admin"
TARGET_SHELL="/bin/bash"
TARGET_COMMENT="Local Administrative Account"
APPLY_MODE="__APPLY_MODE__"
MANAGE_FAILLOCK="__MANAGE_FAILLOCK__"

emit() {
    local key="$1"
    local value="$2"
    value="$(printf '%s' "$value" | base64 | tr -d '\n')"
    printf '@@EXAMPLE_ADMIN_REMEDIATION@@\t%s\t%s\n' "$key" "$value"
}

fail() {
    emit "result" "FAILED"
    emit "failure_reason" "$1"
    exit 1
}

is_rhel9() {
    [ -r /etc/os-release ] || return 1
    . /etc/os-release
    [ "${ID}" = "rhel" ] && [[ "${VERSION_ID}" == 9* ]]
}

ensure_faillock_setting() {
    local key="$1"
    local value="$2"
    local file="/etc/security/faillock.conf"

    touch "$file" || return 1

    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
    else
        printf '%s = %s\n' "$key" "$value" >> "$file"
    fi
}

emit "hostname" "$(hostname -f 2>/dev/null || hostname)"
emit "os_release" "$(cat /etc/os-release 2>/dev/null || true)"
emit "apply_mode" "$APPLY_MODE"
emit "manage_faillock" "$MANAGE_FAILLOCK"

if ! is_rhel9; then
    emit "result" "UNSUPPORTED_OS"
    emit "failure_reason" "Target is not RHEL 9."
    exit 1
fi

# Safety preflight: UID/GID 20000 cannot belong to any other identity.
uid_owner="$(getent passwd "$TARGET_UID" 2>/dev/null || true)"
if [ -n "$uid_owner" ]; then
    uid_name="$(printf '%s' "$uid_owner" | cut -d: -f1)"
    if [ "$uid_name" != "$ACCOUNT" ]; then
        emit "result" "UID_GID_CONFLICT"
        emit "failure_reason" "UID ${TARGET_UID} belongs to existing account: ${uid_name}"
        exit 1
    fi
fi

gid_owner="$(getent group "$TARGET_GID" 2>/dev/null || true)"
if [ -n "$gid_owner" ]; then
    gid_name="$(printf '%s' "$gid_owner" | cut -d: -f1)"
    if [ "$gid_name" != "$ACCOUNT" ]; then
        emit "result" "UID_GID_CONFLICT"
        emit "failure_reason" "GID ${TARGET_GID} belongs to existing group: ${gid_name}"
        exit 1
    fi
fi

existing_account="$(getent passwd "$ACCOUNT" 2>/dev/null || true)"
existing_group="$(getent group "$ACCOUNT" 2>/dev/null || true)"

emit "preflight_existing_account" "$existing_account"
emit "preflight_existing_group" "$existing_group"

if [ "$APPLY_MODE" != "true" ]; then
    emit "result" "DRY_RUN_READY"
    emit "detail" "No conflicts detected. Target is eligible for remediation."
    exit 0
fi

# Receive the new example_admin password only after sudo authentication succeeded.
# read -s prevents terminal echo. The password is not logged or written to disk.
printf '@@EXAMPLE_ADMIN_NEW_PASSWORD_PROMPT@@\n'
IFS= read -r -s NEW_PASSWORD
printf '\n'

if [ -z "$NEW_PASSWORD" ]; then
    fail "No example_admin password was provided."
fi

# Create or normalize private primary group.
if ! getent group "$ACCOUNT" >/dev/null 2>&1; then
    groupadd -g "$TARGET_GID" "$ACCOUNT" || fail "Could not create group ${ACCOUNT}."
else
    current_gid="$(getent group "$ACCOUNT" | cut -d: -f3)"
    if [ "$current_gid" != "$TARGET_GID" ]; then
        groupmod -g "$TARGET_GID" "$ACCOUNT" || fail "Could not set GID for ${ACCOUNT}."
    fi
fi

if ! getent passwd "$ACCOUNT" >/dev/null 2>&1; then
    useradd \
        -u "$TARGET_UID" \
        -g "$TARGET_GID" \
        -c "$TARGET_COMMENT" \
        -d "$TARGET_HOME" \
        -m \
        -s "$TARGET_SHELL" \
        "$ACCOUNT" || fail "Could not create ${ACCOUNT}."
    emit "account_action" "CREATED"
else
    old_uid="$(id -u "$ACCOUNT" 2>/dev/null || true)"

    # Normalize account identity and attributes.
    usermod \
        -u "$TARGET_UID" \
        -g "$TARGET_GID" \
        -c "$TARGET_COMMENT" \
        -d "$TARGET_HOME" \
        -m \
        -s "$TARGET_SHELL" \
        "$ACCOUNT" || fail "Could not normalize ${ACCOUNT}."

    # Preserve local ownership for files on the root filesystem that used the
    # account's prior UID. Separate mount points are deliberately not changed.
    if [ -n "$old_uid" ] && [ "$old_uid" != "$TARGET_UID" ]; then
        find / -xdev -uid "$old_uid" -exec chown -h "$ACCOUNT:$ACCOUNT" {} + 2>/dev/null
        emit "old_uid_migrated" "$old_uid"
    fi

    emit "account_action" "NORMALIZED"
fi

# Ensure required local access properties.
usermod -aG wheel "$ACCOUNT" || fail "Could not add ${ACCOUNT} to wheel."
mkdir -p "$TARGET_HOME" || fail "Could not create home directory."
chown "$ACCOUNT:$ACCOUNT" "$TARGET_HOME" || fail "Could not set home ownership."
chmod 0700 "$TARGET_HOME" || fail "Could not set home mode to 0700."

# Set shared vault-managed password without writing it to disk.
printf '%s:%s\n' "$ACCOUNT" "$NEW_PASSWORD" | chpasswd || fail "Could not set account password."
unset NEW_PASSWORD

# Apply account-specific password aging.
chage \
    -M 60 \
    -m 1 \
    -W 14 \
    -I 60 \
    "$ACCOUNT" || fail "Could not set password aging."

# Unlock example_admin in case it was previously locked.
passwd -u "$ACCOUNT" >/dev/null 2>&1 || true

# Optional: global faillock configuration. This affects locally authenticated users.
if [ "$MANAGE_FAILLOCK" = "true" ]; then
    ensure_faillock_setting "deny" "3" || fail "Could not set faillock deny value."
    ensure_faillock_setting "unlock_time" "900" || fail "Could not set faillock unlock time."
    emit "faillock_action" "UPDATED_GLOBAL_FAILLOCK_CONF"
else
    emit "faillock_action" "NOT_CHANGED"
fi

# Post-remediation validation.
final_passwd="$(getent passwd "$ACCOUNT" 2>/dev/null || true)"
final_group="$(getent group "$ACCOUNT" 2>/dev/null || true)"
final_id="$(id "$ACCOUNT" 2>/dev/null || true)"
final_home="$(stat -c '%n|owner=%U|uid=%u|group=%G|gid=%g|mode=%a' "$TARGET_HOME" 2>/dev/null || true)"
final_chage="$(chage -l "$ACCOUNT" 2>/dev/null || true)"
wheel_group="$(getent group wheel 2>/dev/null || true)"

emit "final_passwd" "$final_passwd"
emit "final_group" "$final_group"
emit "final_id" "$final_id"
emit "final_home" "$final_home"
emit "final_chage" "$final_chage"
emit "final_wheel_group" "$wheel_group"

if ! id "$ACCOUNT" >/dev/null 2>&1; then
    fail "Post-remediation validation could not find ${ACCOUNT}."
fi

if [ "$(id -u "$ACCOUNT")" != "$TARGET_UID" ]; then
    fail "Post-remediation UID validation failed."
fi

if [ "$(id -g "$ACCOUNT")" != "$TARGET_GID" ]; then
    fail "Post-remediation GID validation failed."
fi

if ! id -nG "$ACCOUNT" | tr ' ' '\n' | grep -qx "wheel"; then
    fail "Post-remediation wheel membership validation failed."
fi

if [ ! -d "$TARGET_HOME" ] || [ "$(stat -c '%a' "$TARGET_HOME")" != "700" ]; then
    fail "Post-remediation home-directory validation failed."
fi

emit "result" "REMEDIATED"
emit "detail" "example_admin was created or normalized successfully."
exit 0
"""


def now_utc():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def validate_target(host, username):
    """Reject whitespace, shell metacharacters and option-like inventory values."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]*", host):
        raise ValueError("Invalid inventory target; use a hostname or IP literal.")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*[$]?", username):
        raise ValueError("Invalid SSH username.")


def read_inventory(path):
    records = []

    with open(path, "r", encoding="utf-8", newline="") as handle:
        for line_no, row in enumerate(csv.reader(handle), start=1):
            if not row or not row[0].strip() or row[0].strip().startswith("#"):
                continue

            if len(row) != 2 or not row[1].strip():
                raise ValueError(
                    f"Inventory line {line_no} must be hostname_or_ip,existing_ssh_username"
                )

            validate_target(row[0].strip(), row[1].strip())

            records.append((row[0].strip(), row[1].strip()))

    if not records:
        raise ValueError("Inventory contains no usable hosts.")

    return records


def decode_records(output):
    result = {}

    for line in output.replace("\r", "").splitlines():
        if not line.startswith(MARKER + "\t"):
            continue

        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue

        try:
            result[parts[1]] = base64.b64decode(parts[2]).decode(
                "utf-8", errors="replace"
            )
        except Exception:
            result[parts[1]] = ""

    return result


def run_remote(host, username, current_password, new_password, apply_mode, manage_faillock):
    ssh = shutil.which("ssh")
    if not ssh:
        return {"status": "ERROR", "error": "ssh client not found", "data": {}}

    script = REMOTE_TEMPLATE.replace(
        "__APPLY_MODE__", "true" if apply_mode else "false"
    ).replace(
        "__MANAGE_FAILLOCK__", "true" if manage_faillock else "false"
    )

    command = [
        ssh,
        "-tt",
        "-o", "BatchMode=no",
        "-o", "StrictHostKeyChecking=yes",
        "-o", f"ConnectTimeout={TIMEOUT_SECONDS}",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "PreferredAuthentications=keyboard-interactive,password",
        "-o", "PubkeyAuthentication=no",
        f"{username}@{host}",
        "sudo -S -p 'EXAMPLE_ADMIN_SUDO_PROMPT:' bash -c " + shlex.quote(script),
    ]

    master, slave = pty.openpty()
    output = bytearray()

    try:
        proc = subprocess.Popen(
            command,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
    except Exception as exc:
        os.close(master)
        os.close(slave)
        return {"status": "ERROR", "error": str(exc), "data": {}}

    os.close(slave)

    ssh_password_sent = False
    sudo_password_sent = False
    new_password_sent = False
    deadline = time.monotonic() + TIMEOUT_SECONDS

    try:
        while proc.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                proc.kill()
                return {
                    "status": "TIMEOUT",
                    "error": f"Timed out after {TIMEOUT_SECONDS} seconds.",
                    "data": {},
                }

            readable, _, _ = select.select([master], [], [], min(1, remaining))
            if not readable:
                continue

            try:
                chunk = os.read(master, 4096)
            except OSError:
                break

            if not chunk:
                break

            output.extend(chunk)
            text = output.decode("utf-8", errors="replace").lower()

            # Existing administrative account password for SSH.
            if (
                not ssh_password_sent
                and "password:" in text
                and "example_admin_sudo_prompt:" not in text
            ):
                os.write(master, (current_password + "\n").encode())
                ssh_password_sent = True

            # Existing administrative account password for sudo.
            if not sudo_password_sent and "example_admin_sudo_prompt:" in text:
                os.write(master, (current_password + "\n").encode())
                sudo_password_sent = True

            # New vault-managed example_admin password is read remotely with `read -s`.
            if (
                apply_mode
                and not new_password_sent
                and "@@example_admin_new_password_prompt@@" in text
            ):
                os.write(master, (new_password + "\n").encode())
                new_password_sent = True

        proc.wait(timeout=5)

    except Exception as exc:
        proc.kill()
        return {"status": "ERROR", "error": str(exc), "data": {}}
    finally:
        try:
            os.close(master)
        except OSError:
            pass

    data = decode_records(output.decode("utf-8", errors="replace"))

    if data:
        return {
            "status": data.get("result", "UNKNOWN"),
            "error": data.get("failure_reason"),
            "data": data,
        }

    raw = output.decode("utf-8", errors="replace").lower()
    if "host key verification failed" in raw:
        error = "Host-key verification failed."
    elif "could not resolve hostname" in raw:
        error = "DNS/name resolution failed."
    elif "permission denied" in raw:
        error = "SSH authentication failed."
    elif "example_admin_sudo_prompt:" in raw:
        error = "sudo authentication failed or account lacks sudo."
    else:
        error = "No structured response received from target."

    return {"status": "ERROR", "error": error, "data": {}}


def write_report(report):
    REPORT_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(REPORT_DIR, 0o700)

    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=REPORT_DIR,
        prefix=".latest.",
        suffix=".json",
        delete=False,
    ) as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")
        temporary_name = handle.name

    os.chmod(temporary_name, 0o600)
    os.replace(temporary_name, REPORT_FILE)


def main():
    parser = argparse.ArgumentParser(
        description="Create or normalize example_admin on RHEL 9 hosts."
    )
    parser.add_argument(
        "--inventory",
        required=True,
        help="CSV: hostname_or_ip,existing_ssh_username",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Make changes. Without this option, performs dry-run preflight only.",
    )
    parser.add_argument(
        "--manage-faillock",
        action="store_true",
        help="Set global faillock deny=3 and unlock_time=900 on targets.",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        print(
            f"ERROR: Run as root or with sudo to write {REPORT_FILE}.",
            file=sys.stderr,
        )
        return 2

    try:
        inventory = read_inventory(args.inventory)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    new_password = None

    if args.apply:
        print("This will create or modify example_admin on all eligible targets.")
        confirmation = input("Type APPLY to continue: ").strip()
        if confirmation != "APPLY":
            print("No changes made.")
            return 0

        new_password = getpass.getpass(
            "Vault-managed password for new example_admin account: "
        )
        confirm_password = getpass.getpass(
            "Re-enter vault-managed password for confirmation: "
        )

        if not new_password or new_password != confirm_password:
            print("ERROR: Passwords did not match or were empty.", file=sys.stderr)
            return 2

    report = {
        "report_type": "example_admin_remediation",
        "generated_utc": now_utc(),
        "mode": "APPLY" if args.apply else "DRY_RUN",
        "manage_faillock": args.manage_faillock,
        "baseline": {
            "account": ACCOUNT,
            "uid": UID,
            "gid": GID,
            "group": ACCOUNT,
            "home": HOME,
            "home_mode": "0700",
            "shell": SHELL,
            "comment": COMMENT,
            "wheel_required": True,
            "password_max_days": PASS_MAX_DAYS,
            "password_min_days": PASS_MIN_DAYS,
            "password_warn_days": PASS_WARN_DAYS,
            "password_inactive_days": PASS_INACTIVE_DAYS,
            "faillock_deny": FAILLOCK_DENY,
            "faillock_unlock_time_seconds": FAILLOCK_UNLOCK_SECONDS,
        },
        "hosts": [],
        "summary": {},
    }

    for host, username in inventory:
        print(f"\n--- {host} ({username}) ---")
        current_password = getpass.getpass(
            f"Current SSH/sudo password for {username}@{host}: "
        )

        if not current_password:
            report["hosts"].append({
                "host": host,
                "ssh_username_used": username,
                "status": "NOT_ASSESSED",
                "error": "No current administrative password supplied.",
            })
            continue

        response = None
        for attempt in range(1, (0 if args.apply else RETRIES) + 2):
            print(f"Running {'remediation' if args.apply else 'dry-run preflight'}; attempt {attempt}...")
            response = run_remote(
                host=host,
                username=username,
                current_password=current_password,
                new_password=new_password or "",
                apply_mode=args.apply,
                manage_faillock=args.manage_faillock,
            )
            if args.apply or response["status"] not in {"ERROR", "TIMEOUT"}:
                break
            if attempt <= RETRIES:
                time.sleep(2)

        report["hosts"].append({
            "host": host,
            "ssh_username_used": username,
            "attempts": attempt,
            "status": response["status"],
            "error": response["error"],
            "evidence": response["data"],
        })

        # Remove current host credential reference after use.
        current_password = None

    # Remove shared new-account credential reference before report writing.
    new_password = None
    confirm_password = None

    report["hosts"].sort(key=lambda item: item["host"])

    status_counts = {}
    for host_result in report["hosts"]:
        status = host_result["status"]
        status_counts[status] = status_counts.get(status, 0) + 1

    report["summary"] = {
        "host_count": len(report["hosts"]),
        "status_counts": status_counts,
        "report_path": str(REPORT_FILE),
    }

    try:
        write_report(report)
    except Exception as exc:
        print(f"ERROR: Unable to write report: {exc}", file=sys.stderr)
        return 2

    print(f"\nReport written to: {REPORT_FILE}")
    print(json.dumps(status_counts, indent=2))

    failure_statuses = {
        "ERROR",
        "TIMEOUT",
        "FAILED",
        "UID_GID_CONFLICT",
        "UNSUPPORTED_OS",
        "NOT_ASSESSED",
    }

    return 1 if any(
        host["status"] in failure_statuses for host in report["hosts"]
    ) else 0


if __name__ == "__main__":
    sys.exit(main())
