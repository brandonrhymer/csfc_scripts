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
    Write-Warning 'Test is state-changing. It creates, resets, replicates, deletes, and verifies one disabled temporary user.'
    $receipt = Invoke-KrbtgtTest -OperationId $OperationId
    $receipt | Format-List Phase, Status, OperationId, InvocationId, DomainDnsRoot, ExecutionDc, CompletedUtc, ReceiptPath
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
