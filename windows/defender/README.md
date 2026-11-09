# CSfC Defender Update — Sequential MVP

A standalone implementation of the approved **validate → connect → inspect → copy → execute → verify → report** workflow. It processes one target at a time.

**Current phase: content preparation. Full testing and review are deferred.**
The workflow below is documentation for later approved use, not an instruction
to begin testing now. Earlier limited parser/helper checks do not establish
Windows remoting, certificate, ACL, or installation readiness.

## Files

| File | Purpose |
|---|---|
| `Invoke-CSfCDefenderUpdate-MVP.ps1` | Standalone deployment script; no supporting module required. |
| `systems.example.txt` | Inert, single-target inventory template. |

## Prerequisites

Run the deployment from an elevated **64-bit Windows PowerShell 5.1** console on the designated domain management machine. The account must have administrative access on each target. Targets must have an approved Windows PowerShell remoting endpoint named `Microsoft.PowerShell`, functioning Kerberos/DNS, and a working Defender module with `Get-MpComputerStatus`. The script does not configure any of those prerequisites.

Use an approved Microsoft Defender **security-intelligence executable**, not a platform updater or a different Microsoft installer. Microsoft's update page identifies the available product/platform downloads and documents direct execution of the downloaded package. The supported filenames here are `mpam-fe.exe` and `mpam-feX64.exe`.

Prepare the package through your approved download/import process. Record its SHA-256, signature version, release time in UTC, and intended product/architecture. The script checks a trusted Authenticode signature with Microsoft Corporation as publisher, computes SHA-256, optionally compares an independently approved hash, and checks the PE executable architecture against the target. This is **not** automatic inspection of every embedded payload or a substitute for choosing the correct package. A Microsoft signature alone does not establish package freshness or organizational approval.

The controller must have the certificate trust material required for package signature validation. An air-gapped trust-validation failure is an error; this script provides no bypass. Review/sign the deployment script under your organization's existing execution policy. It does not alter execution policy, TrustedHosts, certificates, firewall rules, Defender settings, or services.

Use one designated controller and do not launch overlapping deployments from other management machines. A local file lock prevents overlapping ordinary runs from this controller. It is not a distributed deployment lock.

## 1. Prepare the inventory and results folder

Place the files in a working directory. Copy `systems.example.txt` to `systems.txt`, then replace the example with **one approved pilot hostname**. Full-line `#` comments and blank lines are ignored. Names are trimmed, normalized, and deduplicated case-insensitively. IP addresses, inline comments, and invalid hostname characters are rejected.

Short names and FQDNs are accepted, but aliases are not resolved into a canonical computer inventory. Include each actual machine only once. Targets are exactly the machines in the file; the script does not discover all Active Directory computers.

Create a `Results` directory and use a **new CSV filename per execution**. Existing CSVs are never overwritten or appended across runs.

```powershell
New-Item -Path .\Results -ItemType Directory -Force | Out-Null
Copy-Item .\systems.example.txt .\systems.txt
notepad.exe .\systems.txt
```

The default remote directory is `C:\ProgramData\CSfC-DefenderUpdate-MVP`. Keep this dedicated to the utility. New staging directories are restricted to SYSTEM and local Administrators. Existing directories are inspected, not silently re-ACLed; an unapproved owner or writer fails the target. Arbitrary shared `C:\Temp` directories may fail this check. Staging parents must also be trusted administrative locations; the checks are not a general filesystem-security audit.

## 2. Reserve validation for the later phase

See [repository validation](../../docs/attachment-validation.md). The original
attachment referenced companion tests and a validation file that were not among
the supplied files; they are not represented as included or executed here.
When the later full test/review phase is authorized, include Windows PowerShell
5.1 and an approved single-target pilot. Those activities are currently deferred.

## 3. Configure and preview

Replace the source path with your staged package location. It may be a local path or a share readable by the controller; the remote target does not need access to that source share. `Copy-Item -ToSession` transfers the controller's staged file into the target session.

```powershell
$settings = @{
    SourceDirectory      = 'D:\Updates\Defender'
    DestinationDirectory = 'C:\ProgramData\CSfC-DefenderUpdate-MVP'
    ExecutableFilename   = 'mpam-fe.exe'
    SystemsListPath      = '.\systems.txt'
    ResultsFilePath      = '.\Results\Defender-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
}

# Recommended: enter metadata from the approved package/import record.
# Do not use invented/example version numbers or the file's copy timestamp.
$version = Read-Host 'Approved package signature version (Enter to omit)'
if ($version) { $settings.ExpectedSignatureVersion = $version }
$hash = Read-Host 'Independently approved SHA-256 (Enter to omit)'
if ($hash) { $settings.ApprovedSha256 = $hash }
$released = Read-Host 'Package release timestamp in UTC, with Z or +00:00 (Enter to omit)'
if ($released) { $settings.PackageReleaseTimeUtc = $released }

.\Invoke-CSfCDefenderUpdate-MVP.ps1 @settings -WhatIf
```

`-WhatIf` reads and validates inputs and the source signature/hash, then lists intended target actions. **It creates no files and contacts no targets.** It therefore does not prove report writability, remote permissions, target readiness, or target free space.

No installer arguments are supplied by default: Microsoft's update instructions say to launch the package. `-InstallerArgumentList` exists for arguments independently validated for your exact package; the script does not assume that `-q` is supported.

## 4. Execute the single-target pilot

```powershell
.\Invoke-CSfCDefenderUpdate-MVP.ps1 @settings
$LASTEXITCODE

Import-Csv -LiteralPath $settings.ResultsFilePath |
    Format-Table ComputerName, DeploymentResult, RecencyResult, BeforeVersion, AfterVersion, Stage -AutoSize
```

