# Start here: administration scripts

This page explains how to choose and prepare a script. It does not authorize a
change to a system, establish compliance, or replace your approved procedures.

**Current phase: code review. Testing and lab validation remain deferred.**
Source review does not establish runtime behavior. Do not treat an example command
or an earlier syntax check as approval to use a script on an operational system.

## 1. Choose the smallest tool for the job

| Need | Start with | What it does |
| --- | --- | --- |
| Inspect ClamAV on RHEL 9 | [ClamAV runbook](../linux/clamav/README.md) | Collects preliminary evidence and runs benign scanner checks. |
| Inspect an illustrative local administrator account | [Local-account runbook](../linux/local-accounts/README.md) | Collects account and policy evidence before remediation is considered. |
| Create or normalize the illustrative account | [Local-account runbook](../linux/local-accounts/README.md) | Defaults to preflight; `--apply` changes accounts. |
| Stage an offline Defender update | [Defender runbook](../windows/defender/README.md) | Copies a supplied package, executes it on approved targets, and records evidence. |
| Download a Nessus plugin archive | [Nessus runbook](../windows/nessus/README.md) | Downloads a file only. It does not import or activate plugins. |
| Install or remove a local Splunk Forwarder | [Splunk runbook](../windows/splunk/README.md) | Runs one local MSI operation. It does not deploy to a remote inventory. |
| Prepare Configuration Manager work | [MECM toolkit](../mecm/README.md) | Follow that toolkit's separate requirements and runbooks. |
| Sanitize text before sharing | [Repository README](../README.md#text-sanitization) | Describes the separate PowerShell text-sanitization utility and its limits. |

Do not run every script as a bundle. Each has different requirements and effects.

## 2. Keep the repository separate from operational material

The tracked repository contains source code, synthetic examples, and instructions.
Keep the following in a separate access-controlled working location:

- Actual hostnames, addresses, domains, account names, and inventories.
- Passwords, activation links, tokens, certificate private keys, and other secrets.
- Installers, signature packages, plugin archives, and package-approval records.
- Reports, logs, screenshots, and other evidence collected from real systems.

A `.gitignore` entry is a convenience, not a privacy guarantee. It does not remove
an already tracked file and does not protect files with another name. Do not
stage your entire working directory when saving a source-code change.

`host1.example.invalid`, `example_operator`, and `example_admin` are examples.
They are not an actual inventory or an organization-approved account baseline.
Replace runtime values only in your private working location. If your approved
baseline requires editing a script, keep that deployment-specific copy private.

## 3. Read the selected runbook before preparing inputs

For the chosen script, identify:

1. The computer where the script runs, and whether it acts locally or remotely.
2. The required shell/version, permissions, and already-configured dependencies.
3. The exact input format and where the output will be written.
4. The commands that only inspect or preview and the commands that make changes.
5. What can remain partially completed after interruption, and who approves retry.

Linux account remediation's default dry-run still connects to targets, uses
sudo, and writes a local report. It is not an entirely offline check.
Defender's `-WhatIf` does not connect to targets. The smaller Windows utilities'
`-WhatIf` behavior is described in their own runbooks.

## 4. Understand evidence and completion

A process exit code describes what that utility observed. It does not certify a
system's security posture or prove every external effect completed.

- A timeout or interrupted connection can leave a remote operation unresolved.
- Do not rerun a mutating command just because the console stopped responding.
- Read the recorded result and failed stage before planning another action.
- Keep evidence private. The collection scripts do not sanitize their reports.
- Do not paste full reports or inventories into GitHub issues or pull requests.

The [preparation record](attachment-validation.md) distinguishes prior limited
checks from current source review and later testing. Testing remains deferred.

## 5. Keep future repository updates organized

Put script-specific instructions beside the script they explain. Update the
relevant `README.md` when parameters, behavior, prerequisites, or output changes.
Keep shared navigation here and in the platform indexes. Broad platform or
administration references belong in the separate guides repository; do not copy
operational inventories into either repository.
