#requires -Version 5.1
<#
.SYNOPSIS
Export existing WSUS metadata and copy existing content to a new folder.
.DESCRIPTION
Run elevated locally on the connected WSUS server after its normal sync finishes.
Does not change WSUS settings, approvals, or jobs, and does not download updates.
The copy includes license files. It is not a Configuration Manager deployment package.
Only absolute local drive-letter paths using long directory names are supported.
UNC, mapped/SUBST/PowerShell drives, reparse points, and relative paths are rejected.
The destination parent must exist. Keep both trees protected from concurrent changes
throughout validation and export; path checks are not a lock on the filesystem.
.PARAMETER ContentPath
The actual WSUSContent folder on this server, with no reparse points in its tree.
.PARAMETER Destination
A new transfer folder in an existing parent, outside the WSUS content tree.
.EXAMPLE
.\wsus-export.ps1 -ContentPath 'D:\WSUS\WsusContent' -Destination 'F:\LAB-export' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ContentPath,
    [Parameter(Mandatory)][string]$Destination
)
$ErrorActionPreference = 'Stop'

function Get-WsusLiteralPath {
    param([string]$Value)
    # Do not let either PowerShell or Win32 reinterpret relative/provider/device syntax.
    if ($Value -notmatch '^[A-Za-z]:\\' -or $Value -match '[\x00-\x1f<>"/|?*\[\]]') {
        throw 'Use an absolute local drive-letter path with literal long directory names.'
    }
    $path = $Value.TrimEnd('\')
    if ($path.Length -lt 4) { throw 'A volume root is not a supported content or destination folder.' }
    foreach ($part in $path.Substring(3).Split('\')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part -match '[:. ]$|:' -or
            $part -match '^(CON|PRN|AUX|NUL|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])(?:\.|$)') {
            throw 'Path components must be literal directory names without dot segments, reserved names, or trailing dots/spaces.'
        }
    }
    return $path
}

$source = Get-WsusLiteralPath $ContentPath
$target = Get-WsusLiteralPath $Destination

# Native read-only queries distinguish physical local-volume names and long names.
# GetFullPath/string comparison alone cannot establish that two paths are separate.
if (-not ('CsfcWsusPathNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class CsfcWsusPathNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint QueryDosDevice(string name, StringBuilder target, int length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetLongPathName(string path, StringBuilder target, int length);
    public static string Device(string drive) {
        var result = new StringBuilder(32768);
        if (QueryDosDevice(drive, result, result.Capacity) == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return result.ToString();
    }
    public static string LongPath(string path) {
        var result = new StringBuilder(32768);
        uint size = GetLongPathName(path, result, result.Capacity);
        if (size == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (size >= result.Capacity) throw new InvalidOperationException("Path exceeds the supported length.");
        return result.ToString();
    }
}
'@
}

function Get-WsusLocalVolume {
    param([string]$Path)
    $letter = $Path.Substring(0, 1)
    $drive = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction Stop
    if ($drive.Root -ine ($letter + ':\') -or $drive.DisplayRoot) {
        throw 'PowerShell and mapped drive aliases are not supported; use the local volume drive letter.'
    }
    $device = [CsfcWsusPathNative]::Device($letter + ':')
    if ($device -notmatch '^\\Device\\HarddiskVolume[0-9]+$') {
        throw 'Only direct local disk volumes are supported; mapped and SUBST aliases are rejected.'
    }
    return $device
}

function Assert-WsusPlainDirectory {
    param([string]$Path)
    $current = $Path.Substring(0, 3)
    $components = @('') + $Path.Substring(3).Split('\')
    foreach ($component in $components) {
        if ($component) { $current = Join-Path $current $component }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) { throw 'Every existing path component must be a directory.' }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Reparse points, including junctions and mounted folders, are not supported.'
        }
        $longPath = [CsfcWsusPathNative]::LongPath($current).TrimEnd('\')
        if (-not $longPath.Equals($current.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Short-name aliases are not supported; use the actual long directory names.'
        }
    }
}

$sourceVolume = Get-WsusLocalVolume $source
$targetVolume = Get-WsusLocalVolume $target
Assert-WsusPlainDirectory $source
$targetParent = [IO.Path]::GetDirectoryName($target)
Assert-WsusPlainDirectory $targetParent

# Compare paths within the native volume, including two drive letters for one volume.
$sourceIdentity = $sourceVolume + $source.Substring(2)
$targetIdentity = $targetVolume + $target.Substring(2)
if ($targetIdentity.Equals($sourceIdentity, [StringComparison]::OrdinalIgnoreCase) -or
    $targetIdentity.StartsWith($sourceIdentity + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $sourceIdentity.StartsWith($targetIdentity + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source and destination must be separate directory trees.'
}
# Never overwrite an earlier transfer. A failed run keeps its folder for diagnosis.
$targetName = [IO.Path]::GetFileName($target)
$existing = @(Get-ChildItem -LiteralPath $targetParent -Force -ErrorAction Stop |
    Where-Object { $_.Name.Equals($targetName, [StringComparison]::OrdinalIgnoreCase) })
if ($existing.Count -or (Test-Path -LiteralPath $target)) {
    throw 'Destination already exists. Use a new transfer folder.'
}

# Inspect one directory at a time, rejecting a link before ever descending into it.
# /XJ remains a copy-time safeguard, but cannot substitute for an explicit inventory check.
$pending = New-Object 'System.Collections.Generic.Stack[string]'
$pending.Push($source)
while ($pending.Count) {
    foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'ContentPath contains a reparse point. Reconcile the source tree before export.'
        }
        if ($item.PSIsContainer) { $pending.Push($item.FullName) }
    }
}

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
