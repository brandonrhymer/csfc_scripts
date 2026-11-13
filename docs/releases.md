# Releases and downloads

Each operational script has its own product ID, version and downloadable ZIP.
A bundle collects product ZIPs for convenient transfer; it does not change their
individual versions. The [catalog](../tools/release/catalog.json) is the source
of truth for versions, entry points and included dependencies.

## Choose a product

| Product ID | Purpose and runbook |
| --- | --- |
| `clamav-discovery` | [Collect ClamAV status](../linux/clamav/README.md) |
| `local-admin-discovery` | [Inspect local Linux accounts](../linux/local-accounts/README.md) |
| `local-admin-remediation` | [Remediate local Linux accounts](../linux/local-accounts/README.md) |
| `mecm-site-status` | [Inspect MECM site status](../mecm/README.md) |
| `mecm-wsus-export` | [Export WSUS material](../mecm/docs/03-first-patches.md) |
| `mecm-collections` | [Prepare MECM collections](../mecm/docs/04-maintain.md) |
| `mecm-msi-application` | [Create a MECM MSI application](../mecm/docs/04-maintain.md) |
| `mecm-cache-cleanup` | [Selective client cache cleanup](../mecm/client-maintenance/cache-cleanup.md) |
| `mecm-ccmeval` | [Overdue client evaluation](../mecm/client-maintenance/ccmeval.md) |
| `mecm-service-start` | [Approved application service start](../mecm/client-maintenance/service-start.md) |
| `mecm-computer-policy-refresh` | [Computer Group Policy refresh](../mecm/client-maintenance/computer-policy-refresh.md) |
| `mecm-dns-cache-flush` | [DNS client cache flush](../mecm/client-maintenance/dns-cache-flush.md) |
| `mecm-time-sync` | [Configured-source time synchronization request](../mecm/client-maintenance/time-sync.md) |
| `mecm-dns-registration` | [Client-owned DNS registration request](../mecm/client-maintenance/dns-registration.md) |
| `mecm-agent-restart` | [Approved application agent restart](../mecm/client-maintenance/agent-restart.md) |
| `mecm-task-enable` | [Approved application task enablement](../mecm/client-maintenance/task-enable.md) |
| `mecm-staging-cleanup` | [Expired application staging cleanup](../mecm/client-maintenance/staging-cleanup.md) |
| `mecm-config-restore` | [Approved application configuration restore](../mecm/client-maintenance/config-restore.md) |
| `text-sanitizer` | [Sanitize a text file](../obfuscation/README.md) |
| `defender-update` | [Stage and apply Defender updates](../windows/defender/README.md) |
| `nessus-plugin-download` | [Download Nessus plugins](../windows/nessus/README.md) |
| `splunk-install` | [Install Splunk Forwarder](../windows/splunk/README.md) |
| `splunk-uninstall` | [Remove Splunk Forwarder](../windows/splunk/README.md) |
| `krbtgt-install` | [Install the KRBTGT tool](../windows/reset-krbtgt/docs/installation.md) |
| `krbtgt-preflight` | [Run KRBTGT preflight](../windows/reset-krbtgt/docs/operator-runbook.md) |
| `krbtgt-test` | [Run the attended KRBTGT test](../windows/reset-krbtgt/docs/operator-runbook.md) |
| `krbtgt-reset` | [Run attended KRBTGT rotation](../windows/reset-krbtgt/docs/operator-runbook.md) |

Read the catalog for each product's current version. Product release tags use
`<product-id>/v<version>`, such as
`clamav-discovery/v0.1.0`. Bundle tags use `bundle/v<version>`.

## Download and use a package

1. Open the repository's [Releases](https://github.com/brandonrhymer/csfc_scripts/releases)
   and select the published product or bundle version you need. Read its release
   notes and validation limits.
2. Download the attached `<product-id>-<version>.zip`, or
   `bundle-<version>.zip`, with the release's checksum and metadata files.
   Use these attached assets for the packaged runbooks and dependencies.
3. Verify the ZIP against `SHA256SUMS.txt` before transfer or extraction. On
   Windows, `Get-FileHash -Algorithm SHA256 .\clamav-discovery-0.1.0.zip` prints
   the digest to compare; on Linux, run `sha256sum -c SHA256SUMS.txt` from a folder
   containing the corresponding assets.
4. Extract the product ZIP and start with `<product-id>-<version>/START-HERE.md`.
   Keep the directory structure intact. Supply approved private inputs as directed
   by the included runbook.

A product ZIP includes its entry point, runbook and declared dependencies under
their repository-relative paths. The catalog explicitly lists the packaged
files; links to other products or development material do not add files to a
download. `PRODUCT.json` records the version, `releaseTag`, a
`sourceContentSha256` digest and the payload's file hashes. The inner
`SHA256SUMS.txt` covers the packaged files and generated metadata.

A product's ZIP stays the same across unrelated repository commits when its
version and packaged content stay the same. Retain the accompanying
`release.json` and provenance with the ZIP: they record the exact tested build
commit. A bundle also records that commit in `BUNDLE.json`.

Every KRBTGT product includes the whole KRBTGT publication manifest, including
the other entry points, because its installation and verification depend on
those files. The selected product's start guide identifies where to begin.
Shared runbooks may describe other products for reference; obtain those products
separately when needed.

