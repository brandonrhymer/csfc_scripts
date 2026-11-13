#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RootPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path -Parent $PSScriptRoot
}
$root = (Resolve-Path -LiteralPath $RootPath).Path
$hashPath = Join-Path -Path $root -ChildPath 'SHA256SUMS.txt'
$manifestPath = Join-Path -Path $root -ChildPath 'release-manifest.txt'
if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
    throw 'SHA256SUMS.txt is missing.'
}

$expected = @{}
foreach ($line in @(Get-Content -LiteralPath $hashPath)) {
    if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})  (?<path>.+)$') {
        throw "Unparseable SHA256SUMS line: '$line'"
    }
    $expected[$Matches.path] = $Matches.hash.ToLowerInvariant()
}

$manifestEntries = @(Get-Content -LiteralPath $manifestPath | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
$hashedEntries = @($manifestEntries | Where-Object { $_.Replace('\', '/') -ne 'SHA256SUMS.txt' })
$missing = @()
$mismatched = @()
foreach ($relativePath in $hashedEntries) {
    $normalized = $relativePath.Replace('\', '/')
    $fullPath = Join-Path -Path $root -ChildPath $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or -not $expected.ContainsKey($normalized)) {
        $missing += $normalized
        continue
    }
    $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected[$normalized]) {
        $mismatched += $normalized
    }
}

$normalizedManifest = @($hashedEntries | ForEach-Object { $_.Replace('\', '/') })
$unexpected = @($expected.Keys | Where-Object { $_ -notin $normalizedManifest })
if ($missing.Count -ne 0 -or $mismatched.Count -ne 0 -or $unexpected.Count -ne 0) {
    throw "Hash verification failed. Missing=$($missing -join ','); Mismatched=$($mismatched -join ','); Unexpected=$($unexpected -join ',')"
}

[pscustomobject]@{
    Status     = 'Succeeded'
    FileCount  = $manifestEntries.Count
    Missing    = 0
    Mismatched = 0
    Unexpected = 0
}
