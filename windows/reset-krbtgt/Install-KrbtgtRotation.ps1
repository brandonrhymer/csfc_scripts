#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'KrbtgtRotation\KrbtgtRotation.psd1'
Import-Module $modulePath -Force -ErrorAction Stop

Install-KrbtgtRotationLocalSetup -WhatIf:$WhatIfPreference
