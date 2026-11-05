
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$MapPath
)

function New-ObfuscationState {
    [PSCustomObject]@{
        IPMap     = @{}
        HostMap   = @{}
        NextIP    = 1
        NextHost  = 1
    }
}

function Get-ObfuscatedValue {
    param(
        [hashtable]$Map,
        [string]$Original,
        [string]$Prefix,
        [ref]$Counter
    )

    if ($Map.ContainsKey($Original)) {
        return $Map[$Original]
    }

    $token = "{0}{1:0000}" -f $Prefix, $Counter.Value
    $Map[$Original] = $token
    $Counter.Value++

    return $token
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Input file not found: $Path"
}

if (-not $OutputPath) {
    $dir  = [System.IO.Path]::GetDirectoryName($Path)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext  = [System.IO.Path]::GetExtension($Path)
    if (-not $ext) { $ext = '.txt' }
    $OutputPath = Join-Path $dir "$name.obfuscated$ext"
}

if (-not $MapPath) {
    $MapPath = "$OutputPath.map.xml"
}

if (Test-Path -LiteralPath $MapPath) {
    $state = Import-Clixml -LiteralPath $MapPath
} else {
    $state = New-ObfuscationState
}

if (-not ($state.IPMap -is [hashtable]))   { $state.IPMap = @{} }
if (-not ($state.HostMap -is [hashtable])) { $state.HostMap = @{} }

$content = Get-Content -LiteralPath $Path -Raw

$ipv4Pattern  = '(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
$hostPattern  = '\b(?:(?:[A-Za-z0-9-]{1,63})\.)+(?:[A-Za-z]{2,63})\b'

$ipMatches = [regex]::Matches($content, $ipv4Pattern) |
    Select-Object -ExpandProperty Value -Unique

foreach ($original in $ipMatches) {
    $replacement = Get-ObfuscatedValue -Map $state.IPMap -Original $original -Prefix 'IP_' -Counter ([ref]$state.NextIP)
    $content = $content -replace [regex]::Escape($original), $replacement
}

$hostMatches = [regex]::Matches($content, $hostPattern) |
    Select-Object -ExpandProperty Value -Unique

foreach ($original in $hostMatches) {
    $replacement = Get-ObfuscatedValue -Map $state.HostMap -Original $original -Prefix 'HOST_' -Counter ([ref]$state.NextHost)
    $content = $content -replace [regex]::Escape($original), $replacement
}

Set-Content -LiteralPath $OutputPath -Value $content -NoNewline
$state | Export-Clixml -LiteralPath $MapPath

Write-Host "Obfuscation complete."
Write-Host "  Input : $Path"
Write-Host "  Output: $OutputPath"
Write-Host "  Map   : $MapPath"