For a separately approved account, add `$settings.Credential = Get-Credential` before execution. For an already configured HTTPS remoting environment, add `$settings.UseSSL = $true`; certificate checks are not disabled. The script explicitly requests Kerberos and does not fall back to IP-based or TrustedHosts-based authentication.

After accepting the pilot evidence, populate the approved target list, assign a **fresh** results path, and rerun. This MVP remains sequential; it has no throttle parameter.

## Results and acceptance

| DeploymentResult | Meaning |
|---|---|
| `AlreadyAtOrAbovePackage` | The baseline was already at/above the supplied expected version; execution was skipped. |
| `TargetVersionVerified` | Installer exit was accepted and the target reached/exceeded the supplied expected version. |
| `VersionIncreaseObserved` | Version increased, but no expected package version was supplied; this is incomplete evidence, not package-version verification. |
| `NoVerifiedVersionChange` | No verifiable increase without expected-version metadata. The machine may already be current; it is not labeled a successful deployment. |
| `ExecutionFailed` | A nonzero or missing installer exit code. The MVP conservatively accepts only zero and does not interpret undocumented reboot codes as success. |
| `VerificationFailed` | Installer completed acceptably but the expected version was not observed before the verification deadline. |
| `Failed` | Failure before a known installation outcome, with stage and error recorded. |
| `Unverified` / `TimedOutUnverified` | A command/installation outcome could not be established. Inspect before retry. |
| `SkippedByOperator` | The operator declined the target through confirmation. |

Definition recency is independent: **Recent** below 24 hours; **Aging** from exactly 24 through exactly 48 hours; **Stale** over 48 hours; **Unknown** for missing, invalid, or future timestamps. Thresholds are configurable. The script converts Defender's local last-updated time to UTC **on the target** before serialization. A controller/target observation-time difference over five minutes marks recency unknown and requests clock investigation.

Optional package release metadata is also aged independently. It is operator-supplied metadata, not automatically extracted or cryptographically bound to the package; keep it associated with the approved SHA-256 in your import record. No online check is made for the latest available definitions. A recent target timestamp alone does not prove that the imported package is current.

Defender operating mode, service status, antivirus status, real-time protection status, and reboot-required status are recorded separately. Signature success does not mean real-time protection is enabled. Passive mode is recorded without remediation. An unavailable Defender service fails prerequisite checks.

CSV rows include the package hash, signing-certificate thumbprint, source architecture, before/after versions and UTC timestamps, exit code, available process ID, failed stage, durations, notes, and error. The controller writes/flushed each completed row. A report-write failure stops new dispatches rather than continuing without evidence.

| Exit | Meaning |
|---|---|
| `0` | All processed targets are version-verified/already-at-version and recent; no supplied package-age warning. Preview also returns zero after its limited checks. |
| `1` | At least one target failed, has unknown/stale definition status, or supplied package-release metadata is stale. |
| `2` | No exit-1 condition, but aging definitions/package, incomplete version evidence, or an operator-skipped target needs attention. |
| `3` | Controller/preflight/report failure. Stop and inspect partial results. |

Missing optional release metadata does not by itself change the exit code. Missing expected-version metadata prevents full version-verification success. Hosts absent from a partial CSV were not completed by this run; a CSV is not a durable resumable queue.

## Timeout and interruption handling

Defaults are 30 seconds to connect, 60 seconds per ordinary remote command, 600 seconds for the installer, and 120 seconds to verify, polling every 5 seconds. Free-space preflight requires the package size plus 1 GiB of configurable headroom on the staging volume; this is a pilot setting, not a vendor-specified space requirement, and does not test every installer extraction volume.

Installer execution uses `Start-Process -Wait -PassThru` inside a remoting job. `-Wait` waits for the process tree. The controller bounds its wait with `Wait-Job -Timeout`, then cancels the command and closes the session if necessary. This is not implemented using WinRM `OperationTimeout`, which Microsoft says is not a remote-command runtime limit.

**A timeout does not prove that the remote installer stopped or completed.** Session closure can terminate remotely launched processes. The script never blindly retries, force-kills unrelated processes, rolls definitions back, or reboots a target. It creates `DefenderUpdate-MVP.pending.json` immediately before launching the installer, and deletes that marker only after a completed process-tree wait. An unresolved marker blocks a later execution, including the ordinary already-current shortcut. The marker records the run, package path/hash, and attempted start time; a PID may be unavailable if the wait never returned.

After an unresolved attempt, use approved target-management procedures to inspect the marker, relevant process tree, Defender status/version, and event logs. Do not remove the marker while execution is active or the outcome is uncertain. Once a responsible operator has reconciled the attempt and confirmed no relevant installer remains active, the operator may remove that specific marker and authorize a targeted retry. There is no automatic force/clear-marker option.

**MVP limitation:** local source staging and `Copy-Item -ToSession` are synchronous and have no separately enforced whole-transfer deadline. A stalled transfer can block sequential progress. Ordinary command cancellation/cleanup can also add time beyond the nominal job deadline. This utility is not a durable background service and does not claim a strict end-to-end host deadline.

## Cleanup and follow-up

Only the controller's unique per-run package directory is cleaned automatically. The protected controller workspace and lock file remain; the lock is an open file handle, so the mere presence of `run.lock` does not mean a run is active. Packages on targets remain for inspection and are replaced on the next safe execution. Remove them through approved cleanup procedures after resolving all uncertain installations. Keep the CSV according to your evidence-retention policy.

Investigate failures by `Stage` and `Error`. A stale target does not prove the source package was stale: compare the installed version with the approved package record. Import a newer package when the source is outdated; otherwise investigate installation, compatibility, or verification. Build a new inventory containing only the approved follow-up targets and use a fresh CSV path. Do not automatically retry timeout or unresolved-marker records.
