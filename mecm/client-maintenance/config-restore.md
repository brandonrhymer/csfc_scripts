# Restore one approved display configuration

`Invoke-MecmConfigRestore.ps1` backs up and restores one nonsecret JSON display
configuration from an approved local source when its bytes differ. It runs
offline in Windows PowerShell 5.1 with no modules, prompts or source edits. It
does not restart a service. **No real application/configuration policy or MECM
pilot is approved.** The supplied contract and example are synthetic.

Read the [shared policy approval guide](policies.md) before preparing inputs;
this script's stricter schema and activity contract below also apply.

## Operator inputs

| Parameter | Type | Meaning |
| --- | --- | --- |
| Mode | String | `Preview` (default) or `Apply` |
| PolicyPath | String | Exact absolute local path to the approved policy JSON |
| PolicySha256 | String | Independently approved SHA256 of the policy bytes |
| TimeoutSeconds | Integer | 5-120 seconds, default 60, inside the MECM deadline |

An application owner prepares and reviews the policy and configuration; the
junior operator selects these four MECM parameters and starts with Preview.
Calculating a hash is not approval. Privately distribute the approved files and
hash through the normal packaging process. Protect the application root, policy,
source, backup directory and every ancestor from untrusted writes. Execution
rights and expected ownership/DACL must be established before Apply.

`config-restore.policy.example.json` has `Approved:false` and deliberately invalid
zero hash placeholders. `config-restore.source.example.json` is a tiny synthetic
example, never an automatically selected source. The owner must supply exact
hashes of the reviewed source and expected old destination, then approve and pin
the complete policy. Do not enable an example on operational clients.

## Narrow supported schema

The policy has exactly the flat keys in the example. SchemaVersion is integer 1,
Approved is boolean true only after review, and ApprovalReference names the
private approval. ApplicationRoot ends in ApplicationId, which has 3-40 ASCII
letters/digits/hyphens and begins with a letter. The only allowed paths are:

| Purpose | Exact location below ApplicationRoot |
| --- | --- |
| Destination | `maintenance-display.json` |
| Approved source | `ApprovedConfiguration\maintenance-display.json` |
| Original backup | `ConfigurationBackup\maintenance-display.before.json` |
| Activity guard | `maintenance.guard` |
| Activity marker | `application.active` |

Directories and files must already exist except the backup file. Source and
destination are limited to 4,096 bytes. Both must satisfy this exact JSON schema:

| Key | Allowed values |
| --- | --- |
| Schema | String `MaintenanceDisplay/v1` |
| RefreshSeconds | Integer 30-3600 |
| DisplayLevel | String `Normal` or `Compact` |

Extra/repeated keys, escaped key spellings and unsupported values are rejected.
There are no arbitrary strings, connection settings, device identities or secret
fields. This is **not a generic secret detector or arbitrary configuration copy
utility**. A real application's existing file must implement this exact reviewed
contract; other schemas require a separately reviewed product change. Hashes
pin bytes, while explicit owner review establishes that source and destination
are nonsecret and portable. Never put operational configuration in this repo.

ActivityProtocol must be `ExclusiveMaintenanceGuard/v1`. The script holds the
existing guard exclusively; the application must acquire the same guard before
using or changing this configuration. An activity marker blocks the run. Apply
checks the marker again after backup. A maintenance window and guard cooperation
are prerequisites; absent files/processes alone cannot prove inactivity.

Canonical drive-letter paths on fixed NTFS are required. UNC/device/relative and
alternate-stream paths, aliases, protected/system roots, reparse ancestors/files,
hardlinks, unsupported attributes and overlapping roles are rejected. The script
holds every ancestor against rename and each participating file against concurrent
access. Backup creation uses CREATE_NEW, so collisions are never overwritten.

## Changes and recovery

Preview reads and validates both files, expected old hash, activity and backup
availability. It writes no content and creates no backup. Already approved bytes
return `Already correct` in either mode; the existing backup is preserved and no
new backup is created. This result does not attest an older backup's contents.

Apply creates the original backup first, copies its discretionary ACL and original
creation/access/write times, flushes and verifies its hash and DACL. Its owner is
the creating execution identity; the destination owner, DACL, identity and creation
time remain unchanged. The destination is written through its existing exclusive
handle, flushed and hashed; last-write time changes normally. The source remains
unchanged. The destination DACL is verified again after replacement.

**Replacement is not atomic.** Holding the destination handle avoids an unlocked
path replacement race, but interruption can leave partial bytes. No automatic
rollback or retry is attempted. A verified backup remains available after a write
failure. If backup writing fails, the destination has not been touched and the
backup may be incomplete; inspect it before any recovery.

One compact JSON result is below 4 KB and excludes file contents and paths. Exit
0 is evaluated, 1 is failure, 2 is invalid top-level input. Status is `Changed`,
`Already correct`, `Skipped` (Preview) or `Failed`. `BackupState` and
`DestinationState` distinguish verified originals, approved bytes and unknown
state. `WrittenBytes` counts only a verified completed replacement; zero does not
exclude partial writes when OutcomeUncertain is true. A timeout kills the owned
worker but cannot undo I/O; Apply returns possibly-changed/uncertain with detailed
states omitted because its final observations were lost.

After failure, stop further runs and keep the application inactive. An authorized
administrator should independently inspect hashes, validate the original backup,
restore the backed-up bytes through the approved application recovery procedure,
preserve required ACL/metadata, and verify application health. Reconcile any
existing backup before approving another change. The script never overwrites or
deletes it to make a retry succeed.

## Validation and pilot limits

`mecm/tests/check-config-restore.ps1` executes the actual script/worker in fresh
Windows PowerShell processes against temporary NTFS files, including Preview,
repeat Apply, policy/source/destination hashes, schema/secret-field rejection,
ACL/creation-time preservation, backup recovery material, locked files, hardlinks,
junctions, injected partial write and timeout. GitHub Actions is the primary
integration gate. Local fixtures do not establish application or MECM readiness.

A real application owner must first approve this supported contract, paths,
source/old destination hashes, ACL handling, guard protocol and recovery. The
deferred MECM pilot must cover SYSTEM access, endpoint policy, parameters/output,
deadlines, concurrent application behavior, low space/denied backup writes and
interrupted replacement, followed by independent health and recovery checks.
There is currently no MECM test environment and no operational policy approval.

Microsoft references: [CreateFileW access/sharing and CREATE_NEW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew),
[FileShare.None](https://learn.microsoft.com/en-us/dotnet/api/system.io.fileshare?view=netframework-4.8.1),
[handle identity and link counts](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/ns-fileapi-by_handle_file_information),
and [normalized final paths](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew).
