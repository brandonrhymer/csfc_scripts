#requires -Version 5.1
<#
.SYNOPSIS
Read basic site-server status without changing configuration.
.DESCRIPTION
Run locally on your site server in Windows PowerShell. Missing roles may be on another host.
A running service or registered provider does not prove end-to-end health.
.EXAMPLE
C:\Admin\mecm\scripts\get-site-status.ps1
#>
[CmdletBinding()]
param()
# Each section is independent so an unavailable provider does not hide services.
Write-Output '--- Services on this computer ---'
Get-Service -Name SMS_EXECUTIVE, SMS_SITE_COMPONENT_MANAGER, MSSQLSERVER, WsusService, W3SVC `
    -ErrorAction Continue | Select-Object Name, Status
Write-Output '--- Registered SMS Providers ---'
try {
    Get-CimInstance -Namespace root\SMS -ClassName SMS_ProviderLocation -ErrorAction Stop |
        Select-Object Machine, SiteCode, ProviderForLocalSite
} catch {
    Write-Warning "Provider query failed: $($_.Exception.Message)"
}
Write-Output '--- Local WSUS setup record ---'
try {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup' -ErrorAction Stop |
        Select-Object ContentDir, SqlServerName, SqlDatabaseName, PortNumber, UsingSSL
} catch {
    Write-Warning "WSUS settings unavailable on this computer: $($_.Exception.Message)"
}
