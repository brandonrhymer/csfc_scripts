#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Release verification requires Windows PowerShell 5.1 Desktop edition.'
}
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path -Path $root -ChildPath 'release-manifest.txt'
$settingsPath = Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1'
$manifestEntries = @(Get-Content -LiteralPath $manifestPath | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })

if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [version]'3.4.0' })) {
    throw 'Pester 3.4.0 is required on this development workstation. This tool never downloads it.'
}
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object { $_.Version -eq [version]'1.25.0' })) {
    throw 'PSScriptAnalyzer 1.25.0 is required on this development workstation. This tool never downloads it.'
}

& (Join-Path $PSScriptRoot 'Test-ReleaseHashes.ps1') | Out-Null

$missing = @($manifestEntries | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf)
    })
if ($missing.Count -ne 0) {
    throw "Publication manifest files are missing: $($missing -join ', ')"
}

$powerShellFiles = @($manifestEntries | Where-Object {
        [IO.Path]::GetExtension($_) -in @('.ps1', '.psm1', '.psd1')
    })
$parseFailures = @()
foreach ($relativePath in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    $fullPath = Join-Path -Path $root -ChildPath $relativePath
    [Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($parseError in @($errors)) {
        $parseFailures += "$relativePath line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
}
if ($parseFailures.Count -ne 0) {
    throw "PowerShell parsing failed: $($parseFailures -join '; ')"
}

Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force -ErrorAction Stop
$findings = @($powerShellFiles | ForEach-Object {
        Invoke-ScriptAnalyzer -Path (Join-Path $root $_) -Settings $settingsPath
    })
if ($findings.Count -ne 0) {
    $summary = $findings | ForEach-Object {
        "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)"
    }
    throw "PSScriptAnalyzer failed: $($summary -join '; ')"
}

Import-Module Pester -RequiredVersion 3.4.0 -Force -ErrorAction Stop
$pesterResult = Invoke-Pester -Script (Join-Path $root 'tests') -PassThru
if ($pesterResult.TotalCount -eq 0 -or $pesterResult.FailedCount -ne 0 -or
    $pesterResult.PassedCount -ne $pesterResult.TotalCount) {
    throw 'Pester must discover tests and pass every test without failures, skips, or pending results.'
}

[pscustomobject]@{
    Status                   = 'Succeeded'
    ParserErrors             = 0
    PSScriptAnalyzerFindings = 0
    PesterTotal              = $pesterResult.TotalCount
    PesterPassed             = $pesterResult.PassedCount
    AdIntegrationTestsExecuted = $false
}
