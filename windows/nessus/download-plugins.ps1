#Requires -Version 5.1
<#
.SYNOPSIS
Download a Nessus plugin archive from an operator-supplied approved HTTPS source.
.PARAMETER DownloadUri
Approved HTTPS archive URL. Supply it at runtime; keep token-bearing URLs private.
.PARAMETER OutputPath
New local output filename in an existing private directory. Never overwritten.
.NOTES
Derived from update-acas-plugin.ps1. Downloads only; does not import plugins.
Example URI: https://updates.example.invalid/all-2.0.tar.gz (reserved placeholder).
Keep actual URLs, credentials, downloaded archives, and logs outside Git.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][uri]$DownloadUri,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
# Stop on a failed request or filesystem operation instead of claiming success.
$ErrorActionPreference = 'Stop'
# 1. Reject insecure/credential-bearing input and the reserved example source.
if ($DownloadUri.Scheme -ne 'https' -or $DownloadUri.UserInfo -or
    $DownloadUri.DnsSafeHost -like '*.invalid') {
    throw 'Supply an approved HTTPS URL without embedded credentials; replace the example.'
}
# 2. Resolve the destination without creating or replacing an existing file.
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $destination) { throw 'Output already exists; choose a new file.' }
$parent = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Create the output directory first.' }
# 3. -WhatIf previews this action. The real request writes a temporary file first.
if ($PSCmdlet.ShouldProcess($destination, 'Download plugin archive (no import)')) {
    $temporary = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.partial')
    try {
        # Require a direct HTTPS download; do not follow an insecure redirect.
        Invoke-WebRequest -Uri $DownloadUri -OutFile $temporary -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
        if ((Get-Item -LiteralPath $temporary).Length -eq 0) { throw 'Downloaded archive is empty.' }
        # Publish the completed nonempty download under its requested filename.
        [IO.File]::Move($temporary, $destination)
        Write-Output "Downloaded archive. Validate through your approved import process before use."
    } catch {
        # Request exceptions can contain a token-bearing URL. Do not print it.
        throw 'Download failed. Check the approved direct HTTPS source, network, and output permissions privately.'
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
