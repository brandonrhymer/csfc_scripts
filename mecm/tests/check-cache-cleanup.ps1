#requires -Version 5.1
# Fresh Windows PowerShell process only. Every provider is synthetic; the exact
# production worker/wrapper execute in real owned child processes. A fixture is
# injected into a disposable copy after the worker param block, never into source.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$sourcePath = Join-Path $PSScriptRoot '..\client-maintenance\Invoke-MecmCacheCleanup.ps1'
$source = [IO.File]::ReadAllText($sourcePath)
$fixtureProvider = Join-Path $PSScriptRoot 'cache-cleanup-fixture.ps1'
$fixtureParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $fixtureParent ('csfc-cache-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$script:Passes = 0
$old = 'DATE:' + [datetime]::UtcNow.AddDays(-90).ToString('o')
$fresh = 'DATE:' + [datetime]::UtcNow.AddDays(-1).ToString('o')
$future = 'DATE:' + [datetime]::UtcNow.AddDays(1).ToString('o')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function New-Entry {
    param([string]$Id = 'fixture-a')
    [pscustomobject]@{ CacheElementID = $Id; ContentID = 'synthetic-' + $Id; Location = 'C:\synthetic-cache\' + $Id
        ReferenceCount = 0; ContentSize = 100; LastReferenceTime = $old }
}
function New-Metadata {
    param([string]$Id = 'fixture-a')
    [pscustomobject]@{ CacheId = $Id; ContentId = 'synthetic-' + $Id; Location = 'C:\synthetic-cache\' + $Id
        ReferenceCount = 0; PersistInCache = 0; ContentComplete = 1; LastReferenced = $old }
}
function Invoke-Fixture {
    param([string]$Name, [object[]]$Entries = @((New-Entry)), [object[]]$Metadata = @((New-Metadata)),
          [string]$Mode = 'Apply', [string]$Fault = '', [string]$Race = '', [int]$RetentionDays = 30,
          [int]$TimeoutSeconds = 15)
    $configPath = Join-Path $fixture ($Name + '.json')
    $evidencePath = Join-Path $fixture ($Name + '-evidence.json')
    $scriptPath = Join-Path $fixture ($Name + '.ps1')
    @{ Entries = @($Entries); Metadata = @($Metadata); Fault = $Fault; Race = $Race; Evidence = $evidencePath } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Production script does not parse in Windows PowerShell 5.1'
    $workerAssignment = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$worker'
    }, $true)
    $workerBlock = $workerAssignment.Right.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockAst] }, $true)
    $insertion = $workerBlock.ParamBlock.Extent.EndOffset
    # Source is unchanged except a provider fixture in the worker's own scope.
    $fixtureLine = "`n. '" + $fixtureProvider.Replace("'", "''") + "' -ConfigurationPath '" + $configPath.Replace("'", "''") + "'`n"
    $instrumented = $source.Insert($insertion, $fixtureLine)
    # Protocol probes deliberately corrupt the worker response only. The parent
    # launcher, parsing, schema validation and output handling remain unchanged.
    switch ($Fault) {
        'OversizeResult' { $instrumented = $instrumented.Replace('return [pscustomobject]$result', '$result.Reason = ''x'' * 5000; return [pscustomobject]$result') }
        'MalformedResult' { $instrumented = $instrumented.Replace('return [pscustomobject]$result', 'return ''malformed-json''') }
        'WrongTypeResult' { $instrumented = $instrumented.Replace('return [pscustomobject]$result', '$result.RemovedCount = ''untrusted-value''; return [pscustomobject]$result') }
    }
    [IO.File]::WriteAllText($scriptPath, $instrumented, (New-Object Text.UTF8Encoding $false))
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& "$PSHOME\powershell.exe" -NoLogo -NoProfile -NonInteractive -File $scriptPath -Mode $Mode -RetentionDays $RetentionDays -TimeoutSeconds $TimeoutSeconds 2>&1)
    $code = $LASTEXITCODE
    $clock.Stop()
    $json = $output -join "`n"
    Assert-True ([Text.Encoding]::UTF8.GetByteCount($json) -lt 4096) "$Name exceeded MECM output budget"
    try { $result = $json | ConvertFrom-Json } catch { throw "${Name}: output was not one JSON result: $json" }
    $evidence = if (Test-Path -LiteralPath $evidencePath) { Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json } else { $null }
    [pscustomobject]@{ Result = $result; ExitCode = $code; Evidence = $evidence; Elapsed = $clock.Elapsed.TotalSeconds }
}
function Assert-Case {
    param([string]$Name, $Actual, [string]$Status, [string]$Reason, [int]$Calls, [int]$ExitCode = 0)
    Assert-True ($Actual.Result.Status -ceq $Status) "$Name status: $($Actual.Result.Status)"
    Assert-True ($Actual.Result.Reason -ceq $Reason) "$Name reason: $($Actual.Result.Reason)"
    Assert-True ($Actual.ExitCode -eq $ExitCode) "$Name exit: $($Actual.ExitCode)"
    $actualCalls = if ($null -eq $Actual.Evidence) { 0 } else { @($Actual.Evidence.Calls).Count }
    Assert-True ($actualCalls -eq $Calls) "$Name made $actualCalls deletion calls; expected $Calls"
    $script:Passes++
    Write-Output "PASS: $Name"
}

