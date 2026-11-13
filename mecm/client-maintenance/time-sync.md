# Configured-source Windows time resync

Import **Invoke-MecmTimeSync.ps1** for an approved change: resynchronization may
adjust the computer clock and affect time-sensitive work. Apply runs this fixed
local sequence through the system-directory w32tm.exe:

1. Capture /query /status /verbose; stop without resync if evidence is unavailable.
2. Submit /resync /nowait once.
3. Capture /query /status /verbose again after request acceptance.

No server or peer name is accepted. Existing source, domain hierarchy, providers
and service configuration are preserved. The script does not start/restart
W32Time, set the clock directly, rediscover sources, register the service, or
submit configuration changes. Windows may select a source or adjust the clock
according to its existing configuration.
[Microsoft Windows Time tools reference](https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings)

BeforeStatus and AfterStatus retain localized native text, collapsed to one line
and capped at 700 UTF-8 bytes each. EvidenceTruncated identifies shortening.
UTC capture timestamps use the local clock and can move during correction;
ElapsedMilliseconds uses a monotonic stopwatch.

Changed and RequestAccepted=true mean the resync command returned zero. The nowait
option does not wait for synchronization. SyncVerified is always false: this
script does not parse localized labels, infer synchronization from exit zero or
treat unchanged status as a new successful sync. After a suitable convergence
interval, review last successful sync time, source, last sync error and Windows
Time events against the expected source and approved accuracy requirement.
Capture full status separately when evidence is truncated.

A failed before-query makes no resync request. A failed after-query reports Failed
while preserving RequestAccepted=true and uncertainty. If the shared deadline is
exhausted, no subsequent native command starts. Inspect before another request;
repeated resyncs can discard accumulated timing statistics.

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

Compare full source/service configuration before and after Apply. Validate
domain-hierarchy and already configured manual-source clients without supplying
new sources. Test stopped W32Time, unreachable sources, failed requests, missing
after-status evidence, localized output and timeout. Demonstrate that request
acceptance can precede actual synchronization, then verify synchronization
independently. Check default Preview and MECM parameter/output/exit handling.

Run **mecm/tests/check-time-sync.ps1** in its own PowerShell process. It substitutes
all native calls in real script control-flow tests, then exercises the production
process helper with synthetic owned PowerShell children for deadline, exit-code
and output-limit checks. No operational policy, DNS or time provider is executed.