A bundle contains individual product ZIPs and `bundle-<version>/BUNDLE.json`,
recording their exact versions, ZIP hashes and source commit. Extract the bundle,
choose a product ZIP, then extract that product. Operators need the script's
documented Python, PowerShell or system prerequisites, but do not need Bun or the
repository's build tooling.

Release preparation generates GitHub build-provenance attestations for the
release ZIPs. On a connected verification workstation, use the
[GitHub CLI verification command](https://cli.github.com/manual/gh_attestation_verify),
substituting the downloaded asset name:

```sh
gh attestation verify clamav-discovery-0.1.0.zip --repo brandonrhymer/csfc_scripts
```

Compare the reported source revision and workflow with the intended release.
An attestation connects an asset to its build provenance; it does not certify
runtime safety or lab readiness. See GitHub's
[attestation guidance](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
and [offline verification procedure](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline)
if your transfer process requires verification without network access.

## Candidate builds

Pull requests and pushes to `main` run **Offline validation**. Its **Product
package checks** job builds all 27 candidate product ZIPs and a bundle from the
tested commit. The downloadable Actions artifact is named `product-packages`
and is retained for 14 days. These are review candidates; the workflow does not
publish a release or deploy a script.

Open **Actions → Offline validation → the intended run → Artifacts →
product-packages**. Check the run's commit and all validation jobs before using
its output. GitHub requires sign-in and repository read access to download
Actions artifacts. See [Downloading workflow artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).

## Prepare a release

Merge the reviewed source and catalog changes to `main`, then open **Actions →
Prepare product release → Run workflow**. Select the `main` branch. The
[release workflow](../.github/workflows/release.yml) accepts:

| Input | Value |
| --- | --- |
| `product` | A product ID from the catalog, or `bundle` |
| `bundle_products` | For a bundle, optional comma-separated product IDs; leave empty for all products |
| `bundle_version` | Optional bundle semantic version, such as `2026.4.0`; blank uses `bundleVersion` from the catalog. An individual product uses its own catalog version. |

The workflow reruns the full validation workflow at the same source SHA,
builds the selected release packages, verifies the downloaded artifacts,
and generates provenance attestations. It then atomically reserves the
namespaced lightweight tag at that tested SHA, creates a **draft** GitHub
Release, uploads and verifies the assets, and rechecks that the tag still points
to the tested commit. It does not publish the draft or deploy anything to
operational systems.
The draft also includes `provenance.jsonl` containing the ZIP attestations.

Review the draft's source SHA, selected products and versions, release notes,
checksums, assets and linked validation run. Resolve any failure before release;
do not treat a partial or failed run as a release candidate. When the package is
ready to distribute, the maintainer publishes the draft through GitHub Releases.
GitHub documents the separate [save-draft and publish actions](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

An existing tag or release, including an existing draft, stops preparation rather
than replacing its contents. A failure after reservation can leave a tag without
a release, or an incomplete draft. Neither is overwritten on retry. The
maintainer must inspect the tag, draft and failed run, then reconcile that state
or prepare a newly reviewed version. Do not publish an incomplete asset set.

## Quarterly bundles

The release workflow is scheduled for 14:00 UTC on January 1, April 1, July 1
and October 1. It prepares a draft containing all catalog products from one
`main` revision. Its calendar-based semantic version is `YYYY.Q.0`, where `Q`
is the quarter number; for example, `2027.1.0` for the first quarter of 2027.

Individual script changes create CI candidates and can receive independent
product releases. They do not trigger a bundle release. Use manual dispatch
for a selected bundle or a reviewed follow-up version such as `2027.1.1`.

The schedule runs on the default branch and can be delayed by GitHub Actions;
the configured time is not a delivery guarantee. Check the run and draft when
the quarter begins. See GitHub's [schedule behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).

## Local packaging

Maintainers can inspect committed-source packages locally with Bun 1.4.2. Run
from the repository root and use a new or empty output directory:

```sh
# Exercise packaging and release regressions.
bun test tools/release

# Check changed product payloads and versions between committed revisions.
bun tools/release/versions.ts

# All product candidates and an all-product bundle.
bun tools/release/package.ts --output ./package-preview --product all --bundle-version 2026.4.0

# One independent product.
bun tools/release/package.ts --output ./product-preview --product clamav-discovery

# A bundle with a selected subset.
bun tools/release/package.ts --output ./bundle-preview --product bundle --bundle-products clamav-discovery,local-admin-discovery --bundle-version 2026.4.0

# Verify the complete output directory.
bun tools/release/package.ts --verify ./package-preview
```

Use `--ref <exact-commit>` to select a committed source revision explicitly.
Uncommitted edits are not release source. Output includes ZIPs, `release.json`,
`SHA256SUMS.txt` and `RELEASE-NOTES.md`. Check the manifest and extracted files
against the catalog and runbook before preparing a draft.

The version check compares `HEAD` with `HEAD^` by default; set the `BASE_SHA`
environment variable to an exact base commit to use another comparison. It
requires a strictly newer product version when that product's payload changes
and rejects version downgrades. Shared packaged-document changes can affect
multiple products; inspect the affected products before updating the catalog.

The pipeline and packaging work are tracked in
[#31](https://github.com/brandonrhymer/csfc_scripts/issues/31). Live lab work is
separate and remains deferred in
[#29](https://github.com/brandonrhymer/csfc_scripts/issues/29). A package, passing
mock, attestation or published release does not close those lab requirements.
