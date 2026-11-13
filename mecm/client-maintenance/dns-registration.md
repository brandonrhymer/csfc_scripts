# Client-owned DNS registration request

Import **Invoke-MecmDnsRegistration.ps1** only for clients whose registration
ownership and all-adapter scope are reviewed.

| Additional input | Default | Accepted values |
| --- | --- | --- |
| RegistrationOwnership | Unknown | Unknown, Client, Dhcp, Other |
| AllAdaptersApproved | No | No, Yes |

Client is an operator assertion backed by approved network/DNS policy for every
affected interface and record type, not an automatic discovery result. Unknown,
Dhcp and Other skip. Use Other for mixed ownership. DHCP-enabled addressing alone
proves neither client nor DHCP ownership. Review DHCP option 81/server policy and
record ownership, including the A/AAAA/PTR division. Mixed client-forward and
DHCP-reverse ownership needs a different scoped remediation.
[Microsoft DHCP/DNS interaction](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/configure-dns-dynamic-updates-windows-server-2003)

AllAdaptersApproved=Yes confirms existing registration settings and all eligible
interfaces, including VPN, virtual and additional adapters. The request is global,
not per-interface; no adapter selector is offered.
[Microsoft global registration scope](https://learn.microsoft.com/en-us/powershell/module/dnsclient/register-dnsclient?view=windowsserver2025-ps)

After both facts are confirmed, Apply runs this system-directory command once:

    ipconfig.exe /registerdns

It initiates registration for names/addresses selected by existing DNS settings.
It preserves adapter addresses, leases, resolvers, suffixes, registration flags,
services, zone permissions and DHCP settings. It does not repair ownership or
change ACLs, and is not a Netlogon domain-controller SRV-record repair.
[Microsoft ipconfig reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ipconfig)

Changed and RequestAccepted=true mean the command returned zero.
RegistrationVerified remains false: request acceptance does not prove
authoritative records were written or replicated. Review DNS Client events and
authoritative A/AAAA/PTR records, intended addresses, timestamps and ownership.
Check replication separately. A local cached answer is not proof of authoritative
registration.

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

Verify Unknown, Dhcp, Other and missing all-adapter approval skip. Test client-owned
static and DHCP-addressed configurations with documented ownership, multiple
interfaces and disabled registration flags. Confirm existing configuration stays
unchanged and only records allowed by existing settings are registered. Test
inaccessible DNS, ownership denial, delayed updates, localized output and timeout;
verify authoritative results independently. Check Preview and MECM parameter/output/exit
handling before collection expansion.

Run **mecm/tests/check-dns-registration.ps1** in its own PowerShell process. It substitutes
all native calls in real script control-flow tests, then exercises the production
process helper with synthetic owned PowerShell children for deadline, exit-code
and output-limit checks. No operational policy, DNS or time provider is executed.

