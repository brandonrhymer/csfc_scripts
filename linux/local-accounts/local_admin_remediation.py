#!/usr/bin/env python3
"""
Remediate an approved local-account policy on RHEL 9.
Supply the same private --policy JSON used for discovery; do not edit source values.

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
from account_policy import load_policy, policy_digest, policy_summary, shell_assignments


TIMEOUT_SECONDS = 60
RETRIES = 1

REPORT_DIR = Path("/var/log/local_admin_remediation")
REPORT_FILE = REPORT_DIR / "latest.json"

MARKER = "@@LOCAL_ADMIN_REMEDIATION@@"


REMOTE_TEMPLATE = r"""#!/bin/bash
set +e

__POLICY_ASSIGNMENTS__
APPLY_MODE="__APPLY_MODE__"
MANAGE_FAILLOCK="__MANAGE_FAILLOCK__"

emit() {
    local key="$1"
    local value="$2"
    value="$(printf '%s' "$value" | base64 | tr -d '\n')"
    printf '@@LOCAL_ADMIN_REMEDIATION@@\t%s\t%s\n' "$key" "$value"
}

fail() {
    emit "result" "FAILED"
    emit "failure_reason" "$1"
    exit 1
}

is_rhel9() {
    [ -r /etc/os-release ] || return 1
    . /etc/os-release
    [ "${ID}" = "rhel" ] && [[ "${VERSION_ID}" =~ ^9(\.[0-9]+)*$ ]]
}

# Only normal, unique local identities may be renumbered. Renumbering a shared
# UID would transfer another account's files; system identities need manual work.
local_identity_is_safe() {
    local file="$1" name="$2" number="$3"
    [[ "$number" =~ ^[0-9]+$ ]] && [ "$number" -ge 1000 ] || return 1
    awk -F: -v name="$name" -v number="$number" '
        $1 == name && $3 == number { exact++ }
        $3 == number { owners++ }
        END { exit !(exact == 1 && owners == 1) }
    ' "$file"
}

