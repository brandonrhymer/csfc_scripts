"""Strict, standard-library-only runtime policy shared by both account tools."""
import hashlib
import json
import re
import shlex
from pathlib import Path


FIELDS = {
    "schema_version", "account", "group", "uid", "gid", "home", "home_mode",
    "shell", "comment", "privileged_group", "password_max_days",
    "password_min_days", "password_warn_days", "password_inactive_days",
    "faillock_deny", "faillock_unlock_time_seconds",
}
SHELL_FIELDS = {
    "ACCOUNT": "account", "GROUP": "group", "TARGET_UID": "uid",
    "TARGET_GID": "gid", "TARGET_HOME": "home", "HOME_MODE": "home_mode",
    "TARGET_SHELL": "shell", "TARGET_COMMENT": "comment",
    "PRIVILEGED_GROUP": "privileged_group", "PASS_MAX_DAYS": "password_max_days",
    "PASS_MIN_DAYS": "password_min_days", "PASS_WARN_DAYS": "password_warn_days",
    "PASS_INACTIVE_DAYS": "password_inactive_days", "FAILLOCK_DENY": "faillock_deny",
    "FAILLOCK_UNLOCK_SECONDS": "faillock_unlock_time_seconds",
}


def validate_policy(value):
    """Reject unknown/missing keys, coercions and unsafe target identities/paths."""
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise ValueError("Policy must contain exactly the documented fields; missing/unknown fields are refused.")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError("Policy schema_version must be integer 1.")
    for field in ("account", "group", "privileged_group"):
        item = value[field]
        if not isinstance(item, str) or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", item):
            raise ValueError(f"Policy {field} must be a lowercase Linux identity of 1-31 characters.")
        if item in {"root", "nobody", "nfsnobody"}:
            raise ValueError(f"Policy {field} cannot select a protected identity.")
    if value["group"] == value["privileged_group"]:
        raise ValueError("The private primary group must differ from the privileged supplementary group.")
    ranges = {
        "uid": (1000, 2147483647), "gid": (1000, 2147483647),
        "password_max_days": (1, 99999), "password_min_days": (0, 99999),
        "password_warn_days": (0, 99999), "password_inactive_days": (0, 99999),
        "faillock_deny": (1, 100), "faillock_unlock_time_seconds": (1, 604800),
    }
    for field, (minimum, maximum) in ranges.items():
        item = value[field]
        if type(item) is not int or not minimum <= item <= maximum:
            raise ValueError(f"Policy {field} must be an integer in {minimum}..{maximum}.")
    if value["uid"] == 65534 or value["gid"] == 65534:
        raise ValueError("UID/GID 65534 is reserved and cannot be a policy target.")
    if any(value[field] > value["password_max_days"] for field in ("password_min_days", "password_warn_days")):
        raise ValueError("Password minimum/warning days cannot exceed maximum days.")
    # Do not turn chmod/chown of a policy path into a system-directory operation.
    if not isinstance(value["home"], str) or not re.fullmatch(r"/(?:home|srv)/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+", value["home"]):
        raise ValueError("Policy home must be a canonical child path under /home or /srv, without dots or shell characters.")
    if value["home_mode"] not in ("0700", "0750"):
        raise ValueError("Policy home_mode must be the string 0700 or 0750.")
    if value["shell"] not in ("/bin/bash", "/bin/sh", "/usr/bin/bash", "/usr/bin/sh"):
        raise ValueError("Policy shell must be an approved bash/sh absolute path listed in the runbook.")
    comment = value["comment"]
    if not isinstance(comment, str) or not 1 <= len(comment) <= 128 or any(ord(char) < 32 or ord(char) > 126 or char == ":" for char in comment):
        raise ValueError("Policy comment must be 1-128 printable ASCII characters without colons.")
    return {field: value[field] for field in sorted(FIELDS)}


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("Duplicate JSON policy fields are refused.")
        value[key] = item
    return value


def _invalid_constant(_value):
    raise ValueError("Non-finite JSON numbers are refused.")


def load_policy(filename):
    with Path(filename).open("r", encoding="utf-8") as handle:
        # A bounded text read avoids consuming an accidentally selected inventory/archive.
        text = handle.read(16385)
    if len(text) > 16384:
        raise ValueError("Policy file exceeds 16 KiB.")
    return validate_policy(json.loads(text, object_pairs_hook=_unique_object, parse_constant=_invalid_constant))


def policy_digest(policy):
    canonical = json.dumps(validate_policy(policy), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def shell_assignments(policy):
    validated = validate_policy(policy)
    return "\n".join(f"{name}={shlex.quote(str(validated[field]))}" for name, field in SHELL_FIELDS.items())


def policy_summary(policy):
    """The same complete policy is displayed before either tool contacts targets."""
    return "Selected runtime policy (SHA-256 " + policy_digest(policy) + "):\n" + json.dumps(validate_policy(policy), indent=2)
