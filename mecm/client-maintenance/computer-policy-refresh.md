# Computer Group Policy refresh

Import **Invoke-MecmComputerPolicyRefresh.ps1** only for an approved computer-policy
change. This refreshes Group Policy, not Configuration Manager client policy.

The fixed system-directory command is:

    gpupdate.exe /target:computer /wait:0

Only changed computer policy is requested. There is no force-reapplication,
user-policy target, boot, logoff or foreground-sync option. Existing policy
processing can still make the changes defined by the approved policy.
[Microsoft gpupdate reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/gpupdate)

A zero exit means the request command completed. With wait zero, policy processing
can continue. Changed and RequestAccepted=true mean request acceptance;
PolicyCompletionVerified remains false. Review Group Policy operational events
and the expected resultant settings. Startup-only extensions may need a separately
authorized restart; this script neither performs nor infers that follow-up.

## Execution and result contract

Use supported 64-bit Windows PowerShell 5.1 under MECM SYSTEM. Import the standalone
script into Run Scripts, retain normal author/approver separation, and choose the
reviewed device or collection. No source edits, framework downloads or prompts are
required. Runtime uses only built-in Windows components.

| Input | Default | Accepted values |
| --- | --- | --- |
| Mode | Preview | Preview, Apply |
| TimeoutSeconds | 60 | Integer 5 through 120 |

Preview executes no native commands. Apply submits the approved request once.
The one JSON record is below 4 KB. Changed reports the narrowly stated command
outcome; Skipped covers Preview, ineligible inputs or an overlapping copy.
Failed covers an unavailable/untrustworthy result, command error or timeout.
Already correct is not emitted because this wrapper does not establish the
target's compliance. NativeExitCode, CommandStarted, CommandCompleted,
MutationAttempted, Phase and OutcomeUncertain preserve partial/unknown outcomes.
RequestAccepted is null when an attempted request has no trustworthy acceptance
result. Exit codes: 0 Changed/Skipped, 1 Failed, 2 timeout.

All native calls share TimeoutSeconds, with up to six additional seconds of
bounded output/termination cleanup when an operation fails. Only the owned native
command is terminated; an operation already handed to Windows can continue.
There are no automatic retries. Inspect evidence before manually repeating.
A per-product mutex excludes overlapping copies of this wrapper, not ordinary
Windows activity or requests from other administrators.

This is a development candidate. GitHub Actions is the primary integration/test
gate; synthetic tests do not establish deployment readiness. An authorized MECM
pilot remains outstanding because no test environment is currently available.
Keep operational outputs and identifiers outside Git.

## Deferred live pilot

Confirm default Preview is inert, Apply refreshes only computer policy, completion
appears in Group Policy events, and resultant settings match the approved change.
Verify no script-requested restart/logoff. Exercise unreachable policy
infrastructure, localized clients and timeout; preserve evidence that processing
can outlive the command. Verify MECM parameter/output/exit handling.

Run **mecm/tests/check-computer-policy-refresh.ps1** in its own PowerShell process. It substitutes
all native calls in real script control-flow tests, then exercises the production
process helper with synthetic owned PowerShell children for deadline, exit-code
and output-limit checks. No operational policy, DNS or time provider is executed.

