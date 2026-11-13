# CSfC administration scripts

A collection of focused administration tools with script-specific runbooks.
Examples are synthetic. Keep actual deployment identifiers, credentials,
packages, inventories, and runtime evidence outside this repository.

Each operational script is a separately versioned product. Download the product
you need from a published release, or use a bundle containing several products.
The [release and download guide](docs/releases.md) explains package selection,
verification, candidate builds, and the quarterly bundle schedule. Operators do
not need Bun or the build tooling to use a downloaded product.

**Full runtime and lab validation are incomplete.**
Hosted isolated checks and source review do not establish deployment readiness.

## Choose a starting point

- [Operator start guide](docs/operator-start-here.md): scope, private inputs, and safe preparation.
- [Linux tools](linux/README.md): ClamAV discovery and illustrative local-account discovery/remediation.
- [Windows tools](windows/README.md): Defender, Nessus download, Splunk Forwarder, and attended KRBTGT rotation.
- [MECM toolkit](mecm/README.md): Configuration Manager preparation, installation, and operations.
- [MECM client maintenance](mecm/client-maintenance/README.md): eleven independently packaged client maintenance candidates, with GitHub CI and outstanding approved-client pilots.
- [Validation guide](docs/validation.md): check coverage, known limits, and required lab validation.
- [Maintenance readiness](docs/maintenance/README.md): native DP/SUP coverage, KRBTGT evidence review, and the unprovisioned validation-lab blueprint.
- [Releases and downloads](docs/releases.md): independent products, selectable bundles, and maintainer release steps.
- [Text sanitization](obfuscation/README.md): redact or consistently substitute sensitive values in a text file.
- [Contributing](CONTRIBUTING.md): bounded changes, review, and validation evidence.
- [GitHub workflow](docs/github-workflow.md): issues, project tracking, validation/package checks, and agent profiles.

Each tool's runbook explains prerequisites, inputs, effects, outputs, and known
limits. A script being present here is not approval to execute it on any system.

Keep script-specific guides with their scripts in this repository. Examples are
placeholders; supply approved local values privately at runtime. Never commit
credentials, actual network identifiers, inventories, installers, or runtime reports.
