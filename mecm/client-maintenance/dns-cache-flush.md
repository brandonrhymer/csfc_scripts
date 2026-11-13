# Local DNS client cache flush

Import **Invoke-MecmDnsCacheFlush.ps1** for approved targets with a stale local
resolver-cache problem. The only system-directory command is:

    ipconfig.exe /flushdns

This resets the local DNS client resolver cache, including dynamically cached
negative answers. It preserves IP addresses, DHCP leases, resolvers, suffixes,
routes, hosts files and service configuration. It performs no release/renew,
registration, network reset, adapter restart or upstream DNS change.
[Microsoft ipconfig reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ipconfig)

Changed means the local flush command completed with exit zero. Entries can
repopulate immediately. UpstreamRecoveryVerified remains false. Test the original
application lookup separately; if it still fails, investigate the configured
resolver and authoritative DNS path. A successful flush is not DNS recovery.

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

Verify Preview does not flush and Apply removes a synthetic cached negative or
dynamic entry. Confirm normal resolution repopulates the cache and network/resolver
configuration stays unchanged. Test unavailable-command/service handling,
localized output and timeout. A failed upstream lookup must remain unresolved
despite a successful local flush. Verify MECM parameter/output/exit handling.

Run **mecm/tests/check-dns-cache-flush.ps1** in its own PowerShell process. It substitutes
all native calls in real script control-flow tests, then exercises the production
process helper with synthetic owned PowerShell children for deadline, exit-code
and output-limit checks. No operational policy, DNS or time provider is executed.
