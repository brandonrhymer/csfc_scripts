#Requires -Version 5.1
# Isolated failure-evidence control flow. No operational module or entrypoint runs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Run this suite in a fresh Windows PowerShell 5.1 process.'
}

$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'windows/reset-krbtgt/KrbtgtRotation/KrbtgtRotation.psm1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The KRBTGT module has parser errors.' }
$writers = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Write-KrbtgtFailureEvidence'
}, $true))
if ($writers.Count -ne 1) { throw 'Expected one production failure-evidence writer.' }
$writer = $writers[0]

# Review every executable boundary before evaluating the extracted definition.
# Only Out-Null is a real command; all four helper calls below use local fakes.
$allowedCommands = @('Add-KrbtgtReceiptStage', 'Complete-KrbtgtReceipt', 'Out-Null',
    'Test-KrbtgtEventSourceRegistration', 'Write-KrbtgtEvent')
foreach ($command in @($writer.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
    if ($command.GetCommandName() -notin $allowedCommands -or
        $command.InvocationOperator.ToString() -ne 'Unknown' -or $command.Redirections.Count -ne 0) {
        throw 'The failure-evidence writer has an unreviewed command boundary; extend isolation before running it.'
    }
}
if (@($writer.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)).Count -ne 0) {
    throw 'The failure-evidence writer has an unreviewed method boundary; extend isolation before running it.'
}
if (@($writer.FindAll({ param($node) $node -is [Management.Automation.Language.RedirectionAst] }, $true)).Count -ne 0) {
    throw 'The failure-evidence writer has an unreviewed redirection boundary; extend isolation before running it.'
}