# A symbolic link in a home path could redirect chown/chmod to unrelated data.
# Validate every existing component, including the parent, without changing it.
home_path_is_safe() {
    local cursor="$1"
    [[ "$cursor" == /* ]] && [ "$cursor" != "/" ] || return 1
    while [ "$cursor" != "/" ]; do
        [ -L "$cursor" ] && return 1
        if [ -e "$cursor" ] && [ ! -d "$cursor" ]; then return 1; fi
        cursor="$(dirname -- "$cursor")" || return 1
    done
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

# Safety preflight: the requested UID/GID cannot belong to another identity.
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
    if [ "$gid_name" != "$GROUP" ]; then
        emit "result" "UID_GID_CONFLICT"
        emit "failure_reason" "GID ${TARGET_GID} belongs to existing group: ${gid_name}"
        exit 1
    fi
fi

existing_account="$(getent passwd "$ACCOUNT" 2>/dev/null || true)"
existing_group="$(getent group "$GROUP" 2>/dev/null || true)"

emit "preflight_existing_account" "$existing_account"
emit "preflight_existing_group" "$existing_group"

# These checks also run in dry-run mode and precede every account mutation.
home_path_is_safe "$TARGET_HOME" || fail "Unsafe home path; inspect symbolic links or non-directory components."
if [ -n "$existing_account" ]; then
    source_uid="$(printf '%s' "$existing_account" | cut -d: -f3)"
    source_home="$(printf '%s' "$existing_account" | cut -d: -f6)"
    local_identity_is_safe /etc/passwd "$ACCOUNT" "$source_uid" \
        || fail "Existing account is not a unique normal local identity; do not migrate it automatically."
    [ "$(getent passwd "$source_uid")" = "$existing_account" ] \
        || fail "Source UID lookup is ambiguous; resolve identity ownership manually."
    # Do not move arbitrary existing home trees. An operator must reconcile a
    # different home path before this utility normalizes the account.
    [ "$source_home" = "$TARGET_HOME" ] \
        || fail "Existing home differs from the target; migrate and verify it manually first."
fi
if [ -n "$existing_group" ]; then
    source_gid="$(printf '%s' "$existing_group" | cut -d: -f3)"
    [ "$source_gid" = "$TARGET_GID" ] \
        || fail "Existing group has a different GID; reconcile it manually before running this tool."
    local_identity_is_safe /etc/group "$GROUP" "$source_gid" \
        || fail "Existing group is not a unique normal local identity; reconcile it manually."
    [ "$(getent group "$source_gid")" = "$existing_group" ] \
        || fail "Source GID lookup is ambiguous; resolve group ownership manually."
fi

# Never adopt another account's home or an unexplained existing directory.
passwd_entries="$(getent passwd)" || fail "Could not check for shared home directories."
if printf '%s\n' "$passwd_entries" | awk -F: -v account="$ACCOUNT" -v home="$TARGET_HOME" '
    $1 != account && ($6 == home || index($6, home "/") == 1 || ($6 != "" && index(home, $6 "/") == 1)) { shared = 1 }
    END { exit !shared }
'; then
    fail "Another account uses this home or an overlapping path; reconcile it manually."
fi
if [ -e "$TARGET_HOME" ]; then
    [ -n "$existing_account" ] \
        || fail "Target home already exists without this account; reconcile it manually."
    [ "$(stat -c '%u' "$TARGET_HOME")" = "$source_uid" ] \
        || fail "Existing home is owned by another identity; reconcile it manually."
fi

getent group "$PRIVILEGED_GROUP" >/dev/null 2>&1 || fail "Required privileged supplementary group does not exist."
[ -x "$TARGET_SHELL" ] || fail "The policy login shell is not executable on this target."

if [ "$APPLY_MODE" != "true" ]; then
    emit "result" "DRY_RUN_READY"
    emit "detail" "No conflicts detected. Target is eligible for remediation."
    exit 0
fi

# Receive the selected account's password only after sudo authentication succeeded.
# read -s prevents terminal echo. The password is not logged or written to disk.
printf '@@LOCAL_ADMIN_NEW_PASSWORD_PROMPT@@\n'
IFS= read -r -s NEW_PASSWORD
printf '\n'

if [ -z "$NEW_PASSWORD" ]; then
    fail "No password was provided for ${ACCOUNT}."
fi

# Create the private primary group if absent. Existing GID mismatches are refused.
if ! getent group "$GROUP" >/dev/null 2>&1; then
    groupadd -g "$TARGET_GID" "$GROUP" || fail "Could not create group ${GROUP}."
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
        # Change the owner only. Files may intentionally belong to other groups.
        # A failed migration can leave partial changes and must never be success.
        find / -xdev -uid "$old_uid" -exec chown -h "$ACCOUNT" {} + 2>/dev/null \
            || fail "Ownership migration failed; inspect partial changes before retrying."
        emit "old_uid_migrated" "$old_uid"
    fi

    emit "account_action" "NORMALIZED"
fi

# Ensure required local access properties.
usermod -aG "$PRIVILEGED_GROUP" "$ACCOUNT" || fail "Could not add ${ACCOUNT} to ${PRIVILEGED_GROUP}."
home_path_is_safe "$TARGET_HOME" || fail "Home path became unsafe; inspect partial changes."
mkdir -p "$TARGET_HOME" || fail "Could not create home directory."
home_path_is_safe "$TARGET_HOME" || fail "Home path became unsafe; inspect partial changes."
chown "$ACCOUNT:$GROUP" "$TARGET_HOME" || fail "Could not set home ownership."
chmod "$HOME_MODE" "$TARGET_HOME" || fail "Could not set home mode to ${HOME_MODE}."

# Set shared vault-managed password without writing it to disk.
printf '%s:%s\n' "$ACCOUNT" "$NEW_PASSWORD" | chpasswd || fail "Could not set account password."
unset NEW_PASSWORD

# Apply account-specific password aging.
chage \
    -M "$PASS_MAX_DAYS" \
    -m "$PASS_MIN_DAYS" \
    -W "$PASS_WARN_DAYS" \
    -I "$PASS_INACTIVE_DAYS" \
    "$ACCOUNT" || fail "Could not set password aging."

# Unlock the selected account in case it was previously locked.
passwd -u "$ACCOUNT" >/dev/null 2>&1 || fail "Could not unlock ${ACCOUNT}."

# Optional: global faillock configuration. This affects locally authenticated users.
if [ "$MANAGE_FAILLOCK" = "true" ]; then
    ensure_faillock_setting "deny" "$FAILLOCK_DENY" || fail "Could not set faillock deny value."
    ensure_faillock_setting "unlock_time" "$FAILLOCK_UNLOCK_SECONDS" || fail "Could not set faillock unlock time."
    emit "faillock_action" "UPDATED_GLOBAL_FAILLOCK_CONF"
else
    emit "faillock_action" "NOT_CHANGED"
fi

# Post-remediation validation.
final_passwd="$(getent passwd "$ACCOUNT" 2>/dev/null || true)"
final_group="$(getent group "$GROUP" 2>/dev/null || true)"
final_id="$(id "$ACCOUNT" 2>/dev/null || true)"
final_home="$(stat -c '%n|owner=%U|uid=%u|group=%G|gid=%g|mode=%a' "$TARGET_HOME" 2>/dev/null || true)"
final_chage="$(chage -l "$ACCOUNT" 2>/dev/null || true)"
privileged_group="$(getent group "$PRIVILEGED_GROUP" 2>/dev/null || true)"

emit "final_passwd" "$final_passwd"
emit "final_group" "$final_group"
emit "final_id" "$final_id"
emit "final_home" "$final_home"
emit "final_chage" "$final_chage"
emit "final_privileged_group" "$privileged_group"

if ! id "$ACCOUNT" >/dev/null 2>&1; then
    fail "Post-remediation validation could not find ${ACCOUNT}."
fi

if [ "$(id -u "$ACCOUNT")" != "$TARGET_UID" ]; then
    fail "Post-remediation UID validation failed."
fi

if [ "$(id -g "$ACCOUNT")" != "$TARGET_GID" ]; then
    fail "Post-remediation GID validation failed."
fi

if ! id -nG "$ACCOUNT" | tr ' ' '\n' | grep -qx "$PRIVILEGED_GROUP"; then
    fail "Post-remediation privileged-group membership validation failed."
fi

if [ ! -d "$TARGET_HOME" ] || [ "$(stat -c '%a' "$TARGET_HOME")" != "${HOME_MODE#0}" ]; then
    fail "Post-remediation home-directory validation failed."
fi

[ "$(printf '%s' "$final_passwd" | cut -d: -f5)" = "$TARGET_COMMENT" ] \
    && [ "$(printf '%s' "$final_passwd" | cut -d: -f6)" = "$TARGET_HOME" ] \
    && [ "$(printf '%s' "$final_passwd" | cut -d: -f7)" = "$TARGET_SHELL" ] \
    || fail "Post-remediation account attributes differ from the selected policy."

emit "result" "REMEDIATED"
emit "detail" "${ACCOUNT} was created or normalized successfully."
exit 0
"""


def build_remote_script(policy, apply_mode=False, manage_faillock=False):
    template = REMOTE_TEMPLATE.replace(
        "__APPLY_MODE__", "true" if apply_mode else "false"
    ).replace("__MANAGE_FAILLOCK__", "true" if manage_faillock else "false")
    return template.replace("__POLICY_ASSIGNMENTS__", shell_assignments(policy))


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
    seen_hosts = set()

    with open(path, "r", encoding="utf-8", newline="") as handle:
        for line_no, row in enumerate(csv.reader(handle), start=1):
            if not row or not row[0].strip() or row[0].strip().startswith("#"):
                continue

            if len(row) != 2 or not row[1].strip():
                raise ValueError(
                    f"Inventory line {line_no} must be hostname_or_ip,existing_ssh_username"
                )

            validate_target(row[0].strip(), row[1].strip())

            host = row[0].strip()
            # Normalize spelling only. Aliases may still name the same machine;
            # the operator must keep each actual target in the inventory once.
            target_key = host.lower().rstrip(".")
            if target_key in seen_hosts:
                raise ValueError(f"Duplicate target on inventory line {line_no}; list each host once.")
            seen_hosts.add(target_key)
            records.append((host, row[1].strip()))

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


def run_remote(host, username, current_password, new_password, apply_mode, manage_faillock, policy):
    ssh = shutil.which("ssh")
    setsid = shutil.which("setsid")
    if not ssh or not setsid:
        return {"status": "ERROR", "error": "OpenSSH 'ssh' and util-linux 'setsid' must be available in PATH.", "data": {}}

    script = build_remote_script(policy, apply_mode, manage_faillock)

    command = [
        # Give SSH this PTY as its controlling terminal, including /dev/tty.
        setsid, "--ctty", "--wait",
        ssh,
        "-tt",
        "-o", "BatchMode=no",
        "-o", "StrictHostKeyChecking=yes",
        "-o", f"ConnectTimeout={TIMEOUT_SECONDS}",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "PreferredAuthentications=keyboard-interactive,password",
        "-o", "PubkeyAuthentication=no",
        f"{username}@{host}",
        "sudo -S -p 'LOCAL_ADMIN_SUDO_PROMPT:' bash -c " + shlex.quote(script),
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
        # Drain final buffered output even if the SSH process has already exited.
        while True:
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
                if proc.poll() is not None:
                    break
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
                and "local_admin_sudo_prompt:" not in text
            ):
                os.write(master, (current_password + "\n").encode())
                ssh_password_sent = True

            # Existing administrative account password for sudo.
            if not sudo_password_sent and "local_admin_sudo_prompt:" in text:
                os.write(master, (current_password + "\n").encode())
                sudo_password_sent = True

            # The selected account's new password is read remotely with `read -s`.
            if (
                apply_mode
                and not new_password_sent
                and "@@local_admin_new_password_prompt@@" in text
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

    return interpret_remote_response(
        output.decode("utf-8", errors="replace"), proc.returncode, apply_mode
    )


def interpret_remote_response(output, returncode, apply_mode):
    """Require a terminal success record AND a successful SSH exit.

    Missing, unexpected, or contradictory completion evidence is unverified,
    even if earlier structured records were received. Never infer success from
    partial evidence or retry an apply run automatically.
    """
    data = decode_records(output)
    status = data.get("result")
    expected = "REMEDIATED" if apply_mode else "DRY_RUN_READY"
    if status == expected and returncode == 0:
        return {"status": status, "error": None, "data": data}
    if status in {"FAILED", "UID_GID_CONFLICT", "UNSUPPORTED_OS"}:
        return {
            "status": status,
            "error": data.get("failure_reason") or "Remote script reported failure.",
            "data": data,
        }
    return {
        "status": "UNVERIFIED",
        "error": (
            "Remote completion was not verified: missing/unexpected final result "
            "or unsuccessful SSH exit. Inspect target state before retrying."
        ),
        "data": data,
    }


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
        description="Create or normalize an approved private account policy on RHEL 9 hosts."
    )
    parser.add_argument("--policy", required=True, help="Approved private JSON policy; see policy.example.json and README.md.")
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
        help="Set system-wide faillock values from the selected private policy on targets.",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        print(
            f"ERROR: Run as root or with sudo to write {REPORT_FILE}.",
            file=sys.stderr,
        )
        return 2

    try:
        policy = load_policy(args.policy)
        inventory = read_inventory(args.inventory)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    new_password = None
    print(policy_summary(policy))

    if args.apply:
        print(f"This will create or modify {policy['account']} on all eligible targets using the policy above.")
        if args.manage_faillock:
            print("The selected faillock values will also change system-wide authentication policy.")
        confirmation = input("Type APPLY to continue: ").strip()
        if confirmation != "APPLY":
            print("No changes made.")
            return 0

        new_password = getpass.getpass(
            f"Vault-managed password for {policy['account']}: "
        )
        confirm_password = getpass.getpass(
            "Re-enter vault-managed password for confirmation: "
        )

        if not new_password or new_password != confirm_password:
            print("ERROR: Passwords did not match or were empty.", file=sys.stderr)
            return 2

    report = {
        "report_type": "local_admin_remediation",
        "schema_version": 2,
        "generated_utc": now_utc(),
        "mode": "APPLY" if args.apply else "DRY_RUN",
        "run_status": "IN_PROGRESS",
        "planned_host_count": len(inventory),
        "manage_faillock": args.manage_faillock,
        "policy": policy,
        "policy_sha256": policy_digest(policy),
        "hosts": [],
        "summary": {},
    }

    # Confirm the report can be saved before changing any target. Later snapshots
    # retain finished hosts if the operator interrupts at the next prompt.
    try:
        write_report(report)
    except Exception as exc:
        print(f"ERROR: Unable to write report; no targets changed: {exc}", file=sys.stderr)
        return 2

    for host, username in inventory:
        print(f"\n--- {host} ({username}) ---")
        current_password = getpass.getpass(
            f"Current SSH/sudo password for {username}@{host}: "
        )

        attempt = 0
        if not current_password:
            response = {
                "status": "NOT_ASSESSED",
                "error": "No current administrative password supplied.",
                "data": {},
            }
        else:
            for attempt in range(1, (0 if args.apply else RETRIES) + 2):
                print(f"Running {'remediation' if args.apply else 'dry-run preflight'}; attempt {attempt}...")
                response = run_remote(
                    host=host,
                    username=username,
                    current_password=current_password,
                    new_password=new_password or "",
                    apply_mode=args.apply,
                    manage_faillock=args.manage_faillock,
                    policy=policy,
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
        try:
            write_report(report)
        except Exception as exc:
            print(f"ERROR: Unable to save {host}'s result; stopping before the next target: {exc}", file=sys.stderr)
            return 2

    # Remove shared new-account credential reference before report writing.
    new_password = None
    confirm_password = None

    report["hosts"].sort(key=lambda item: item["host"])
    report["run_status"] = "COMPLETE"

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

    # Fail closed: only the expected completion for this mode is success.
    expected_status = "REMEDIATED" if args.apply else "DRY_RUN_READY"
    return 1 if any(
        host["status"] != expected_status for host in report["hosts"]
    ) else 0


if __name__ == "__main__":
    sys.exit(main())
