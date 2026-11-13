#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$OperationId
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'KrbtgtRotation\KrbtgtRotation.psd1'
Import-Module $modulePath -Force -ErrorAction Stop

try {
    $receipt = Invoke-KrbtgtPreflight -OperationId $OperationId
    $receipt | Format-List Phase, Status, OperationId, InvocationId, DomainDnsRoot, ExecutionDc, CompletedUtc, ReceiptPath
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
