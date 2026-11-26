# Acquire missing update files for a disconnected site

Use this when the existing export lacks files for selected updates. Metadata and
content are separate: a console update record does not prove the patch files
are present. The shared connected WSUS serves another network; do not change
its products, classifications, languages, approvals, synchronization or cleanup.
The acquisition owner must provide a separately approved source and workflow.

## Define the acquisition request

Keep this request outside Git. Do not send internal device inventories to a
public service.

| Required field | Evidence to supply |
| --- | --- |
| Update identity | Update ID/revision, title/KB, product, architecture and applicability selected in the disconnected console |
| Content scope | Required languages and complete file/content identifiers for those updates; include dependencies/UUP content where applicable |
| Source and owner | Approved connected ConfigMgr or dedicated WSUS acquisition environment; owner and permitted download scope |
| Deliverable | Files with relative paths preserved, manifest of names/sizes/SHA-256, publisher/source records and successful download log |
| Transfer | Approved media/destination, scan results, dates and matching source/destination hashes |
| Acceptance | Disconnected Download Software Updates wizard succeeds for every selected update, followed by DP/pilot verification |

## Use a supported acquisition branch

**Connected ConfigMgr source available:** have its authorized owner select the
matching updates in **Software Library > Software Updates > All Software
Updates**, run **Download**, and use a new approved deployment-package source.
Select required languages and let its supported internet download complete.
Retain wizard results and `PatchDownloader.log`. Transfer the completed source
files, preserving paths, together with the manifest. No client deployment is
required to acquire that package's files.

**Separate WSUS acquisition source available:** have that server's owner approve
the necessary product/classification/language/download settings and obtain the
required files through supported WSUS procedures. Wait for actual file-download
completion, then export/copy using the approved disconnected transfer procedure.
An approval or synchronization event alone is not proof that all files exist.
This branch does not authorize changes to the existing shared export server.

**Only direct Catalog downloads available:** reconcile the complete file list
for the selected updates with the acquisition owner. A KB page or one `.msu`
does not establish complete UUP/express content. A downloaded `.msu` is not a
WSUS metadata-import package. If the approved source cannot deliver the complete
set, stop and obtain a supported acquisition environment; do not rename files
or mark the dependency satisfied.

Microsoft documents the [ConfigMgr download workflow](https://learn.microsoft.com/en-us/intune/configmgr/sum/deploy-use/download-software-updates)
and distinguishes [Catalog downloads and WSUS imports](https://learn.microsoft.com/en-us/windows-server/administration/windows-server-update-services/manage/wsus-and-the-catalog-site).

## Accept the files inside the disconnected environment

1. Follow the approved scan/transfer process. Compare each full SHA-256 with the
   source manifest and verify publisher/source provenance. Where an individual
   file carries an Authenticode signature, check it; not every payload file is
   individually Authenticode-signed. Matching transfer hashes prove copy integrity,
   not trust. Preserve the vendor's content validation rather than bypassing it.
2. Stage files in a protected local/network folder with their original names
   and relative paths. Grant the console operator access to read them. Keep
   this staging area separate from the permanent package source and WSUS database.
3. In the disconnected console, select the exact update set and **Download**.
   Create/select an approved deployment package with its own permanent UNC source
   folder. The operator and SMS Provider computer need the documented write
   access to that destination. Do not share a source directory across packages.
4. Choose **Download software updates from a location on my network**, select
   staging, and choose the required available languages. Require successful
   completion for every selected update. Inspect `PatchDownloader.log` in the
   executing user's `%TEMP%` directory on the console host for missing files,
   source access, signature/hash or download failures.
5. If incomplete, retain the missing identifiers/error details and return them
   to the acquisition owner. Reconcile the source before rerunning the wizard.
   Do not change the shared WSUS or silently omit required updates.
6. Distribute the completed package to the pilot DP and verify its content status.
   Continue the [first-patch test](03-first-patches.md#prepare-installation-files-and-test).
   File acceptance is not client-installation acceptance.

## UUP readiness

Apply this branch to supported Windows 11 UUP targets. Mark it not applicable
with the target-OS rationale for a server-only pilot; do not presume every
operating system uses the same content path.

- Check supported, currently serviced WSUS/Windows versions and all SUPs. The
  documented UUP baseline includes the February 2023 or later WSUS-host cumulative
  update; use current approved servicing rather than deliberately installing an
  obsolete CU.
- Inspect IIS server-level MIME types and inheritance: `.wim` maps to
  `application/x-ms-wim`, `.msu` to `application/octet-stream`. Current servicing
  supplies support; if the documented manual fallback is approved, check existing
  mappings first and add only missing entries. Duplicate mappings can break IIS.
- Plan additional UUP storage of approximately **10 GB per Windows version and
  processor architecture**, plus normal package, transfer, backup and growth
  headroom. Measure actual selected content; do not treat that estimate as a cap.
- Verify the full required content set, correct languages, DP distribution and a
  real matching pilot. A few successful Catalog downloads do not close this check.

Source: [Microsoft WSUS UUP considerations](https://learn.microsoft.com/en-us/windows-server/administration/windows-server-update-services/plan/plan-your-wsus-deployment#uup-considerations).
