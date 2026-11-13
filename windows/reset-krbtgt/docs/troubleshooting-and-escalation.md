# Troubleshooting and escalation

## Universal response to failure

1. Stop the current sequence.
2. Do not retry a production reset or continue to Reset 2.
3. Do not attempt to restore a prior `krbtgt` password; the prior key is not
   available as an ordinary rollback value.
4. Do not delete, edit, compress, or move the local JSON receipt or System events.
5. Record the UTC time, selected DC, phase, operation ID, invocation ID, console
   error, and manual client symptoms in the approved external change record.
6. Escalate to the responsible AD authority using its approved incident/recovery
   procedure. This routine-rotation tool does not diagnose compromise or perform
   forest recovery.

Successful prior production use and passing mocked tests do not make a current
failure safe to override.

## Common Preflight blocks

| Message or condition | Meaning | Safe next action |
|---|---|---|
| Windows PowerShell 5.1/elevation failure | Wrong host runtime or token | Close it and manually start approved elevated Windows PowerShell 5.1. Never self-elevate the script. |
| Current identity is not Domain Admin | Current token lacks current-domain RID 512 group SID | Sign out and follow the approved privileged-login process. Do not supply alternate credentials. |
| Event source or receipt directory missing/wrong | One-time local setup is absent or ACL drifted | Stop. Review installation and local security policy; run setup only with AD authority approval. |
| DC count is not exactly two, an RODC exists, or OS is not Server 2022 | Environment no longer matches the approved profile | Stop. Do not exclude or skip a DC. Reassess architecture. |
| `LsaOpenPolicy` or `LsaQueryDomainInformationPolicy` fails | Effective KDC policy could not be read from a DC, commonly because access or RPC policy blocks the read | Preserve the exact Win32 error and escalate to AD/security owners. Do not substitute a default value. |
| `MaxTicketAge` is not 10 hours or policy differs | The fixed wait assumption is invalid | Stop. Correct policy only through the separate approved GPO process, never through this tool. |
| DNS/SRV, `dcdiag`, replication, or time check fails/unparseable | Health cannot be proven | Preserve exact output and escalate to AD/DNS/time owners. Do not use a warning as success. |
| `dcdiag` success marker is unparseable | Output/localization differs from the verified parser | Stop. This release expects the documented English success markers; do not edit the parser at change time. |
| RID 502/SID/GUID/DN/disabled state differs | The exact built-in target cannot be proven | Stop immediately and escalate. Never target by name alone. |

## Test failures

Test creates a unique disabled `KRT-<hex>` user. If creation, password reset,
replication, metadata verification, deletion, tombstone replication, or cleanup
verification fails, the Test receipt fails and later reset gates reject it.

The tool intentionally stops immediately and does not attempt ad hoc cleanup
after an earlier Test anomaly. A disabled temporary user might remain. Give the
AD authority the receipt's name/GUID and let it approve a separate manual
investigation and cleanup. Never rename it to resemble `krbtgt`, enable it, or
rerun Test merely to hide the first failure.

## Production anomalies

The following all make the phase failed:

- `Set-ADAccountPassword` throws or returns a terminating error;
- source `pwdLastSet` replication metadata does not advance exactly one version;
- originating invocation/USN/time evidence is incomplete or unexpected;
- targeted `Sync-ADObject` fails;
- both DCs do not match the exact expected metadata within five minutes;
- any post-check fails or observes a different metadata change;
- required JSON receipt or System event cannot be completed.

After `DirectoryMutationAttempted=true`, assume the password might have changed
even when the command reported an error. Do not infer unchanged state from a
console exception. The AD authority must inspect both DCs, replication metadata,
events, authentication behavior, and recovery status.

Reset 2 additionally fails closed for:

- an explicit Reset 1 receipt outside the protected local directory;
- the wrong domain, DC, SID, GUID, policy, or receipt status;
- less than 11 elapsed hours or a future timestamp;
- an unresolved Reset 1 mutation anomaly in the current cycle;
- an intervening production mutation after the selected Reset 1 receipt.

There is no override switch. Do not edit a receipt to satisfy the gate.

## Evidence locations

```text
JSON:   %ProgramData%\KrbtgtRotation\Receipts\*.json
Events: classic System log, source KrbtgtRotation
Schema: schemas\receipt.schema.json and schemas\event.schema.json
IDs:    schemas\event-catalog.json
```

Use read-only tools to inspect evidence. If enclave procedure requires transfer,
copy it through the approved classified-media process while preserving the
original local files and recording hashes. The product never sends or packages
evidence.
