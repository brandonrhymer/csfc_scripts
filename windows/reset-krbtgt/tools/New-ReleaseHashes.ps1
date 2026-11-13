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
$resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
$outputPath = Join-Path -Path $resolvedRoot -ChildPath 'SHA256SUMS.txt'
$manifestPath = Join-Path -Path $resolvedRoot -ChildPath 'release-manifest.txt'
$manifestEntries = @(Get-Content -LiteralPath $manifestPath | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
$files = foreach ($relativePath in $manifestEntries) {
    if ($relativePath.Replace('\', '/') -eq 'SHA256SUMS.txt') {
        continue
    }
    $fullPath = Join-Path -Path $resolvedRoot -ChildPath $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Publication manifest file '$relativePath' is missing."
    }
    Get-Item -LiteralPath $fullPath
}
$files = @($files | Sort-Object FullName)

$lines = foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($resolvedRoot.Length).TrimStart('\').Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    '{0}  {1}' -f $hash, $relativePath
}

[IO.File]::WriteAllLines($outputPath, $lines, [Text.UTF8Encoding]::new($false))
Write-Output $outputPath
