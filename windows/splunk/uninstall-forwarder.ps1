#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Uninstall registered Splunk Universal Forwarder MSI products on this computer.
.NOTES
Derived from uninstall.ps1. Preview with -WhatIf. A successful MSI exit does
not verify that forwarding has been migrated or that all product data is gone.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()
$ErrorActionPreference = 'Stop'
# 1. Inspect both registry views without invoking Win32_Product repair behavior.
$paths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '^(Splunk\s+)?Universal\s*Forwarder(?:\s|$)' })
if ($apps.Count -eq 0) { Write-Output 'Splunk Universal Forwarder not found.'; return }
# 2. Require a real MSI product-code GUID; never run arbitrary uninstall strings.
foreach ($app in $apps) {
    $productCode = $app.PSChildName
    if ($productCode -notmatch '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
        throw 'Matching product has no valid MSI product code; refusing to uninstall.'
    }
    # -WhatIf previews each matching product without stopping or uninstalling it.
    if ($PSCmdlet.ShouldProcess($app.DisplayName, 'Stop forwarding and uninstall')) {
        # A subsequent MSI failure may leave forwarding stopped. No blind retry.
        $service = Get-Service -Name 'SplunkForwarder' -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Stopped') { Stop-Service -InputObject $service -ErrorAction Stop }
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/X $productCode /qn /norestart" -Wait -PassThru
        # 3010 requests a later restart; /norestart prevents this script doing it.
        if ($process.ExitCode -notin @(0, 3010)) { throw "MSI uninstall failed with exit code $($process.ExitCode); forwarding may be stopped." }
        Write-Output "Uninstaller exit code: $($process.ExitCode). Verify removal separately."
    }
}
