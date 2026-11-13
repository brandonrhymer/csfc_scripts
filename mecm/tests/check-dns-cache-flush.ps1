#requires -Version 5.1
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'os-request-fixture.ps1') -Product 'DnsCacheFlush'
