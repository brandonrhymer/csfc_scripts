# CSfC administration scripts

A collection of focused administration tools with script-specific runbooks.
Examples are synthetic. Keep actual deployment identifiers, credentials,
packages, inventories, and runtime evidence outside this repository.

**Current phase: code review. Testing and lab validation remain deferred.**
The scripts are undergoing source review before that later phase. Earlier
limited checks do not establish deployment readiness.

## Choose a starting point

- [Operator start guide](docs/operator-start-here.md): scope, private inputs, and safe preparation.
- [Linux tools](linux/README.md): ClamAV discovery and illustrative local-account discovery/remediation.
- [Windows tools](windows/README.md): Defender, Nessus download, and local Splunk Forwarder utilities.
- [MECM toolkit](mecm/README.md): Configuration Manager preparation, installation, and operations.
- [Preparation record](docs/attachment-validation.md): imported files, prior checks, and deferred testing.
- [Text sanitization](obfuscation/README.md): redact or consistently substitute sensitive values in a text file.

Each tool's runbook explains prerequisites, inputs, effects, outputs, and known
limits. A script being present here is not approval to execute it on any system.

Keep script-specific guides with their scripts in this repository. Examples are
placeholders; supply approved local values privately at runtime. Never commit
credentials, actual network identifiers, inventories, installers, or runtime reports.
