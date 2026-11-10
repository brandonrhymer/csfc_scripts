# Download a Nessus plugin archive

`download-plugins.ps1` downloads one archive from an operator-supplied HTTPS URL
and saves it to a new local file.

**It downloads only.** It does not register a scanner, activate a license,
validate archive authenticity, import plugins, restart services, or update a
scanner's displayed plugin set.

**Full runtime and lab validation are incomplete.**
The examples below do not establish download or scanner-import success.

## Requirements

- Windows PowerShell 5.1 or later on the approved download computer.
- An approved source URL and permission to download that archive.
- Existing destination directory, sufficient space, and write access.
- A separate approved verification/transfer/import procedure for the scanner.

The script does not set proxy, certificate, or TLS policy. Resolve connectivity
and trust requirements through the approved process; do not disable certificate
validation to work around a failure.

## 1. Prepare private runtime values

Keep the real download URL outside source control. URLs can contain activation
or download tokens even when there is no username/password before the hostname.
Do not paste such links into a public issue or transcript.

```powershell
# Run from the directory containing download-plugins.ps1.
# Enter the approved URL at runtime rather than putting it in the source file.
$uri = Read-Host 'Approved HTTPS plugin archive URL'

# Choose a NEW file in an existing private directory.
$output = 'C:\PrivateUpdates\Nessus\all-2.0.tar.gz'
```

`https://updates.example.invalid/all-2.0.tar.gz` is a reserved placeholder, not a
download service. The script rejects that example, non-HTTPS input, and URLs with
embedded user information. A valid URL is not by itself proof of approval or
that the response contains the expected archive.

## 2. Preview, then download when approved

```powershell
# Preview: checks the supplied values and output location, without downloading.
.\download-plugins.ps1 -DownloadUri $uri -OutputPath $output -WhatIf

# Later, when authorized: download once to the new local destination.
.\download-plugins.ps1 -DownloadUri $uri -OutputPath $output
```

Preview does not test connectivity, permissions by writing, available content,
or scanner compatibility. The script refuses to overwrite an existing output
file. Use a new filename rather than deleting evidence to force a rerun.
The URL must serve the archive directly. All redirects are refused so a response
cannot silently downgrade HTTPS to HTTP. Obtain an approved direct HTTPS source
if the service returns a redirect; do not bypass this restriction.

During download, a uniquely named `.partial` file is used in the destination
directory. Empty downloads are rejected. After the request completes, the file
is moved into the selected name. The script attempts to remove its temporary
file on failure. Errors stop the command rather than reporting a completed
archive.

## 3. Keep download separate from import

A nonempty downloaded file can still be an error page or the wrong package.
Before any later scanner import, follow the approved procedure to establish:

1. The source, product, archive type, and intended scanner/version.
2. Integrity/authenticity using the independently approved evidence available.
3. Transfer/media handling requirements for the destination environment.
4. The correct import method and who may perform it.
5. How the scanner's resulting plugin set and service state will be recorded.

This repository does not supply an import command as part of this download tool.
Do not infer successful scanner updating from the download message.

## Troubleshooting boundaries

| Symptom | Next preparation step |
| --- | --- |
| Existing output | Choose a new approved output filename. |
| Missing directory | Prepare the private destination directory using your normal process. |
| URL rejected | Supply the approved HTTPS URL without embedded user information; keep tokens private. |
| HTTP/TLS/proxy error | Resolve source, trust, or network prerequisites without bypassing security controls. |
| File saved but scanner unchanged | Expected: this utility performs no import. Follow the separate approved import procedure. |

Keep archives, URLs, logs, and import records outside Git. See the
[validation guide](../../docs/validation.md) for outstanding validation requirements.
