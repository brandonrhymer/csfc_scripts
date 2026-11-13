#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Reset1', 'Reset2')]
    [string]$Phase,

    [Parameter(Mandatory)]
    [guid]$OperationId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Reset1ReceiptPath
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'KrbtgtRotation\KrbtgtRotation.psd1'
Import-Module $modulePath -Force -ErrorAction Stop

try {
    $parameters = @{
        Phase       = $Phase
        OperationId = $OperationId
        WhatIf      = $WhatIfPreference
        Confirm     = $false
    }
    if ($PSBoundParameters.ContainsKey('Reset1ReceiptPath')) {
        $parameters.Reset1ReceiptPath = $Reset1ReceiptPath
    }
    $receipt = Invoke-KrbtgtReset @parameters
    $receipt | Format-List Phase, Status, OperationId, InvocationId, DomainDnsRoot, ExecutionDc, CompletedUtc, ReceiptPath
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
