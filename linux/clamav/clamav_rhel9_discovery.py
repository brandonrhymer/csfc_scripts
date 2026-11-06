#!/usr/bin/env python3
"""
Read-only ClamAV discovery and preliminary assessment for RHEL 9 hosts.

Requirements:
  - Python 3 standard library
  - OpenSSH client (/usr/bin/ssh or ssh in PATH)
  - An inventory text file: one hostname or IP address per line
  - SSH host keys already trusted by the executing account
  - Same SSH and sudo password on all targets

The script:
  - Does not change remote configuration; scanner checks may write normal logs.
  - Does not update signatures; freshclam is invoked only with --version.
  - Writes one local JSON report to /var/log/clamav_assessment/latest.json.
"""

import argparse
import base64
import concurrent.futures
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


REPORT_DIR = Path("/var/log/clamav_assessment")
REPORT_FILE = REPORT_DIR / "latest.json"

CONNECT_TIMEOUT_SECONDS = 60
RETRIES = 1
MAX_WORKERS = 5
SIGNATURE_MAX_AGE_DAYS = 7

# This marker identifies structured data returned by the remote collection script.
MARKER = "@@CLAMAV@@"

REMOTE_SCRIPT = r"""#!/bin/bash
# Read-only remote collection script. Passed as one quoted argument to sudo bash -c
set +e

emit() {
    local key="$1"
    local value="$2"
    value="$(printf '%s' "$value" | base64 | tr -d '\n')"
    printf '@@CLAMAV@@\t%s\t%s\n' "$key" "$value"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

emit "hostname" "$(hostname -f 2>/dev/null || hostname 2>/dev/null)"
emit "date_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

if [ -r /etc/os-release ]; then
    emit "os_release" "$(cat /etc/os-release)"
else
    emit "os_release" ""
fi

emit "kernel" "$(uname -r 2>/dev/null)"
emit "id" "$(id 2>/dev/null)"

# Installed ClamAV-related RPMs.
emit "clamav_rpms" "$(
    rpm -qa --qf '%{NAME}|%{VERSION}-%{RELEASE}|%{ARCH}\n' 2>/dev/null \
      | grep -Ei '(^|[-_.])(clamav|clamd)([-_.]|$)' || true
)"

# Executable presence and versions.
for binary in clamscan clamdscan clamd freshclam; do
    if command_exists "$binary"; then
        path="$(command -v "$binary")"
        version="$("$binary" --version 2>&1 | head -n 1)"
        emit "binary_${binary}" "${path}|${version}"
    else
        emit "binary_${binary}" ""
    fi
done

# Candidate systemd unit files and current service states.
unit_files="$(systemctl list-unit-files --type=service --type=socket --type=timer \
    --no-legend --no-pager 2>/dev/null \
    | grep -Ei 'clam(av|d)|freshclam' || true)"
emit "unit_files" "$unit_files"

candidate_services="$(
    printf '%s\n' "$unit_files" | awk '{print $1}' \
      | grep -E '\.service$' || true
)"
service_states=""
for unit in $candidate_services; do
    active="$(systemctl is-active "$unit" 2>&1)"
    enabled="$(systemctl is-enabled "$unit" 2>&1)"
    service_states="${service_states}${unit}|active=${active}|enabled=${enabled}"$'\n'
done
emit "service_states" "$service_states"

# Candidate configuration files. Only paths and selected non-secret settings are returned.
config_files=""
for f in /etc/freshclam.conf /etc/clamd.conf /etc/clamd.d/*.conf /etc/clamav/*.conf; do
    [ -f "$f" ] && config_files="${config_files}${f}"$'\n'
done
emit "config_files" "$config_files"

config_settings=""
for f in $config_files; do
    selected="$(
        grep -E '^[[:space:]]*(DatabaseDirectory|LogFile|LocalSocket|TCPSocket|TCPAddr|User|ScanOnAccess)[[:space:]]+' \
            "$f" 2>/dev/null || true
    )"
    [ -n "$selected" ] && config_settings="${config_settings}### ${f}"$'\n'"${selected}"$'\n'
done
emit "config_settings" "$config_settings"

# Signature database discovery. Format: path|mtime_epoch|size_bytes
signature_files="$(
    find /var/lib/clamav /var/lib/clamd /usr/local/share/clamav \
        -maxdepth 2 -type f \( -iname '*.cvd' -o -iname '*.cld' \) \
        -printf '%p|%T@|%s\n' 2>/dev/null || true
)"
emit "signature_files" "$signature_files"

# Extract likely LocalSocket values and test whether sockets exist.
socket_settings="$(
    grep -hE '^[[:space:]]*LocalSocket[[:space:]]+' $config_files 2>/dev/null \
      | awk '{print $2}' || true
)"
socket_checks=""
for socket in $socket_settings; do
    if [ -S "$socket" ]; then
        socket_checks="${socket}|SOCKET_PRESENT"$'\n'
    elif [ -e "$socket" ]; then
        socket_checks="${socket}|EXISTS_NOT_SOCKET"$'\n'
    else
        socket_checks="${socket}|MISSING"$'\n'
    fi
done
emit "socket_checks" "$socket_checks"

# Report listening TCP endpoints owned by clamd if configured or discovered.
emit "clamd_listeners" "$(ss -lntp 2>/dev/null | grep -Ei 'clamd|:3310' || true)"

# Validate configured log paths without changing them.
# Uses configured User when found; otherwise root is used for the access check.
clam_user="$(
    grep -hE '^[[:space:]]*User[[:space:]]+' $config_files 2>/dev/null \
      | awk 'NR==1 {print $2}' || true
)"
[ -z "$clam_user" ] && clam_user="root"

log_paths="$(
    grep -hE '^[[:space:]]*LogFile[[:space:]]+' $config_files 2>/dev/null \
      | awk '{print $2}' || true
)"
log_checks=""
for log_path in $log_paths; do
    if [ -e "$log_path" ]; then
        if runuser -u "$clam_user" -- test -w "$log_path" 2>/dev/null; then
            log_checks="${log_path}|EXISTS_WRITABLE_BY_${clam_user}"$'\n'
        else
            log_checks="${log_path}|EXISTS_NOT_WRITABLE_BY_${clam_user}"$'\n'
        fi
    else
        log_dir="$(dirname "$log_path")"
        if [ -d "$log_dir" ] && runuser -u "$clam_user" -- test -w "$log_dir" 2>/dev/null; then
            log_checks="${log_path}|MISSING_PARENT_WRITABLE_BY_${clam_user}"$'\n'
        else
            log_checks="${log_path}|MISSING_PARENT_NOT_WRITABLE_BY_${clam_user}"$'\n'
        fi
    fi
done
emit "log_checks" "$log_checks"

# Discover systemd timer definitions and candidate scheduled scan commands.
timer_units="$(
    systemctl list-unit-files --type=timer --no-legend --no-pager 2>/dev/null \
      | awk '{print $1}' | grep -Ei 'clam|scan' || true
)"
timer_details=""
for timer in $timer_units; do
    timer_details="${timer_details}### ${timer}"$'\n'
    timer_details="${timer_details}$(systemctl is-enabled "$timer" 2>&1)"$'\n'
    timer_details="${timer_details}$(systemctl is-active "$timer" 2>&1)"$'\n'
    timer_details="${timer_details}$(systemctl cat "$timer" 2>/dev/null || true)"$'\n'
    service="${timer%.timer}.service"
    timer_details="${timer_details}### ${service}"$'\n'
    timer_details="${timer_details}$(systemctl cat "$service" 2>/dev/null || true)"$'\n'
done
emit "timer_details" "$timer_details"

cron_details="$(
    grep -R -i -E 'clam(scan|dscan)|clamav' \
      /etc/crontab /etc/cron.d /etc/cron.daily /etc/cron.weekly \
      /var/spool/cron 2>/dev/null || true
)"
emit "cron_details" "$cron_details"

# Non-malicious functional execution checks against a benign local system file.
if command_exists clamscan; then
    clamscan_output="$(timeout 60 clamscan --no-summary /etc/hosts 2>&1)"
    clamscan_rc=$?
    emit "clamscan_test" "rc=${clamscan_rc}"$'\n'"${clamscan_output}"
else
    emit "clamscan_test" "NOT_INSTALLED"
fi

if command_exists clamdscan; then
    clamdscan_output="$(timeout 60 clamdscan --fdpass --no-summary /etc/hosts 2>&1)"
    clamdscan_rc=$?
    emit "clamdscan_test" "rc=${clamdscan_rc}"$'\n'"${clamdscan_output}"
else
    emit "clamdscan_test" "NOT_INSTALLED"
fi

# Do not run signature updates; this tool assumes manual signature import.
emit "freshclam_execution" "NOT_RUN_AIR_GAPPED_MANUAL_SIGNATURE_PROCESS"
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
    hosts = []
    seen = set()

    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            host = line.strip()
            if not host or host.startswith("#"):
                continue
            if host not in seen:
                hosts.append(host)
                seen.add(host)

    if not hosts:
        raise ValueError("Inventory contains no hosts.")

    return hosts


def decode_remote_output(raw_output):
    """Extract MARKER tab key tab base64-value records from terminal output."""
    result = {}
    clean_output = raw_output.replace("\r", "")

    for line in clean_output.splitlines():
        if not line.startswith(MARKER + "\t"):
            continue

        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue

        _, key, encoded = parts
        try:
            result[key] = base64.b64decode(encoded).decode("utf-8", errors="replace")
        except Exception:
            result[key] = ""

    return result


def ssh_collect(host, username, password):
    """
    Runs SSH through a PTY. Passwords are submitted only after SSH/sudo prompts.
    The remote script is shell-quoted in the command; stdin carries credentials only.
    """
    ssh_binary = shutil.which("ssh")
    if not ssh_binary:
        return {
            "transport_status": "ERROR",
            "error": "OpenSSH client binary 'ssh' was not found in PATH.",
            "raw_output": "",
            "data": {},
        }

    command = [
        ssh_binary,
        "-tt",
        "-o", "BatchMode=no",
        "-o", "StrictHostKeyChecking=yes",
        "-o", f"ConnectTimeout={CONNECT_TIMEOUT_SECONDS}",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "PreferredAuthentications=keyboard-interactive,password",
        "-o", "PubkeyAuthentication=no",
        f"{username}@{host}",
        "sudo -S -p 'CLAMAV_SUDO_PROMPT:' bash -c " + shlex.quote(REMOTE_SCRIPT),
    ]

    master_fd, slave_fd = pty.openpty()

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
            "error": f"Unable to start SSH process: {exc}",
            "raw_output": "",
            "data": {},
        }

    os.close(slave_fd)

    output = bytearray()
    ssh_password_sent = False
    sudo_password_sent = False
    deadline = time.monotonic() + CONNECT_TIMEOUT_SECONDS

    try:
        while True:
            if process.poll() is not None:
                break

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                return {
                    "transport_status": "UNREACHABLE",
                    "error": f"SSH/sudo collection exceeded {CONNECT_TIMEOUT_SECONDS} seconds.",
                    "raw_output": output.decode("utf-8", errors="replace"),
                    "data": {},
                }

            ready, _, _ = select.select([master_fd], [], [], min(1.0, remaining))
            if not ready:
                continue

            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break

            if not chunk:
                break

            output.extend(chunk)
            current_text = output.decode("utf-8", errors="replace").lower()

            # SSH password prompt. Do not send a password until the prompt arrives.
            if (
                not ssh_password_sent
                and "password:" in current_text
                and "clamav_sudo_prompt:" not in current_text
            ):
                os.write(master_fd, (password + "\n").encode("utf-8"))
                ssh_password_sent = True

            # The unique sudo prompt confirms that SSH completed and sudo is requesting input.
            if not sudo_password_sent and "clamav_sudo_prompt:" in current_text:
                os.write(master_fd, (password + "\n").encode("utf-8"))
                sudo_password_sent = True


        process.wait(timeout=5)

    except Exception as exc:
        process.kill()
        return {
            "transport_status": "ERROR",
            "error": f"SSH collection error: {exc}",
            "raw_output": output.decode("utf-8", errors="replace"),
            "data": {},
        }
    finally:
        try:
            os.close(master_fd)
        except OSError:
            pass

    raw_output = output.decode("utf-8", errors="replace")
    data = decode_remote_output(raw_output)

    if data:
        return {
            "transport_status": "SUCCESS",
            "error": None,
            "raw_output": raw_output,
            "data": data,
        }

    lower_output = raw_output.lower()

    if "permission denied" in lower_output:
        error = "SSH authentication or authorization failed."
        status = "UNREACHABLE"
    elif "host key verification failed" in lower_output:
        error = "SSH host key is not trusted or does not match known_hosts."
        status = "UNREACHABLE"
    elif "could not resolve hostname" in lower_output:
        error = "DNS/name resolution failed."
        status = "UNREACHABLE"
    elif "connection refused" in lower_output or "no route to host" in lower_output:
        error = "SSH connection failed."
        status = "UNREACHABLE"
    elif "clamav_sudo_prompt:" in lower_output:
        error = "sudo authentication or privilege escalation failed."
        status = "INSUFFICIENT_PRIVILEGE"
    else:
        error = "No structured response returned from remote target."
        status = "ERROR"

    return {
        "transport_status": status,
        "error": error,
        "raw_output": raw_output,
        "data": {},
    }


def newest_signature_age_days(signature_text):
    """Return newest signature age in days, or None if no valid signature timestamps exist."""
    newest_epoch = None

    for line in signature_text.splitlines():
        parts = line.split("|")
        if len(parts) < 3:
            continue
        try:
            epoch = float(parts[1])
        except ValueError:
            continue
        newest_epoch = epoch if newest_epoch is None else max(newest_epoch, epoch)

    if newest_epoch is None:
        return None

    return round((time.time() - newest_epoch) / 86400, 2)


def contains_active_enabled_daemon(service_states):
    found = False

    for line in service_states.splitlines():
        line_l = line.lower()
        if "clamd" in line_l or "clamav" in line_l:
            found = True
            if "active=active" in line_l and "enabled=enabled" in line_l:
                return True

    return False if found else None


def schedule_indicators(timer_details, cron_details):
    """
    Heuristic discovery check for a daily ClamAV scan and weekly ClamAV full-system scan.
    Evidence is retained in JSON for human validation.
    """
    text = f"{timer_details}\n{cron_details}".lower()

    has_clamav_scan = bool(re.search(r"clam(scan|dscan)|clamav", text))
    daily = has_clamav_scan and bool(
        re.search(r"\bdaily\b|oncalendar=.*\*-\*-\*|^[^\n]*\s0\s+\*\s+\*\s+\*\s+", text, re.MULTILINE)
    )
    weekly = has_clamav_scan and bool(
        re.search(r"\bweekly\b|oncalendar=.*(sun|mon|tue|wed|thu|fri|sat)|^[^\n]*\s0\s+\d+\s+\*\s+\*", text, re.MULTILINE)
    )

    # A full system scan normally has "/" in the scan command. This is only evidence,
    # not a blanket requirement to scan pseudo-filesystems.
    weekly_full_scope = weekly and bool(
        re.search(r"(clam(scan|dscan)[^\n]*\s/\s|clam(scan|dscan)[^\n]*--recursive[^\n]*\s/)", text)
    )

    return {
        "candidate_clamav_schedule_found": has_clamav_scan,
        "daily_candidate_found": daily,
        "weekly_candidate_found": weekly,
        "weekly_full_system_scope_apparent": weekly_full_scope,
    }


def assess(host, collected):
    """Convert collected evidence into a preliminary discovery/assessment record."""
    result = {
        "host": host,
        "assessment_time_utc": utc_now(),
        "overall_status": "ERROR",
        "findings": [],
        "evidence": {},
    }

    if collected["transport_status"] != "SUCCESS":
        result["overall_status"] = collected["transport_status"]
        result["findings"].append({
            "control": "REMOTE_ACCESS",
            "status": collected["transport_status"],
            "detail": collected["error"],
        })
        return result

    data = collected["data"]
    result["evidence"] = data

    os_release = data.get("os_release", "")
    is_rhel9 = bool(
        re.search(r"^ID=\"?rhel\"?", os_release, re.MULTILINE | re.IGNORECASE)
        and re.search(r"^VERSION_ID=\"?9", os_release, re.MULTILINE)
    )

    if not is_rhel9:
        result["overall_status"] = "UNAUTHORIZED_OR_UNSUPPORTED_OS"
        result["findings"].append({
            "control": "OS_VALIDATION",
            "status": "UNAUTHORIZED_OR_UNSUPPORTED_OS",
            "detail": "Target did not identify as RHEL 9 from /etc/os-release.",
        })
        return result

    result["findings"].append({
        "control": "OS_VALIDATION",
        "status": "PASS",
        "detail": "Target identified as RHEL 9.",
    })

    rpms = data.get("clamav_rpms", "").strip()
    clamscan = data.get("binary_clamscan", "").strip()
    clamdscan = data.get("binary_clamdscan", "").strip()
    clamd = data.get("binary_clamd", "").strip()

    if not rpms and not any((clamscan, clamdscan, clamd)):
        result["overall_status"] = "NOT_INSTALLED"
        result["findings"].append({
            "control": "CLAMAV_INSTALLATION",
            "status": "NOT_INSTALLED",
            "detail": "No ClamAV-related RPMs or expected executables were discovered.",
        })
        return result

    failures = []
    partial = []

    if not rpms:
        partial.append("ClamAV executable(s) found, but no matching RPM was discovered.")
    if not clamscan:
        partial.append("clamscan executable was not found.")
    if not clamdscan:
        partial.append("clamdscan executable was not found.")
    if not clamd:
        partial.append("clamd executable was not found.")

    signature_age = newest_signature_age_days(data.get("signature_files", ""))
    if signature_age is None:
        failures.append("No ClamAV signature database (.cvd or .cld) was found.")
    elif signature_age > SIGNATURE_MAX_AGE_DAYS:
        failures.append(
            f"Newest signature database is {signature_age} days old; "
            f"maximum permitted age is {SIGNATURE_MAX_AGE_DAYS} days."
        )

    daemon_state = contains_active_enabled_daemon(data.get("service_states", ""))
    if daemon_state is None:
        partial.append("No candidate ClamAV daemon service unit was discovered.")
    elif daemon_state is False:
        failures.append("No discovered ClamAV daemon service is both active and enabled.")

    socket_checks = data.get("socket_checks", "").strip()
    listeners = data.get("clamd_listeners", "").strip()
    if socket_checks:
        if "SOCKET_PRESENT" not in socket_checks:
            failures.append("Configured LocalSocket is missing or is not a socket.")
    elif not listeners:
        partial.append("No configured LocalSocket or clamd TCP listener was discovered.")

    log_checks = data.get("log_checks", "").strip()
    if not log_checks:
        partial.append("No configured ClamAV LogFile was discovered.")
    elif "NOT_WRITABLE" in log_checks:
        failures.append("At least one configured ClamAV log path is not writable by the service user.")

    clamscan_test = data.get("clamscan_test", "")
    if not clamscan_test.startswith("rc=0"):
        failures.append("clamscan functional scan of /etc/hosts did not complete successfully.")

    clamdscan_test = data.get("clamdscan_test", "")
    if not clamdscan_test.startswith("rc=0"):
        failures.append("clamdscan functional scan of /etc/hosts did not complete successfully.")

    schedule = schedule_indicators(
        data.get("timer_details", ""),
        data.get("cron_details", ""),
    )
    result["evidence"]["schedule_assessment"] = schedule

    if not schedule["daily_candidate_found"]:
        failures.append("No candidate daily ClamAV scan schedule was discovered.")
    if not schedule["weekly_candidate_found"]:
        failures.append("No candidate weekly ClamAV scan schedule was discovered.")
    elif not schedule["weekly_full_system_scope_apparent"]:
        partial.append(
            "A weekly ClamAV schedule was found, but full-system scan scope could not be confirmed."
        )

    result["evidence"]["signature_age_days"] = signature_age
    result["evidence"]["detection_test"] = {
        "status": "NOT_ASSESSED",
        "reason": "No authorized EICAR or equivalent detection test artifact is available.",
    }
    result["evidence"]["freshclam_assessment"] = {
        "status": "INFORMATIONAL",
        "reason": (
            "freshclam was not executed. This assessment assumes an air-gapped "
            "environment using manually imported signature databases."
        ),
    }
    result["evidence"]["package_baseline"] = {
        "status": "DISCOVERED_BASELINE_NOT_DEFINED",
        "reason": (
            "Version 1 inventories installed ClamAV RPMs but does not enforce "
            "a vendor-approved package/version baseline."
        ),
    }

    for item in partial:
        result["findings"].append({
            "control": "CLAMAV_CONFIGURATION",
            "status": "PARTIAL",
            "detail": item,
        })

    for item in failures:
        result["findings"].append({
            "control": "CLAMAV_CONFIGURATION",
            "status": "NONCOMPLIANT",
            "detail": item,
        })

    if failures:
        result["overall_status"] = "NONCOMPLIANT"
    elif partial:
        result["overall_status"] = "PARTIAL"
    else:
        # Discovery-only mode cannot certify a package baseline as compliant.
        result["overall_status"] = "NOT_ASSESSED"
        result["findings"].append({
            "control": "PACKAGE_BASELINE",
            "status": "NOT_ASSESSED",
            "detail": (
                "Operational checks passed, but no approved vendor package/version "
                "baseline has been defined for compliance determination."
            ),
        })

    return result


def collect_with_retry(host, username, password):
    last = None

    for attempt in range(1, RETRIES + 2):
        collected = ssh_collect(host, username, password)
        collected["attempt"] = attempt
        last = collected

        if collected["transport_status"] == "SUCCESS":
            return collected

        if attempt <= RETRIES:
            time.sleep(2)

    return last


def write_report(report):
    REPORT_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(REPORT_DIR, 0o700)

    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=REPORT_DIR,
        prefix=".latest.",
        suffix=".json",
        delete=False,
    ) as handle:
        json.dump(report, handle, indent=2, sort_keys=False)
        handle.write("\n")
        temp_name = handle.name

    os.chmod(temp_name, 0o600)
    os.replace(temp_name, REPORT_FILE)


def main():
    parser = argparse.ArgumentParser(
        description="Read-only ClamAV discovery and preliminary assessment for RHEL 9."
    )
    parser.add_argument(
        "--inventory",
        required=True,
        help="Text file containing one hostname or IP address per line.",
    )
    parser.add_argument(
        "--user",
        required=True,
        help="Shared SSH username. The password is also used for sudo.",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=MAX_WORKERS,
        help=f"Maximum parallel hosts; default {MAX_WORKERS}.",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        print(
            f"ERROR: Run as root or through sudo so the script can write {REPORT_FILE}.",
            file=sys.stderr,
        )
        return 2

    if args.workers < 1 or args.workers > MAX_WORKERS:
        print(f"ERROR: --workers must be between 1 and {MAX_WORKERS}.", file=sys.stderr)
        return 2

    try:
        hosts = read_inventory(args.inventory)
        for host in hosts:
            validate_target(host, args.user)
    except Exception as exc:
        print(f"ERROR: Unable to read inventory: {exc}", file=sys.stderr)
        return 2

    password = getpass.getpass(
        f"SSH/sudo password for {args.user} (used only in memory for this run): "
    )
    if not password:
        print("ERROR: Empty password is not permitted.", file=sys.stderr)
        return 2

    report = {
        "report_type": "clamav_rhel9_discovery_assessment",
        "generated_utc": utc_now(),
        "execution": {
            "inventory": os.path.abspath(args.inventory),
            "requested_hosts": hosts,
            "max_workers": args.workers,
            "connect_timeout_seconds": CONNECT_TIMEOUT_SECONDS,
            "retry_count": RETRIES,
            "signature_max_age_days": SIGNATURE_MAX_AGE_DAYS,
            "remote_actions": "READ_ONLY",
            "internet_access": "NOT_ATTEMPTED",
            "freshclam_execution": "NOT_ATTEMPTED",
        },
        "hosts": [],
        "summary": {},
    }

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        future_map = {
            executor.submit(collect_with_retry, host, args.user, password): host
            for host in hosts
        }

        for future in concurrent.futures.as_completed(future_map):
            host = future_map[future]
            try:
                collected = future.result()
                host_report = assess(host, collected)
                host_report["collection_attempts"] = collected.get("attempt", 1)
            except Exception as exc:
                host_report = {
                    "host": host,
                    "assessment_time_utc": utc_now(),
                    "overall_status": "ERROR",
                    "collection_attempts": None,
                    "findings": [{
                        "control": "ASSESSMENT_EXECUTION",
                        "status": "ERROR",
                        "detail": str(exc),
                    }],
                    "evidence": {},
                }

            report["hosts"].append(host_report)

    report["hosts"].sort(key=lambda item: item["host"])

    status_counts = {}
    for host_result in report["hosts"]:
        status = host_result["overall_status"]
        status_counts[status] = status_counts.get(status, 0) + 1

    report["summary"] = {
        "host_count": len(report["hosts"]),
        "status_counts": status_counts,
        "report_path": str(REPORT_FILE),
    }

    try:
        write_report(report)
    except Exception as exc:
        print(f"ERROR: Could not write report to {REPORT_FILE}: {exc}", file=sys.stderr)
        return 2

    print(f"Report written to: {REPORT_FILE}")
    print(json.dumps(report["summary"]["status_counts"], indent=2))

    # Per requirement: nonzero if any host is not fully assessed/compliant.
    nonzero_statuses = {
        "NONCOMPLIANT",
        "NOT_INSTALLED",
        "PARTIAL",
        "UNREACHABLE",
        "UNAUTHORIZED_OR_UNSUPPORTED_OS",
        "INSUFFICIENT_PRIVILEGE",
        "ERROR",
        "NOT_ASSESSED",
    }

    if any(host["overall_status"] in nonzero_statuses for host in report["hosts"]):
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
