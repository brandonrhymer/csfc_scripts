#requires -Version 5.1
<#
.SYNOPSIS
Read MSI properties; optionally create a Configuration Manager application.
.DESCRIPTION
Windows only. Reads the MSI database without executing the installer.
Use a permanent UNC source with the MSI and its companion files. EXE unsupported.
Without -Create, only prints metadata. Creation requires the console's site drive.
Does not distribute content or deploy software. Review generated settings in console.
.PARAMETER MsiPath
Full UNC path to an MSI, for example \\files.example.invalid\software\Product\setup.msi.
.PARAMETER Create
Create the application and deployment type after reviewing the default preview.
.EXAMPLE
C:\Admin\mecm\scripts\add-msi-application.ps1 -MsiPath '\\files.example.invalid\software\Product\setup.msi'
.EXAMPLE
C:\Admin\mecm\scripts\add-msi-application.ps1 -MsiPath '\\files.example.invalid\software\Product\setup.msi' -Create -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [ValidatePattern('^[A-Za-z0-9]{3}$')][string]$SiteCode = 'LAB',
    [switch]$Create
)
$ErrorActionPreference = 'Stop'
if ($MsiPath -notmatch '^\\\\[^\\]+\\[^\\]+\\.+\.msi$') {
    throw 'Supply the full UNC path to an MSI on a permanent share.'
}
# .NET checks the file directly even when the current PowerShell drive is LAB:.
if (-not [IO.File]::Exists($MsiPath)) { throw 'MSI does not exist or is not readable.' }
$installer = $database = $view = $record = $null
$properties = @{}
try {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    # Zero opens the MSI database read-only. No install action is invoked.
    $database = $installer.OpenDatabase($MsiPath, 0)
    foreach ($property in 'ProductName', 'ProductVersion', 'Manufacturer', 'ProductCode') {
        $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$property'")
        $view.Execute()
        $record = $view.Fetch()
        $properties[$property] = if ($null -ne $record) { $record.StringData(1) } else { '' }
        if ($null -ne $record) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); $record = $null }
        $view.Close()
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
        $view = $null
    }
} finally {
    # Release file handles even when an MSI query fails.
    foreach ($comObject in @($record, $view, $database, $installer)) {
        if ($null -ne $comObject) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) }
    }
}
if (-not $properties.ProductName -or -not $properties.ProductVersion -or
    $properties.ProductCode -notmatch '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
    throw 'Required MSI identity fields are missing or invalid. Review this installer manually.'
}
$name = "$($properties.ProductName) $($properties.ProductVersion)"
[pscustomobject]@{
    ApplicationName = $name
    Publisher = $properties.Manufacturer
    Version = $properties.ProductVersion
    ProductCode = $properties.ProductCode
    Source = $MsiPath
}
if (-not $Create) { return }
if ((Get-Location).Drive.Name -ne $SiteCode -or (Get-Location).Provider.Name -ne 'CMSite') {
    throw "Open Connect via Windows PowerShell and select the $SiteCode site drive."
}
# Stop rather than editing an existing application or silently making duplicates.
if (@(Get-CMApplication -Name $name | Where-Object LocalizedDisplayName -EQ $name).Count -gt 0) {
    throw "Application already exists: $name. Review it in the console."
}
if ($PSCmdlet.ShouldProcess($name, 'Create application and MSI deployment type')) {
    $app = New-CMApplication -Name $name -SoftwareVersion $properties.ProductVersion `
        -Publisher $properties.Manufacturer
    # Let the supported MSI cmdlet import detection and installer details from the file.
    # ContentLocation is the MSI file path, not just its containing folder.
    try {
        Add-CMMsiDeploymentType -InputObject $app -DeploymentTypeName 'MSI' -ContentLocation $MsiPath
    } catch {
        throw "Application was created but its deployment type failed. Review '$name' in the console. $($_.Exception.Message)"
    }
}
