# Attachment preparation record

**Current phase: code review. Testing and lab validation remain deferred at
user direction.** This page retains the history of earlier limited checks.
Source review is not execution evidence. Do not begin the later test phase from
these instructions alone.

## Focused review corrections

- SSH uses util-linux `setsid` to give each process its own controlling PTY.
- Remediation refuses an existing group with a different GID and refuses foreign,
  unexplained, or shared existing homes rather than trying to repair them.
- Remediation saves its report before the first target and after each result.
  An interrupted active host still needs manual reconciliation.
- ClamAV retains every socket/log result and checks every configured socket.
- Nessus downloads refuse redirects and suppress request errors that may contain
  private URL tokens. Splunk removal requires 64-bit PowerShell on 64-bit Windows.
- The existing SSH-exit test fixture now supplies EOF after its result instead
  of returning the same bytes indefinitely. It has not been run in this phase.

No test commands, deployment scripts, installers, or live targets were executed
for these corrections. The changes remain subject to source review and later
authorized testing; no new framework or automated migration system was added.

## Content-only completion update

The repository now has an operator start guide, platform indexes, expanded
script-specific runbooks, and clearer descriptions of private inputs, preview
scope, side effects, outputs, interruption handling, and recovery limits.

Previously prepared Linux safety corrections are included: discovery requires
completion evidence and a successful SSH exit, terminal output is drained after
process exit, RHEL major-version matching is exact, and repeated remediation
targets are rejected. Ownership migration preserves file groups and reports
failure. Remediation refuses unsafe/shared/protected source identities and
unsafe home paths; an existing different home path requires manual reconciliation.
Account-unlock failures no longer count as success.

That earlier content update did not run validation or add test files. The current
source-review corrections are listed separately above; testing remains deferred.

## Imported sources

Seven scripts and one Defender guide were imported from complete original
attachment text reads. Source identities and full line coverage were verified.
Returned text sizes differed from uploaded byte counts, consistent with newline
normalization; raw-byte identity was not verified. No prior/reconstructed script
version was substituted. Sanitized versions are the repository deliverables.

| Supplied file | Repository path |
| --- | --- |
| clamav_rhel9_discovery.py | linux/clamav/clamav_rhel9_discovery.py |
| local_admin_discovery.py | linux/local-accounts/local_admin_discovery.py |
| local_admin_remediation.py | linux/local-accounts/local_admin_remediation.py |
| Invoke-CSfCDefenderUpdate-MVP.ps1 | windows/defender/Invoke-CSfCDefenderUpdate-MVP.ps1 |
| README attachment | windows/defender/README.md |
| update-acas-plugin.ps1 | windows/nessus/download-plugins.ps1 |
| uninstall.ps1 | windows/splunk/uninstall-forwarder.ps1 |
| exec.ps1 | windows/splunk/install-forwarder.ps1 |

## Sanitization and focused corrections

- Removed embedded deployment addresses and download domain; inputs are supplied
  at runtime. Public documentation URLs were also removed from the imported guide.
- Replaced account identity/UID/GID values with a clearly labeled illustrative
  baseline in both Linux account scripts. Host examples use reserved names.
- Corrected the account discovery shell emitter and UID-zero query.
- Passed remote shell scripts as quoted command arguments so credential input
  cannot consume script source. Added inventory-value validation and removed
  automatic retries for mutating account runs.
- The plugin script downloads only, protects existing output, and fails on errors.
- The Splunk installer runs once locally and accepts explicit package/endpoints;
  the original computer loop never used its target. Installer and uninstaller
  support preview/confirmation and inspect MSI exit codes.
- Removed references implying that absent Defender companion tests were included.

## Historical limited checks

The earlier preparation record reported twelve Python tests (including embedded
Bash parsing), PowerShell parsing and isolated Defender helper checks with
PowerShell 7.4.6 on Linux, and staged-content privacy/documentation review.
Windows PowerShell 5.1 and live-system checks have not been performed.

Follow-up review fixes are covered by regressions for empty ClamAV configuration
lists with stdin held open, configuration filenames containing spaces, partial or
unknown remediation results, nonzero SSH exits, and failing process exit codes
without automatic apply retries. ClamAV config queries use quoted arrays and an
explicit empty input file. Remediation requires its expected terminal result plus
a successful SSH exit; otherwise completion is unverified or failed.

For the later authorized phase, the existing command is
`python3 tests/test_admin_tools.py` for Python syntax, embedded Bash syntax,
isolated emitter/decoder and assessment checks, and synthetic inventory checks.
The existing PowerShell command is
`pwsh -NoProfile -File tests/check-admin-tools.ps1` for PowerShell parsing and
isolated Defender helper checks. These tests do not contact targets, install
packages, change accounts, or run the deployment scripts' main bodies.

## Deferred full test and lab validation

Linux SSH/sudo prompt handling, actual RHEL account changes, ClamAV collection,
Windows PowerShell 5.1 compatibility, WinRM/Kerberos, ACLs, Authenticode trust,
downloads, MSI installation/removal, and Defender updates require approved lab
testing. Parser/helper tests do not establish deployment readiness. No live
system testing, package execution, merging, or deployment was performed here.

Review found no apparent embedded credentials or classification markings in the
published text. This is a content review, not a classification determination.
Runtime outputs may contain sensitive material and must stay outside Git.