try {
    $preview = Invoke-Fixture -Name 'preview' -Mode Preview
    Assert-Case 'preview' $preview 'Skipped' 'PreviewOnly' 0
    Assert-True ($preview.Result.PlannedContentSize -eq 100 -and $preview.Result.RemovedContentSize -eq 0) 'Preview size accounting'
    Assert-True (-not $preview.Result.MayHaveChanged) 'Preview incorrectly reports changes'

    $applied = Invoke-Fixture -Name 'eligible'
    Assert-Case 'eligible' $applied 'Changed' 'EligibleContentRemoved' 1
    Assert-True ($applied.Result.RemovedCount -eq 1 -and $applied.Result.RemovedContentSize -eq 100) 'Confirmed removal accounting'
    Assert-True ($applied.Evidence.Reads -ge 3 -and $applied.Evidence.CimReads -ge 2) 'Missing fresh pre-delete or post-delete read'
    $repeat = Invoke-Fixture -Name 'repeat' -Entries @($applied.Evidence.Entries) -Metadata @($applied.Evidence.Metadata)
    Assert-Case 'repeat' $repeat 'Already correct' 'NoEligibleContent' 0
    $guidEntry = New-Entry '{11111111-1111-4111-8111-111111111111}'
    $guidMetadata = New-Metadata '11111111-1111-4111-8111-111111111111'
    $guidMetadata.ContentId = $guidEntry.ContentID; $guidMetadata.Location = $guidEntry.Location
    $guidCase = Invoke-Fixture -Name 'guid-representation' -Entries @($guidEntry) -Metadata @($guidMetadata)
    Assert-Case 'guid-representation' $guidCase 'Changed' 'EligibleContentRemoved' 1
    $guidDuplicate = $guidEntry.PSObject.Copy(); $guidDuplicate.CacheElementID = $guidMetadata.CacheId
    $duplicateCase = Invoke-Fixture -Name 'guid-alias-duplicate' -Entries @($guidEntry, $guidDuplicate) -Metadata @($guidMetadata)
    Assert-Case 'guid-alias-duplicate' $duplicateCase 'Skipped' 'UnknownMetadataRetained' 0

    foreach ($case in @('persistent-number', 'persistent-bool', 'referenced-com', 'referenced-wmi', 'incomplete', 'recent-com', 'recent-wmi')) {
        $entry = New-Entry; $metadata = New-Metadata
        switch ($case) {
            'persistent-number' { $metadata.PersistInCache = 1 }
            'persistent-bool' { $metadata.PersistInCache = $true }
            'referenced-com' { $entry.ReferenceCount = 1 }
            'referenced-wmi' { $metadata.ReferenceCount = 1 }
            'incomplete' { $metadata.ContentComplete = 0 }
            'recent-com' { $entry.LastReferenceTime = $fresh }
            'recent-wmi' { $metadata.LastReferenced = $fresh }
        }
        $actual = Invoke-Fixture -Name $case -Entries @($entry) -Metadata @($metadata)
        Assert-Case $case $actual 'Already correct' 'NoEligibleContent' 0
        Assert-True ($actual.Result.RetainedCount -eq 1) "$case not counted as retained"
    }
    foreach ($case in @('null-persist', 'invalid-persist', 'string-false', 'missing-persist', 'null-ref', 'negative-ref', 'null-size', 'fraction-size',
        'future-com', 'future-wmi', 'string-date', 'missing-wmi', 'duplicate-wmi', 'duplicate-com', 'wrong-identity', 'wrong-location', 'null-com-time')) {
        $entry = New-Entry; $metadata = New-Metadata
        $entries = @($entry); $metadataEntries = @($metadata)
        switch ($case) {
            'null-persist' { $metadata.PersistInCache = $null }
            'invalid-persist' { $metadata.PersistInCache = 2 }
            'string-false' { $metadata.PersistInCache = 'false' }
            'missing-persist' { $metadata.PSObject.Properties.Remove('PersistInCache') }
            'null-ref' { $entry.ReferenceCount = $null }
            'negative-ref' { $metadata.ReferenceCount = -1 }
            'null-size' { $entry.ContentSize = $null }
            'fraction-size' { $entry.ContentSize = 1.5 }
            'future-com' { $entry.LastReferenceTime = $future }
            'future-wmi' { $metadata.LastReferenced = $future }
            'string-date' { $entry.LastReferenceTime = '01/02/2020' }
            'missing-wmi' { $metadataEntries = @() }
            'duplicate-wmi' { $metadataEntries += $metadata }
            'duplicate-com' { $entries += $entry }
            'wrong-identity' { $metadata.ContentId = 'different' }
            'wrong-location' { $metadata.Location = 'C:\different' }
            'null-com-time' { $entry.LastReferenceTime = $null }
        }
        $actual = Invoke-Fixture -Name $case -Entries $entries -Metadata $metadataEntries
        Assert-Case $case $actual 'Skipped' 'UnknownMetadataRetained' 0
        Assert-True ($actual.Result.UnknownCount -gt 0) "$case not counted unknown"
    }
    foreach ($race in @('Referenced', 'WmiReferenced', 'Persistent', 'Fresh', 'OldTimestampChanged', 'Replace', 'Missing', 'Duplicate', 'Unknown')) {
        $actual = Invoke-Fixture -Name ('race-' + $race) -Race $race
        Assert-Case ('race-' + $race) $actual 'Skipped' 'EligibilityChanged' 0
        Assert-True ($actual.Result.ChangedBeforeDeleteCount -eq 1) "$race race not counted"
    }
    foreach ($fault in @('Provider', 'Enumeration', 'Cim', 'Revalidation', 'Delete', 'Verify', 'NoOp', 'MetadataNoOp')) {
        $actual = Invoke-Fixture -Name ('failure-' + $fault) -Fault $fault
        $reason = switch ($fault) {
            'Revalidation' { 'RevalidationFailed' }; 'Delete' { 'DeletionFailed' }
            'Verify' { 'VerificationFailed' }; 'NoOp' { 'DeletionNotConfirmed' }; 'MetadataNoOp' { 'DeletionNotConfirmed' }; default { 'InspectionFailed' }
        }
        $calls = if ($fault -in @('Delete', 'Verify', 'NoOp', 'MetadataNoOp')) { 1 } else { 0 }
        Assert-Case ('failure-' + $fault) $actual 'Failed' $reason $calls 1
        Assert-True ($actual.Result.OutcomeUncertain -eq ($calls -gt 0)) "$fault uncertainty mismatch"
        Assert-True ($actual.Result.RemovedCount -eq 0) "$fault falsely claimed removal"
    }
    $partial = Invoke-Fixture -Name 'partial' -Entries @((New-Entry 'a'), (New-Entry 'b')) -Metadata @((New-Metadata 'a'), (New-Metadata 'b')) -Fault SecondDelete
    Assert-Case 'partial' $partial 'Failed' 'DeletionFailed' 2 1
    Assert-True ($partial.Result.RemovedCount -eq 1 -and $partial.Result.RemovedContentSize -eq 100 -and $partial.Result.OutcomeUncertain) 'Partial result lost confirmed changes'
    foreach ($fault in @('Noise', 'OversizeResult', 'MalformedResult', 'WrongTypeResult')) {
        $actual = Invoke-Fixture -Name ('protocol-' + $fault) -Fault $fault
        Assert-Case ('protocol-' + $fault) $actual 'Failed' 'WorkerFailed' 1 1
        Assert-True ($actual.Result.OutcomeUncertain -and $null -eq $actual.Result.RemovedCount) "$fault failed to report unknown effects"
        Assert-True ($actual.Elapsed -lt 15) "$fault blocked output pipe"
    }

    foreach ($case in @('invalid-mode', 'invalid-retention', 'invalid-timeout')) {
        $options = @{ Name = $case }
        switch ($case) { 'invalid-mode' { $options.Mode = 'anything' }; 'invalid-retention' { $options.RetentionDays = 0 }; 'invalid-timeout' { $options.TimeoutSeconds = 121 } }
        $actual = Invoke-Fixture @options
        Assert-Case $case $actual 'Failed' 'InvalidParameter' 0 2
        Assert-True ($null -eq $actual.Evidence) "$case started a provider worker"
    }
    foreach ($mode in @('Preview', 'Apply')) {
        $actual = Invoke-Fixture -Name ('timeout-' + $mode) -Mode $mode -Fault HangInspection -TimeoutSeconds 5
        Assert-Case ('timeout-' + $mode) $actual 'Failed' 'WorkerTimeout' 0 1
        Assert-True ($actual.Elapsed -lt 15) "$mode timeout did not bound a real child process"
        Assert-True ($null -eq $actual.Result.RemovedCount) "$mode timeout claimed known counts"
        Assert-True ($actual.Result.OutcomeUncertain -eq ($mode -eq 'Apply')) "$mode timeout uncertainty mismatch"
        Assert-True ($null -eq (Get-Process -Id $actual.Evidence.WorkerPid -ErrorAction SilentlyContinue)) "$mode timed-out worker is still running"
    }
    $hanging = Invoke-Fixture -Name 'timeout-deletion' -Fault HangDelete -TimeoutSeconds 5
    Assert-Case 'timeout-deletion' $hanging 'Failed' 'WorkerTimeout' 1 1
    Assert-True ($hanging.Elapsed -lt 15 -and $hanging.Result.OutcomeUncertain -and $null -eq $hanging.Result.RemovedCount) 'Deletion timeout outcome was misrepresented'
    Assert-True ($null -eq (Get-Process -Id $hanging.Evidence.WorkerPid -ErrorAction SilentlyContinue)) 'Timed-out mutation worker remains running'

    # Anti-regression source checks supplement behavioral tests; no cache path is
    # handed to a filesystem deletion or a force/persistent override API.
    Assert-True ($source -notmatch '(?i)Remove-Item|Remove-CimInstance|Remove-WmiObject|DeleteCacheElementEx|\[IO\.(File|Directory)\]::Delete') 'Forbidden deletion fallback present'
    Write-Output "Cache cleanup checks passed: $script:Passes cases; synthetic providers only."
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ne $fixtureParent -or [IO.Path]::GetFileName($resolved) -notlike 'csfc-cache-test-*') {
        throw 'Refusing fixture cleanup outside its verified temporary parent.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
exit 0