& {
    param($writerSource)
    . ([scriptblock]::Create($writerSource))

    # Mock contract failures are recorded separately from simulated exceptions so
    # a broken assertion cannot accidentally satisfy an expected failure case.
    function Assert-FakeArgument {
        param([bool]$Condition, [string]$Message)
        if (-not $Condition) { $script:failureEvidenceMockErrors += $Message }
    }
    function Add-KrbtgtReceiptStage {
        param($Receipt, $Name, $Status, $Summary, $Evidence)
        $script:failureEvidenceCalls += 'Stage'
        Assert-FakeArgument ($args.Count -eq 0 -and $PSBoundParameters.Count -eq 5) 'Stage argument set changed.'
        Assert-FakeArgument ([object]::ReferenceEquals($Receipt, $script:failureEvidenceReceipt)) 'Stage received a different receipt.'
        Assert-FakeArgument ($Name -ceq 'Failure') 'Stage name was not Failure.'
        Assert-FakeArgument ($Status -ceq 'Failed') 'Stage status was not Failed.'
        Assert-FakeArgument ($Summary -ceq $script:failureEvidenceOriginal.Exception.Message) 'Stage lost the original error message.'
        Assert-FakeArgument ($null -eq $Evidence) 'Stage received unexpected evidence.'
    }
    function Complete-KrbtgtReceipt {
        param($Receipt, $Status, $ErrorRecord)
        $script:failureEvidenceCalls += 'Receipt'
        Assert-FakeArgument ($args.Count -eq 0 -and $PSBoundParameters.Count -eq 3) 'Completion argument set changed.'
        Assert-FakeArgument ([object]::ReferenceEquals($Receipt, $script:failureEvidenceReceipt)) 'Completion received a different receipt.'
        Assert-FakeArgument ($Status -ceq 'Failed') 'Completion status was not Failed.'
        Assert-FakeArgument ([object]::ReferenceEquals($ErrorRecord, $script:failureEvidenceOriginal)) 'Completion lost the original ErrorRecord.'
        if ($script:failureEvidenceReceiptFails) { throw 'Synthetic receipt write failure.' }
        return 'Synthetic completion output must be discarded.'
    }
    function Test-KrbtgtEventSourceRegistration {
        param()
        $script:failureEvidenceCalls += 'Registration'
        Assert-FakeArgument ($args.Count -eq 0 -and $PSBoundParameters.Count -eq 0) 'Registration received unexpected arguments.'
        if ($script:failureEvidenceEventMode -ceq 'ProbeFailure') { throw 'Synthetic registration lookup failure.' }
        return ($script:failureEvidenceEventMode -cne 'Absent')
    }
    function Write-KrbtgtEvent {
        param($EventId, $EntryType, $Receipt, $Message)
        $script:failureEvidenceCalls += 'Event'
        Assert-FakeArgument ($args.Count -eq 0 -and $PSBoundParameters.Count -eq 4) 'Event argument set changed.'
        Assert-FakeArgument ($EventId -eq 1202) 'Event ID was not forwarded.'
        Assert-FakeArgument ($EntryType -ceq 'Error') 'Event type was not Error.'
        Assert-FakeArgument ([object]::ReferenceEquals($Receipt, $script:failureEvidenceReceipt)) 'Event received a different receipt.'
        Assert-FakeArgument ($Message -ceq $script:failureEvidenceOriginal.Exception.Message) 'Event lost the original operation error.'
        if ($script:failureEvidenceEventMode -ceq 'WriteFailure') { throw 'Synthetic event write failure.' }
    }

    $caseCount = 0
    foreach ($receiptFails in @($false, $true)) {
        foreach ($eventMode in @('Absent', 'Success', 'WriteFailure', 'ProbeFailure')) {
            $caseName = 'receiptFails={0}, event={1}' -f $receiptFails, $eventMode
            $script:failureEvidenceReceiptFails = $receiptFails
            $script:failureEvidenceEventMode = $eventMode
            $script:failureEvidenceMockErrors = @()
            $script:failureEvidenceCalls = @()
            $script:failureEvidenceReceipt = [pscustomobject]@{
                InvocationId = 'synthetic-invocation'; Phase = 'Test'; DirectoryMutationAttempted = $true
            }
            $script:failureEvidenceOriginal = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Synthetic original operation failure.'),
                'SyntheticOriginalFailure', [Management.Automation.ErrorCategory]::InvalidOperation, $null)
            $caught = $null
            $output = @()
            try {
                $output = @(Write-KrbtgtFailureEvidence -Receipt $script:failureEvidenceReceipt `
                    -ErrorRecord $script:failureEvidenceOriginal -EventId 1202)
            }
            catch { $caught = $_ }

            if ($script:failureEvidenceMockErrors.Count -ne 0) {
                throw "Case '$caseName' violated fake arguments: $($script:failureEvidenceMockErrors -join ' ')"
            }
            $expectedCalls = 'Stage,Receipt,Registration'
            if ($eventMode -in @('Success', 'WriteFailure')) { $expectedCalls += ',Event' }
            if (($script:failureEvidenceCalls -join ',') -cne $expectedCalls) {
                throw "Case '$caseName' crossed unexpected fake boundaries: $($script:failureEvidenceCalls -join ',')"
            }
            $expectedFailure = $null
            if ($receiptFails) { $expectedFailure = 'Synthetic receipt write failure.' }
            elseif ($eventMode -ceq 'WriteFailure') { $expectedFailure = 'Synthetic event write failure.' }
            elseif ($eventMode -ceq 'ProbeFailure') { $expectedFailure = 'Synthetic registration lookup failure.' }

            if ($expectedFailure) {
                $expectedMessage = "The operation failed and durable evidence could not be completed: $expectedFailure"
                if ($null -eq $caught -or $caught.Exception.Message -cne $expectedMessage) {
                    throw "Case '$caseName' did not preserve the expected evidence failure: $caught"
                }
            }
            elseif ($null -ne $caught) { throw "Case '$caseName' unexpectedly failed: $caught" }
            if ($output.Count -ne 0) { throw "Case '$caseName' returned unexpected output." }
            if ($script:failureEvidenceOriginal.Exception.Message -cne 'Synthetic original operation failure.' -or
                $script:failureEvidenceOriginal.FullyQualifiedErrorId -cne 'SyntheticOriginalFailure' -or
                -not $script:failureEvidenceReceipt.DirectoryMutationAttempted) {
                throw "Case '$caseName' altered the original error or mutation-attempt flag."
            }
            $caseCount++
            Write-Output "PASS: failure evidence / $caseName"
        }
    }
    if ($caseCount -ne 8) { throw 'Failure-evidence case count mismatch.' }
    Write-Output ('PASS: {0} KRBTGT failure-evidence cases; fake helpers only, no receipt or event writes.' -f $caseCount)
} $writer.Extent.Text
exit 0
