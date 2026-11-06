#Requires -Version 5.1
<#
.SYNOPSIS
Download a Nessus plugin archive from an operator-supplied approved HTTPS source.
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
$ErrorActionPreference = 'Stop'
if ($DownloadUri.Scheme -ne 'https' -or $DownloadUri.UserInfo -or
    $DownloadUri.DnsSafeHost -like '*.invalid') {
    throw 'Supply an approved HTTPS URL without embedded credentials; replace the example.'
}
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $destination) { throw 'Output already exists; choose a new file.' }
$parent = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Create the output directory first.' }
if ($PSCmdlet.ShouldProcess($destination, 'Download plugin archive (no import)')) {
    $temporary = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.partial')
    try {
        Invoke-WebRequest -Uri $DownloadUri -OutFile $temporary -UseBasicParsing -ErrorAction Stop
        if ((Get-Item -LiteralPath $temporary).Length -eq 0) { throw 'Downloaded archive is empty.' }
        [IO.File]::Move($temporary, $destination)
        Write-Output "Downloaded archive. Validate through your approved import process before use."
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
