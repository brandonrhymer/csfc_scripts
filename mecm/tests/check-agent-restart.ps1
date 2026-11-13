#requires -Version 5.1
# Run in a fresh Windows PowerShell 5.1 process. Synthetic owned children only.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'service-task-policy-check-fixture.ps1') -Product agent-restart
exit 0
