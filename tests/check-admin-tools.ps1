# Offline parser/helper checks. Never execute a deployment script's main body.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'windows') -Filter '*.ps1' -Recurse) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell parse failure: $($file.Name): $errors" }
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'windows/defender/Invoke-CSfCDefenderUpdate-MVP.ps1'), [ref]$tokens, [ref]$errors)
foreach ($name in @('ConvertTo-SignatureVersion', 'Get-DefinitionRecency', 'Get-TargetName')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $node) { throw "Missing helper: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
if ($null -ne (ConvertTo-SignatureVersion 'invalid')) { throw 'Invalid version accepted.' }
$reference = [datetimeoffset]'2026-01-03T00:00:00Z'
foreach ($case in @(@(23, 'Recent'), @(24, 'Aging'), @(48, 'Aging'), @(49, 'Stale'), @(-1, 'Unknown'))) {
    $result = Get-DefinitionRecency ($reference.AddHours(-$case[0]).ToString('o')) $reference 24 48
    if ($result.Result -ne $case[1]) { throw 'Recency boundary failed.' }
}
$path = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.txt')
try {
    Set-Content -LiteralPath $path -Value @('# Reserved synthetic input', 'HOST1.example.invalid', 'host1.example.invalid')
    if (@(Get-TargetName $path).Count -ne 1) { throw 'Target deduplication failed.' }
    Set-Content -LiteralPath $path -Value 'invalid target'
    $rejected = $false
    try { $null = Get-TargetName $path } catch { $rejected = $true }
    if (-not $rejected) { throw 'Malformed target accepted.' }
} finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
'PowerShell parsing and isolated Defender helper checks passed.'
