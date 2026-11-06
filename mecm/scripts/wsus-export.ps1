#requires -Version 5.1
<#
.SYNOPSIS
Export existing WSUS metadata and copy existing content to a new folder.
.DESCRIPTION
Run elevated locally on the connected WSUS server after its normal sync finishes.
Does not change WSUS settings, approvals, or jobs, and does not download updates.
The copy includes license files. It is not a Configuration Manager deployment package.
.PARAMETER ContentPath
The actual WSUSContent folder on this server; obtain it from the WSUS owner.
.PARAMETER Destination
A new, empty transfer folder outside the WSUS content tree.
.EXAMPLE
.\wsus-export.ps1 -ContentPath 'D:\WSUS\WsusContent' -Destination 'F:\LAB-export' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ContentPath,
    [Parameter(Mandatory)][string]$Destination
)
$ErrorActionPreference = 'Stop'
# Normalize paths before checking for accidental copies into the source tree.
$source = (Get-Item -LiteralPath $ContentPath).FullName.TrimEnd('\')
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'ContentPath must be a folder.' }
$target = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($target.Equals($source, [StringComparison]::OrdinalIgnoreCase) -or
    $target.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $source.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source and destination must be separate directory trees.'
}
# Never overwrite an earlier transfer. A failed run keeps its folder for diagnosis.
if (Test-Path -LiteralPath $target) { throw 'Destination already exists. Use a new transfer folder.' }
$wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
if (-not (Test-Path -LiteralPath $wsusUtil -PathType Leaf)) { throw 'WsusUtil.exe was not found on this server.' }
if ($PSCmdlet.ShouldProcess($target, "Export metadata and copy existing content from $source")) {
    $null = New-Item -ItemType Directory -Path $target
    & $wsusUtil export (Join-Path $target 'metadata.xml.gz') (Join-Path $target 'export.log')
    if ($LASTEXITCODE -ne 0) { throw 'WSUS export failed. Review export.log; do not import this transfer.' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'metadata.xml.gz') -PathType Leaf)) {
        throw 'WSUS did not create the metadata file. Review export.log.'
    }
    # /E copies subfolders, /COPY:DAT excludes source ACLs, and retries are bounded.
    # Do not use /MIR or /PURGE: neither source nor prior destination files are deleted.
    & robocopy.exe $source (Join-Path $target 'WsusContent') /E /COPY:DAT /R:2 /W:2 /XJ "/LOG:$target\copy.log"
    if ($LASTEXITCODE -ge 8) { throw 'Content copy failed. Review copy.log; transfer is incomplete.' }
    Write-Output "Export finished: $target. Review both logs before transfer. Missing source content is not downloaded."
}
