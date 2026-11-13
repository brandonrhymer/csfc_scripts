# Approved disposable staging cleanup

`Invoke-MecmStagingCleanup.ps1` previews or deletes old disposable files from one
reviewed application staging directory. It runs offline in Windows PowerShell
5.1 and requires no installed module or source edits. This is a candidate for
local fixture testing and GitHub Actions review. **No operational application,
path policy, or MECM pilot has been approved or tested.**

Read the [shared policy approval guide](policies.md) before preparing inputs;
this script's stricter schema and activity contract below also apply.

## Operator inputs

Import the script into MECM Run Scripts using the normal author, approver and
runner separation. Enter these four parameters; leave Mode at Preview first.

| Parameter | Type | Meaning |
| --- | --- | --- |
| Mode | String | `Preview` (default) or `Apply` |
| PolicyPath | String | Exact full local path to the approved JSON policy |
| PolicySha256 | String | Independently supplied 64-character SHA256 of that policy |
| TimeoutSeconds | Integer | 5-120 seconds, default 60; shorter than the MECM deadline |

The operator receives an already reviewed policy file and its hash. The operator
does not edit the script, approve a policy by calculating its hash, install a
framework, or respond to prompts. Deploy the policy privately through the normal
approved packaging process. A hash pins reviewed bytes; it does not authenticate
an approver. Keep the policy writable only by authorized administrators and
SYSTEM. Limit writes to the staging directory and its ancestors to trusted
administrators and the explicitly reviewed application identity.

The included `staging-cleanup.policy.example.json` is **synthetic and disabled**:
`Approved:false`. It is never selected automatically. The application owner must
document disposable-file semantics and supply the approved policy before use.

## Policy and activity contract

The exact flat schema in the example is required, with no extra or repeated keys.
`SchemaVersion` is integer 1, `Approved` is boolean true only after review, and
`ApprovalReference` identifies the private approval. `ApplicationId` contains
3-40 ASCII letters/digits/hyphens and begins with a letter. `Root` must end in
`<ApplicationId>\DisposableStaging`. The script never creates that directory.

Paths must be canonical absolute drive-letter paths on fixed NTFS volumes, at
least three components below the volume root. UNC/device/relative paths, alternate
streams, short-name aliases, substituted-drive aliases, reparse points and system
or protected directory names are rejected. Windows, Program Files, MECM cache,
logs, evidence and package roots are excluded. Directory handles prevent ancestor
renames while work proceeds. Files must have one hardlink and ordinary supported
attributes; open/locked, read-only, hidden/system, encrypted, sparse or compressed
candidate files fail preflight.

`FileNamePatterns` has 1-8 distinct patterns of the form `prefix-*.disposable`;
the prefix has 1-32 ASCII letters/digits/hyphens. Patterns or names containing
`log`, `evidence`, `package` or `active` are protected. Files with other names and
all nested directories remain untouched. Overlapping matches are retained.
An approved suffix alone does not prove content is disposable: the owner must
confirm the application never places logs, evidence, installers or active
packages under these names.

`MinimumAgeDays` is 1-3650. Both creation and last-write timestamps must precede
the cutoff and must be plausible. `MaximumEntries` is 1-500 top-level entries,
including retained entries; `MaximumDeleteBytes` is 1-1,073,741,824 bytes. Exceeding
either limit fails before any deletion. The script never recurses.

`ActivityProtocol` must be `ExclusiveMaintenanceGuard/v1`. An existing ordinary
`maintenance.guard` file in Root is opened exclusively for the entire operation.
**The application must honor the same guard before writing, reading or consuming
staged files.** Without this cooperation the policy is unsupported; a process
check alone cannot establish inactivity. `ActivityMarkers` lists 1-16 distinct
`name.active` files, and `ProcessNames` lists 1-16 exact process names without
`.exe`. Any marker or matching process blocks work. Activity is checked before
inspection and before every deletion. No process is stopped. The application and
trusted administrators must not change the directory during the operation.

## Results, failures and recovery

One JSON summary stays below 4 KB and excludes paths and file content. Exit 0 is
an evaluated result, 1 is failure, and 2 is invalid top-level parameters.

| Status/reason | Meaning |
| --- | --- |
| Skipped / PreviewOnly | Evaluated eligible files; nothing deleted |
| Already correct / NoEligibleFiles | No files eligible for this approved policy |
| Changed / ApprovedDisposableFilesRemoved | All selected deletions confirmed |
| Failed / stage-specific reason | Stop and inspect; do not automatically retry |

`PlannedBytes` and `RemovedBytes` are logical file lengths, **not disk space
reclaimed**. Counts and removed bytes cover confirmed removals only. An ordinary
failure preserves prior counts; `MayHaveChanged` and `OutcomeUncertain` describe
partial effects. A timeout terminates the owned worker, returns unknown counters
(omitted rather than zero), and marks Apply as possibly changed/uncertain.
Termination does not undo completed I/O or a pending deletion.

Deletion has no rollback. The policy must cover genuinely disposable content
with a documented regeneration procedure. After a failed or timed-out Apply,
inspect the approved root and application state privately and reconcile before
another run. A repeated successful Apply finds no remaining eligible files.

## Validation and pilot limits

The isolated `mecm/tests/check-staging-cleanup.ps1` suite runs the actual script
and child worker in fresh Windows PowerShell processes against temporary NTFS
files. It checks Preview, repetition, age/activity exclusions, policy/path limits,
unexpected-file retention, file locks, hardlinks, junctions, partial failure and
timeout. Fault cases inject a failure into a disposable copy of the script.
GitHub Actions is the primary integration gate; local runs support development.

Before an operational pilot, obtain a real policy and application-owner approval;
verify guard cooperation, file semantics, ACLs, identity under SYSTEM, application
versions, concurrent activity, endpoint controls, and MECM parameter/output and
deadline behavior. Run Preview, independently inspect planned contents, run a
bounded Apply, confirm only intended files disappeared and the application remains
healthy, then repeat. No lab is currently available; fixture results prove none
of these application or MECM behaviors.

Microsoft references: [CreateFileW sharing and reparse flags](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew),
[GetFinalPathNameByHandleW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew),
[file identity and link counts](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/ns-fileapi-by_handle_file_information),
and [handle-based deletion](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle).
