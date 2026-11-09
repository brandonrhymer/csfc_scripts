#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Install a locally staged Splunk Universal Forwarder MSI on this computer.
.PARAMETER MsiPath
Path to the locally staged, separately approved Universal Forwarder MSI.
.PARAMETER ReceivingIndexer
Approved receiver in hostname:port form. This is not a target-computer inventory.
.PARAMETER DeploymentServer
Approved deployment server in hostname:port form.
.PARAMETER AcceptLicense
Explicit acknowledgement that the operator has reviewed and accepted the license.
.NOTES
Derived from exec.ps1. Its unused Computers loop ran repeated local installs;
this script deliberately installs once locally. It does not provide remoting.
Use an approved package and confirm its signature/hash before execution.
Endpoint examples: indexer.example.invalid:9997 and deployment.example.invalid:8089.
These are reserved placeholders. Supply approved values at runtime, outside Git.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$MsiPath,
    [Parameter(Mandatory = $true)][string]$ReceivingIndexer,
    [Parameter(Mandatory = $true)][string]$DeploymentServer,
    [Parameter(Mandatory = $true)][switch]$AcceptLicense
)
# Fail visibly rather than continuing after a preparation or installer error.
$ErrorActionPreference = 'Stop'
if (-not $AcceptLicense) { throw 'Read the product license and explicitly accept it before installation.' }
# 1. Validate endpoints before any installer process can start.
foreach ($endpoint in @($ReceivingIndexer, $DeploymentServer)) {
    if ($endpoint -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*:[0-9]{1,5}$' -or
        $endpoint -match '(?i)\.invalid:' -or [int]($endpoint.Split(':')[-1]) -notin 1..65535) {
        throw 'Supply a hostname:port endpoint with port 1-65535; replace reserved examples.'
    }
}
# 2. Resolve the existing MSI. Trust/hash approval is a separate prerequisite.
$package = Get-Item -LiteralPath $MsiPath -ErrorAction Stop
if ($package.PSIsContainer -or $package.Extension -ne '.msi' -or $package.FullName.Contains('"')) {
    throw 'Supply a local MSI file with no quote characters in its path.'
}
# 3. -WhatIf stops at preview. A confirmed execution acts only on this computer.
if ($PSCmdlet.ShouldProcess('this computer', 'Install Splunk Universal Forwarder')) {
    # Quote each path/value for Windows Installer and suppress automatic restart.
    $arguments = '/i "{0}" AGREETOLICENSE=Yes RECEIVING_INDEXER="{1}" DEPLOYMENT_SERVER="{2}" /quiet /norestart' -f
        $package.FullName, $ReceivingIndexer, $DeploymentServer
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    # 3010 is success with restart required; coordinate the restart separately.
    if ($process.ExitCode -notin @(0, 3010)) { throw "MSI installation failed with exit code $($process.ExitCode)." }
    Write-Output "Installer exit code: $($process.ExitCode). Verify forwarding and service status separately."
}
