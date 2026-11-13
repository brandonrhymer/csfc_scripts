# MECM client maintenance candidates

These eleven standalone Windows PowerShell 5.1 scripts run on an individual
Configuration Manager client. MECM Run Scripts supplies approved parameters to
collection members. They require no Internet downloads, console module,
interactive menu, or source edits on the client. Policy, DNS and time requests
can contact the client's existing domain, DNS and time infrastructure.

**Development candidates: an approved real-client pilot remains required.**
GitHub Actions is the primary integration and test gate; local checks support
development. There is no MECM test environment yet.
Mocked tests establish control flow and failure handling; they do not establish
that a particular client version exposes the expected interfaces or that an
operational collection is safe to target.

| Product | Runbook | Purpose |
|---|---|---|
| `mecm-cache-cleanup` | [Cache cleanup](cache-cleanup.md) | Preview eligible old content and remove it through the client cache interface |
| `mecm-ccmeval` | [CcmEval](ccmeval.md) | Request the existing client health evaluation task when overdue |
| `mecm-service-start` | [Service start](service-start.md) | Start an approved stopped application service |
| `mecm-computer-policy-refresh` | [Computer policy](computer-policy-refresh.md) | Request computer Group Policy refresh without forced reboot or logoff |
| `mecm-dns-cache-flush` | [DNS cache](dns-cache-flush.md) | Clear the local resolver cache |
| `mecm-time-sync` | [Time synchronization](time-sync.md) | Request synchronization from the configured time source |
| `mecm-dns-registration` | [DNS registration](dns-registration.md) | Request registration only with approved client ownership and adapter scope |
| `mecm-agent-restart` | [Agent restart](agent-restart.md) | Restart one approved application agent without dependent-service cascades |
| `mecm-task-enable` | [Task enablement](task-enable.md) | Enable one approved existing disabled task without a direct run request |
| `mecm-staging-cleanup` | [Staging cleanup](staging-cleanup.md) | Remove expired disposable application staging files |
| `mecm-config-restore` | [Configuration restore](config-restore.md) | Back up and restore an approved narrow application configuration |

Each product has its own version and ZIP. A selected bundle can contain several;
bundles have a separate release cadence. Verify the downloaded package and its
hashes before importing the script. Review the product runbook and the
[pilot checklist](pilot-checklist.md) before executing even a preview.

All scripts default to `Mode=Preview`. Apply is a separate, explicit selection.
Their integer and string parameters suit MECM Run Scripts; do not edit the source
to set an environment-specific policy. Run Scripts executes under the computer
account. Use the normal script author, approver and runner roles.

The five application-specific products require validated local policies pinned
by independently approved hashes. Read [application policy approval](policies.md).
Included examples are synthetic; actual service/task/path/configuration approval
remains outstanding.

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
