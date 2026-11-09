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
- [Text sanitization](#text-sanitization): the repository-root utility described below.

Each tool's runbook explains prerequisites, inputs, effects, outputs, and known
limits. A script being present here is not approval to execute it on any system.

## Text sanitization

`obfuscatefile.ps1` redacts or consistently substitutes sensitive values in one text file. It supports `.txt`, `.log`, `.conf`, `.cfg`, `.xml`, and other extensions when the contents are valid text. Binary files that happen to contain readable strings are unsupported.

Requires **PowerShell 7.4 or later**. No external PowerShell modules are needed.

## Usage

Run these commands from PowerShell in the repository directory:

```powershell
# Redact a log; writes application.redacted.log beside the input.
./obfuscatefile.ps1 -Path ./application.log

# Configuration files work the same way, regardless of extension.
./obfuscatefile.ps1 -Path ./service.conf -OutputPath ./service.sanitized.conf

# Supply hostnames and sensitive values that cannot be inferred from context.
./obfuscatefile.ps1 -Path ./capture.txt `
    -KnownHostnames 'SERVER01', 'BACKUP02' `
    -SensitiveValues 'synthetic-value-to-remove' `
    -SecretKeys 'databaseCredential', 'customAccessKey'

# Preserve relationships using stable replacement tokens.
./obfuscatefile.ps1 -Path ./application.log -Mode Obfuscate

# Explicitly retain a reversible map in a separate, protected location.
./obfuscatefile.ps1 -Path ./application.log -Mode Obfuscate `
    -MapPath ./private/application.map.xml
```

Keep mapping files separate from shared output: they contain the original values in readable XML. Redaction is the default and does not create a map. Obfuscation without `-MapPath` creates no persistent map either. To reuse an existing map, supply its path with `-Force`; only version 2 maps from this revision are accepted. Legacy maps are rejected because their tokens may be ambiguous.

## Detection and limits

The script detects IPv4 and IPv6 addresses, dotted hostnames/domain names, and single-label hostnames in recognized host/server/computer fields. It recognizes `key=value`, `key: value`, and line-start whitespace directives such as `server SERVER01` or `password synthetic-value`. Use `-KnownHostnames` for single-label names appearing outside those contexts.

Secret detection covers common password, token, API-key, authorization, connection-string, private-key, and community fields, plus Bearer/Basic authorization values and private-key PEM blocks. Default field names include `password`, `passwd`, `pwd`, `secret`, `client_secret`, `token`, `access_token`, `refresh_token`, `api_key`, `apikey`, `authorization`, `connectionstring`, `privatekey`, and `community`, including supported case/separator variants. Add application-specific names with `-SecretKeys`, or known values with `-SensitiveValues`.

Dotted filenames such as `report.log` can look like domains and be replaced. Unlabelled secrets and arbitrary classified content cannot be identified reliably from text alone. Review the output against your data policy before sharing it; running the script does not establish that a file has been declassified.

Credentials embedded in service URLs are also masked. Unquoted secret values are consumed to the next field assignment or line end; punctuation within them is not treated as a safe boundary. An unquoted connection-string field consumes the rest of its line. Ambiguous formats may therefore lose surrounding text; this is text sanitization, not a parser for every configuration language.

## Parameters

| Parameter | Purpose |
| --- | --- |
| `-Path` | Required path to a single input file. Directory traversal is not supported. |
| `-OutputPath` | Output file. Defaults to `<name>.redacted<extension>` or `<name>.obfuscated<extension>`, depending on the mode. |
| `-Mode` | `Redact` (default) or `Obfuscate`. |
| `-MapPath` | Optional reversible XML map; permitted only with `Obfuscate`. |
| `-KnownHostnames` | Additional exact hostnames to recognize. |
| `-SensitiveValues` | Additional exact sensitive strings to remove or substitute. |
| `-SecretKeys` | Additional field names whose values are sensitive. |
| `-Encoding` | `Auto` (default), `Utf8`, `Utf16LE`, `Utf16BE`, `Utf32LE`, `Utf32BE`, `Ascii`, or `Latin1`. |
| `-Force` | Permit replacement of existing output/map files. Input, output, and map paths must still be distinct. |

Existing destination directories must exist. Without `-Force`, existing output/map files are protected from replacement. Results are staged locally before moving them into place; on Unix, newly created output and map files allow owner read/write only (`0600`). Read, parse, validation, and write failures stop processing instead of reporting success. The input is preserved.

## Text encoding and XML

Automatic encoding detection uses a byte-order mark when present, honors supported XML encoding declarations, and otherwise uses strict UTF-8. Choose an explicit supported encoding for legacy text without a mark; invalid text and unsupported binary control content are rejected. The file is loaded into memory, so available memory limits file size.

XML receives format-aware processing of attribute values, text, comments, CDATA, and processing-instruction data. XML character references are decoded in attributes/text. Secret/host contexts include named elements and configuration entries such as `<add key="password" value="synthetic-value"/>` or `<add name="host" value="SERVER01"/>`. Adjacent text/CDATA is combined across comments for detection, but values split across nested elements are not concatenated. Serialization may change character-reference or CDATA formatting.

Supported XML encodings and declarations are kept consistent, and the saved document is checked for valid XML. Malformed XML-like input, DTDs, and external entities are rejected.

Element/attribute names and namespace identifiers remain structural identifiers. They may contain names you consider sensitive and need separate review. Valid XML output does not imply conformance to an external schema or unchanged application behavior.

## Tests

The synthetic regression suite runs without Pester or other modules:

```powershell
./tests/obfuscatefile.Tests.ps1
```

## Configuration Manager (MECM)

See the [MECM toolkit](mecm/README.md) for offline preparation, native site installation, first patch deployment, and routine operations. Its Windows PowerShell requirements are documented separately.

## Additional administration tools

- [Linux tools](linux/README.md): ClamAV discovery and illustrative local-account discovery/remediation.
- [Windows tools](windows/README.md): Defender updates, Nessus plugin downloads, and Splunk Forwarder installation/removal.
- [Attachment validation](docs/attachment-validation.md): source mapping, sanitization, checks, and remaining lab work.

Keep script-specific guides with their scripts in this repository. Examples are
placeholders; supply approved local values privately at runtime. Never commit
credentials, actual network identifiers, inventories, installers, or runtime reports.
