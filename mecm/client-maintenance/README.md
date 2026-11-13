# MECM client maintenance candidates

These two standalone Windows PowerShell 5.1 scripts run on an individual
Configuration Manager client. MECM Run Scripts supplies approved parameters to
collection members. They require no network access, downloads, console module,
interactive menu, or source edits on the client.

**Local candidates only: an approved real-client pilot remains required.**
Mocked tests establish control flow and failure handling; they do not establish
that a particular client version exposes the expected interfaces or that an
operational collection is safe to target.

| Product | Runbook | Purpose |
|---|---|---|
| `mecm-cache-cleanup` | [Cache cleanup](cache-cleanup.md) | Preview eligible old content and remove it through the client cache interface |
| `mecm-ccmeval` | [CcmEval](ccmeval.md) | Request the existing client health evaluation task when overdue |

Each product has its own version and ZIP. A selected bundle can contain both;
bundles have a separate release cadence. Verify the downloaded package and its
hashes before importing the script. Review the product runbook and the
[pilot checklist](pilot-checklist.md) before executing even a preview.

Both scripts default to `Mode=Preview`. Apply is a separate, explicit selection.
Their integer and string parameters suit MECM Run Scripts; do not edit the source
to set an environment-specific policy. Run Scripts executes under the computer
account. Use the normal script author, approver and runner roles.

The result contains one of `Changed`, `Already correct`, `Skipped`, or `Failed`
and a reason. Read the reason and counters: a successful invocation is not proof
of healthy deployments, actual disk space reclaimed, or successful CcmEval
remediation. Timeout or partial failure requires inspection before a retry.

Runtime output is deliberately compact because MECM truncates script output at
4 KB. Keep actual device identities, logs and pilot evidence in an approved
private location; examples in this directory are synthetic.

## Sources

- [Microsoft: create and run scripts](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-deploy-scripts)
- [Microsoft: configure the client cache](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/manage/configure-client-cache)
- [Microsoft: client health checks](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/manage/client-health-checks)
