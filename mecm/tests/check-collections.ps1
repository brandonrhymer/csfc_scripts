# Isolated control-flow tests. No ConfigMgr module, site, or network is contacted.
# The fake commands below exist only in this script's scope.
$ErrorActionPreference = 'Stop'
$global:MecmTestCreated = @()
$global:MecmTestExisting = @()
$global:MecmTestSite = 'LAB'
function Get-Location { [pscustomobject]@{ Drive = @{Name=$global:MecmTestSite}; Provider = @{Name='CMSite'} } }
function Get-CMDeviceCollection {
    param($Id, $Name, $ErrorAction)
    if ($Id) { return [pscustomobject]@{Name='All Systems'} }
    if ($Name -in $global:MecmTestExisting) { return [pscustomobject]@{Name=$Name} }
}
function New-CMDeviceCollection {
    param($Name, $LimitingCollectionId, $RefreshType, $Comment)
    if ($RefreshType -ne 'Manual' -or $LimitingCollectionId -ne 'SMS00001') { throw 'Unexpected scope or refresh mode.' }
    $global:MecmTestCreated += $Name
}
$scriptPath = Join-Path $PSScriptRoot '..\scripts\create-collections.ps1'
& $scriptPath -WhatIf
if ($global:MecmTestCreated.Count -ne 0) { throw 'WhatIf created a collection.' }
Write-Output 'PASS: WhatIf makes no changes'
& $scriptPath
if (($global:MecmTestCreated -join ',') -ne 'LAB - Pilot,LAB - Servers,LAB - Workstations') { throw 'Unexpected starter collections.' }
Write-Output 'PASS: creates the three named collections'
$global:MecmTestExisting = $global:MecmTestCreated
$global:MecmTestCreated = @()
& $scriptPath -WarningAction SilentlyContinue
if ($global:MecmTestCreated.Count -ne 0) { throw 'Repeat run created duplicates.' }
Write-Output 'PASS: existing collections remain unchanged'
$global:MecmTestSite = 'OTHER'
$rejected = $false
try { & $scriptPath } catch { $rejected = $true }
if (-not $rejected) { throw 'Wrong site was accepted.' }
Write-Output 'PASS: wrong site is rejected'
