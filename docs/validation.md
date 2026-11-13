# Administration script validation

**Full runtime and lab validation are incomplete.** Source review and isolated
parser/helper checks do not establish deployment readiness. The commands on
this page describe available checks; they do not authorize execution against
operational systems.

This page covers the Linux account/ClamAV tools and the Windows Defender,
Nessus, and Splunk utilities. See the separate [MECM validation requirements](../mecm/docs/validation.md)
and [text-sanitizer tests](../obfuscation/README.md#tests) for those tools. KRBTGT
has its own [release and validation record](../windows/reset-krbtgt/docs/verification.md),
including an unresolved Test-flow report that repository integration does not resolve.

## Package check matrix

Run commands from the repository root in a suitable development environment.
Use a fresh PowerShell process for each MECM test. These are isolated checks;
the operational entry points and live lab checks require a separate plan.

| Package | Shell and command | What the check establishes |
| --- | --- | --- |
| Linux account/ClamAV | Linux Python 3 plus Bash: `python3 -B -m unittest discover -s tests -p 'test_*.py'` | Discovers all `test_*.py` suites, including syntax, embedded Bash, helpers, synthetic inventories and mocked transport outcomes |
| Windows utilities | Windows PowerShell 5.1: `powershell.exe -NoProfile -File tests/check-admin-tools.ps1` | Windows `.ps1` syntax and isolated Defender helpers; does not cover the KRBTGT module or all deployment behavior |
| MECM | Windows PowerShell 5.1: `powershell.exe -NoProfile -File mecm/tests/check-syntax.ps1` | Operational script syntax |
| MECM collections | Windows PowerShell 5.1: `powershell.exe -NoProfile -File mecm/tests/check-collections.ps1` | Synthetic collection control flow with fake commands |
| MECM application lookup | Windows PowerShell 5.1: `powershell.exe -NoProfile -File mecm/tests/check-application-duplicates.ps1` | Isolated duplicate guard; no MSI COM or provider interaction |
| Text sanitizer | PowerShell 7.4+: `pwsh -NoProfile -File obfuscation/tests/obfuscatefile.Tests.ps1` | Synthetic text/XML, encoding, path and failure regressions; Unix permission assertions run only on Unix |
| KRBTGT package | Windows PowerShell 5.1, Pester 3.4.0 and PSScriptAnalyzer 1.25.0: `powershell.exe -NoProfile -File windows/reset-krbtgt/tools/Invoke-ReleaseVerification.ps1` | Committed manifest/hashes, syntax including module/data files, configured analyzer rules, JSON parsing and mocked behavior; no AD integration |

The [GitHub workflow](github-workflow.md#automated-checks) runs these suites on
hosted development runners. A result applies to the tested revision and runner;
it does not supersede the lab requirements below or the KRBTGT known issue.

## Available checks and evidence limits

Earlier limited validation reported twelve Python tests, including embedded
Bash parsing, plus PowerShell parsing and isolated Defender helper checks using
PowerShell 7.4.6 on Linux. Those results predate subsequent safety changes and
do not validate the current revision. Windows PowerShell 5.1 and live-system
checks have not been performed.

The Python checks cover syntax, embedded Bash syntax, isolated emitter/decoder
and assessment behavior, and synthetic inventories:

```sh
python3 -B -m unittest discover -s tests -p 'test_*.py'
```

The PowerShell checks cover parsing and isolated Defender helper behavior:

```powershell
pwsh -NoProfile -File tests/check-admin-tools.ps1
```

These tests do not contact targets, install packages, change accounts, or run
the deployment scripts' main bodies. They are not a complete Defender deployment
test suite. A fixture's presence is not evidence that it passed on the current
revision.

## Safety behavior requiring validation

The source includes the following safeguards. They still require validation in
the intended environment; source inspection is not runtime evidence.

- SSH uses util-linux `setsid` to give each process its own controlling terminal.
  Remote scripts are quoted command arguments rather than credential-input data.
  Discovery requires completion evidence and a successful SSH exit, and drains
  terminal output after process exit.
- Linux account tools match the RHEL major version exactly and validate inventory
  values. Remediation rejects repeated targets and has no automatic apply retry.
- Remediation refuses unsafe/shared/protected source identities, unsafe home
  paths, existing groups with different GIDs, and foreign, unexplained, or shared
  homes. A different existing home path requires manual reconciliation.
- Ownership migration preserves file groups and reports failures. Account-unlock
  failures do not count as success. Reports are saved before the first target and
  after each result; an interrupted active host still needs manual reconciliation.
- ClamAV retains every socket/log result and checks every configured socket.
  Configuration queries use quoted arrays and an explicit empty input file.
- Nessus downloads refuse redirects, protect existing output, and suppress
  request errors that may contain private URL tokens. Downloading does not import
  or activate plugins.
- Splunk wrappers act locally, support preview/confirmation, and inspect MSI exit
  codes. Removal requires 64-bit PowerShell on 64-bit Windows.

Regression fixtures cover empty ClamAV configuration lists with stdin held open,
filenames containing spaces, partial or unknown remediation results, nonzero SSH
exits, and failing process exit codes without automatic apply retries. The SSH
exit fixture supplies EOF after its result rather than repeating the same bytes.
The latest safety changes and that fixture correction have not been executed in
the test suite. Remediation requires its expected terminal result plus a
successful SSH exit; otherwise completion is unverified or failed.

## Required lab validation

Use an approved, limited lab plan before operational use. The following remain
unverified:

- Linux SSH/sudo prompt handling and actual RHEL account changes.
- ClamAV collection, configuration parsing, socket/log checks, and scanner behavior.
- Windows PowerShell 5.1 compatibility, WinRM/Kerberos, ACLs, and Authenticode trust.
- Nessus archive downloads and the separate verification/transfer/import procedure.
- Splunk MSI installation/removal, service health, and forwarding verification.
- Defender package staging, installation, interruption recovery, and version checks.

Record the tested revision, platform versions, inputs, expected results, observed
results, and unresolved outcomes privately. Do not infer deployment readiness
from parser/helper checks or a successful process exit alone.

## Private inputs and evidence

Account names, UID/GID values, and hosts in examples are illustrative, not an
organization-approved baseline. Supply deployment-specific values privately.
Keep credentials, actual addresses, download tokens, packages, inventories, and
runtime reports outside Git. Review source changes for embedded private values
before publishing. Content review is not a classification determination.
