#requires -Version 5.1
<#
.SYNOPSIS
Create three empty starter device collections. Never deploys software.
.DESCRIPTION
Run from Connect via Windows PowerShell in the Configuration Manager console.
Existing collections are reported and left unchanged, including their membership.
New collections use manual refresh. Use Update Membership after rule changes.
Review and enable a refresh schedule before relying on query membership.
.PARAMETER LimitingCollectionId
Maximum membership scope. SMS00001 is the built-in All Systems collection.
.EXAMPLE
C:\Admin\mecm\scripts\create-collections.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z0-9]{3}$')][string]$SiteCode = 'LAB',
    [string]$LimitingCollectionId = 'SMS00001'
)
$ErrorActionPreference = 'Stop'
# The console connects the module and site drive for us. Do not guess a provider.
if ((Get-Location).Drive.Name -ne $SiteCode -or
    (Get-Location).Provider.Name -ne 'CMSite') {
    throw "Open Connect via Windows PowerShell and select the $SiteCode site drive."
}
if (-not (Get-CMDeviceCollection -Id $LimitingCollectionId -ErrorAction Stop)) {
    throw 'The limiting collection was not found.'
}
foreach ($purpose in 'Pilot', 'Servers', 'Workstations') {
    $name = "$SiteCode - $purpose"
    # Exact matching avoids treating a similar name as the requested collection.
    $existing = @(Get-CMDeviceCollection -Name $name | Where-Object Name -EQ $name)
    if ($existing.Count -gt 0) {
        Write-Warning "Already exists: $name. Review its members and deployments; no change made."
        continue
    }
    if ($PSCmdlet.ShouldProcess($name, 'Create empty device collection')) {
        New-CMDeviceCollection -Name $name -LimitingCollectionId $LimitingCollectionId `
            -RefreshType Manual -Comment 'Starter collection. Add reviewed membership rules.'
    }
}
