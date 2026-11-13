# Windows PowerShell 5.1 synthetic process/control-flow tests. No MECM client is
# queried: each temporary script's worker receives local provider substitutions.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\client-maintenance\Invoke-MecmCcmEval.ps1'))
$source = [IO.File]::ReadAllText($scriptPath)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
$assignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$worker' }, $true)
$workerAst = $assignment.Right.Find({ param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true).ScriptBlock
$insertion = $workerAst.ParamBlock.Extent.EndOffset
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('csfc-ccmeval-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$cases = 0

$providers = {
    if ($fixture.Scenario -eq 'NoisyOutput') { Write-Output 'synthetic unexpected stdout' }
    if ($fixture.Scenario -in @('LongReason', 'UnknownStatus', 'ExtraField', 'MalformedResult')) {
        $bad = [ordered]@{ Kind = 'Result'; Product = 'mecm-ccmeval'; Mode = $Mode; Status = 'Skipped'; Reason = 'synthetic'; ProposedAction = 'None'; EnabledByScript = $false; StartRequested = $false; MutationAttempted = $false; LastRunUtc = $null; LastTaskResult = $null; OverdueHours = $OverdueHours; Phase = 'Inspect' }
        if ($fixture.Scenario -eq 'LongReason') { $bad.Reason = 'x' * 5000 }
        if ($fixture.Scenario -eq 'UnknownStatus') { $bad.Status = 'Everything is fine' }
        if ($fixture.Scenario -eq 'ExtraField') { $bad.Unexpected = 'extra' }
        if ($fixture.Scenario -eq 'MalformedResult') { $bad.Remove('Status') }
        $bad | ConvertTo-Json -Compress
        return
    }
    $global:ReadCount = 0
    $global:Enabled = $false
    function Write-Trace { param([string]$Text) [IO.File]::AppendAllText($fixture.TracePath, ($Text + [Environment]::NewLine)) }
    function Get-ScheduledTask {
        param($ErrorAction)
        $global:ReadCount++
        Write-Trace 'read'
        if ($fixture.Scenario -eq 'ProviderFailure') { throw 'synthetic provider failure' }
        if ($fixture.Scenario -eq 'Hang') { Start-Sleep -Seconds 30 }
        if ($fixture.Scenario -eq 'Missing') { return }
        if ($fixture.Scenario -eq 'Disappear' -and $global:ReadCount -gt 1) { return }
        if ($fixture.Scenario -eq 'HangAfterEnable' -and $global:ReadCount -gt 2) { Start-Sleep -Seconds 30 }
        $state = 'Ready'
        if ($fixture.Scenario -in @('Disabled', 'EnableFailure', 'EnableStartFailure', 'EnableRace', 'EnableNoEffect', 'HangAfterEnable', 'RecentDisabled') -and -not $global:Enabled) { $state = 'Disabled' }
        if ($fixture.Scenario -eq 'Running' -or ($fixture.Scenario -eq 'RaceActive' -and $global:ReadCount -gt 1) -or ($fixture.Scenario -eq 'EnableRace' -and $global:ReadCount -gt 2)) { $state = 'Running' }
        if ($fixture.Scenario -eq 'Queued') { $state = 'Queued' }
        if ($fixture.Scenario -eq 'UnknownState') { $state = 'Unknown' }
        $action = Join-Path $env:windir 'CCM\CcmEval.exe'
        if ($fixture.Scenario -eq 'WrongAction') { $action = Join-Path $env:windir 'System32\cmd.exe' }
        $arguments = ''
        if ($fixture.Scenario -eq 'Arguments') { $arguments = '/unexpected' }
        $principal = 'SYSTEM'
        if ($fixture.Scenario -eq 'WrongPrincipal') { $principal = 'SYNTHETIC\operator' }
        $policy = 'IgnoreNew'
        if ($fixture.Scenario -in @('Parallel', 'Queue', 'StopExisting', 'UnknownPolicy')) { $policy = $fixture.Scenario }
        if ($fixture.Scenario -eq 'RacePolicy' -and $global:ReadCount -gt 1) { $policy = 'Parallel' }
        $enabled = $state -ne 'Disabled'
        if ($fixture.Scenario -eq 'Inconsistent') { $enabled = $false }
        $demand = $fixture.Scenario -ne 'DemandDisabled'
        if ($fixture.Scenario -eq 'UnknownDemand') { $demand = $null }
        if ($fixture.Scenario -eq 'UnknownEnabled') { $enabled = 'true' }
        [pscustomobject]@{
            TaskName = 'Configuration Manager Health Evaluation'; TaskPath = '\Microsoft\Configuration Manager\'
            State = $state; Settings = [pscustomobject]@{ Enabled = $enabled; AllowDemandStart = $demand; MultipleInstances = $policy }
            Principal = [pscustomobject]@{ UserId = $principal }
            Actions = @([pscustomobject]@{ Execute = $action; Arguments = $arguments; WorkingDirectory = '' })
        }
    }
    function Get-ScheduledTaskInfo {
        param($TaskName, $TaskPath, $ErrorAction)
        if ($TaskName -ne 'Configuration Manager Health Evaluation' -or $TaskPath -ne '\Microsoft\Configuration Manager\') { throw 'Wrong task requested.' }
        $last = [datetime]::Now.AddHours(-96)
        if ($fixture.Scenario -in @('Recent', 'RecentDisabled') -or ($fixture.Scenario -eq 'RaceRecent' -and $global:ReadCount -gt 1) -or [IO.File]::Exists($fixture.StartedPath)) { $last = [datetime]::Now.AddMinutes(-5) }
        if ($fixture.Scenario -eq 'Future') { $last = [datetime]::Now.AddHours(1) }
        if ($fixture.Scenario -in @('Never', 'SentinelMismatch')) { $last = [datetime]'1899-12-30' }
        if ($fixture.Scenario -in @('NeverMin', 'MinMismatch')) { $last = [datetime]::MinValue }
        if ($fixture.Scenario -eq 'Never1999') { $last = [datetime]'1999-11-30' }
        if ($fixture.Scenario -eq 'Malformed1899') { $last = [datetime]'1899-04-01' }
        if ($fixture.Scenario -eq 'InvalidLastRun') { $last = 'unreadable' }
        if ($fixture.Scenario -eq 'OldUnknown') { $last = [datetime]'1990-01-01' }
        $result = 0
        if ($fixture.Scenario -in @('Never', 'NeverMin', 'Never1999', 'InconsistentNever')) { $result = 0x00041303 }
        if ($fixture.Scenario -eq 'UnknownResult') { $result = $null }
        if ($fixture.Scenario -eq 'RunningResult') { $result = 0x00041301 }
        [pscustomobject]@{ LastRunTime = $last; LastTaskResult = $result }
    }
    function Enable-ScheduledTask {
        param($TaskName, $TaskPath, $ErrorAction)
        if ($TaskName -ne 'Configuration Manager Health Evaluation' -or $TaskPath -ne '\Microsoft\Configuration Manager\') { throw 'Wrong task enabled.' }
        Write-Trace 'enable'
        if ($fixture.Scenario -eq 'EnableFailure') { throw 'synthetic enable failure' }
        if ($fixture.Scenario -ne 'EnableNoEffect') { $global:Enabled = $true }
    }
    function Start-ScheduledTask {
        param($TaskName, $TaskPath, $ErrorAction)
        if ($TaskName -ne 'Configuration Manager Health Evaluation' -or $TaskPath -ne '\Microsoft\Configuration Manager\') { throw 'Wrong task started.' }
        Write-Trace 'start'
        if ($fixture.Scenario -in @('StartFailure', 'EnableStartFailure')) { throw 'synthetic start failure' }
        [IO.File]::WriteAllText($fixture.StartedPath, 'synthetic started')
        if ($fixture.Scenario -eq 'HangStart') { Start-Sleep -Seconds 30 }
    }
    function Test-Path {
        param($LiteralPath, $PathType)
        if ($LiteralPath -ne (Join-Path $env:windir 'CCM\CcmEval.exe') -or $PathType -ne 'Leaf') { throw 'Unexpected file probe.' }
        return $fixture.Scenario -ne 'MissingExecutable'
    }
    function Register-ScheduledTask { throw 'Forbidden task registration.' }
    function Set-ScheduledTask { throw 'Forbidden task definition change.' }
    function Restart-Service { throw 'Forbidden service restart.' }
    function Start-Service { throw 'Forbidden direct service start.' }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function New-Fixture {
    param([string]$Scenario)
    $id = [guid]::NewGuid().ToString('N')
    $fixture = @{ Scenario = $Scenario; TracePath = (Join-Path $fixtureRoot ($id + '.trace')); StartedPath = (Join-Path $fixtureRoot ($id + '.started')) }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($fixture | ConvertTo-Json -Compress)))
    $header = [Environment]::NewLine + '$fixture = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $encoded + ''')) | ConvertFrom-Json' + [Environment]::NewLine + $providers.ToString() + [Environment]::NewLine
    $copy = $source.Insert($insertion, $header)
    if ($Scenario -eq 'BlockStdin') {
        # Exercise the real parent deadline when its child never consumes input.
        $copy = $copy.Replace('$entry = ''$source = [Console]::In.ReadToEnd(); & ([scriptblock]::Create($source))''', '$entry = ''Start-Sleep -Seconds 30''')
        if ($copy -notmatch '\$entry = ''Start-Sleep -Seconds 30''') { throw 'Could not create stdin-stall fixture.' }
    }
    $path = Join-Path $fixtureRoot ($id + '.ps1')
    [IO.File]::WriteAllText($path, $copy, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path = $path; TracePath = $fixture.TracePath }
}
function Invoke-Case {
    param([string]$Scenario, [string]$Status, [string]$Mode = 'Apply', [string]$EnableDisabled = 'No', [int]$ExpectedStarts = 0, [int]$ExpectedEnables = 0, [int]$ExitCode = 0, [int]$TimeoutSeconds = 15)
    $fixture = New-Fixture $Scenario
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& $fixture.Path -Mode $Mode -EnableDisabled $EnableDisabled -TimeoutSeconds $TimeoutSeconds)
    $actualExit = $LASTEXITCODE
    $watch.Stop()
    Assert-True ($actualExit -eq $ExitCode) "$Scenario exit $actualExit, expected $ExitCode. $output"
    Assert-True ($output.Count -eq 1) "$Scenario returned multiple output records."
    $json = [string]$output[0]
    Assert-True ([Text.Encoding]::UTF8.GetByteCount($json) -lt 4096) "$Scenario output exceeded 4KB."
    $result = $json | ConvertFrom-Json
    Assert-True ($result.Status -eq $Status) "$Scenario status $($result.Status), expected $Status. $json"
    $trace = @()
    if ([IO.File]::Exists($fixture.TracePath)) { $trace = @([IO.File]::ReadAllLines($fixture.TracePath)) }
    Assert-True (@($trace | Where-Object { $_ -eq 'start' }).Count -eq $ExpectedStarts) "$Scenario unexpected start count."
    Assert-True (@($trace | Where-Object { $_ -eq 'enable' }).Count -eq $ExpectedEnables) "$Scenario unexpected enable count."
    if ($ExitCode -eq 2) {
        Assert-True $result.TimedOut "$Scenario did not report timeout."
        Assert-True ($watch.Elapsed.TotalSeconds -lt ($TimeoutSeconds + 12)) "$Scenario exceeded bounded timeout cleanup."
        Assert-True $result.OutcomeUncertain "$Scenario hid uncertain Apply effects."
    }
    $script:cases++
    Write-Host ("PASS: CcmEval {0} ({1})" -f $Scenario, $Mode)
    return [pscustomobject]@{ Result = $result; Fixture = $fixture; Trace = $trace }
}

try {
    $defaultFixture = New-Fixture 'Overdue'
    $defaultOutput = @(& $defaultFixture.Path -TimeoutSeconds 15)
    Assert-True ($LASTEXITCODE -eq 0 -and (($defaultOutput[0] | ConvertFrom-Json).Mode -eq 'Preview')) 'Omitted Mode was not Preview.'
    Assert-True (@([IO.File]::ReadAllLines($defaultFixture.TracePath) | Where-Object { $_ -in @('enable', 'start') }).Count -eq 0) 'Default mode changed a task.'
    $cases++; Write-Host 'PASS: CcmEval defaults to preview'
    $preview = Invoke-Case 'Overdue' 'Skipped' 'Preview'
    Assert-True ($preview.Result.ProposedAction -eq 'Start existing task') 'Preview omitted planned start.'
    $disabledPreview = Invoke-Case 'Disabled' 'Skipped' 'Preview' 'Yes'
    Assert-True ($disabledPreview.Result.ProposedAction -eq 'Enable and start existing task') 'Preview omitted planned enable.'
    $applied = Invoke-Case 'Overdue' 'Changed' -ExpectedStarts 1
    Assert-True $applied.Result.StartRequested 'Accepted request not reported.'
    $repeatOutput = @(& $applied.Fixture.Path -Mode Apply -TimeoutSeconds 15)
    Assert-True ($LASTEXITCODE -eq 0 -and (($repeatOutput[0] | ConvertFrom-Json).Status -eq 'Already correct')) 'Repeated run was not safely current.'
    Assert-True (@([IO.File]::ReadAllLines($applied.Fixture.TracePath) | Where-Object { $_ -eq 'start' }).Count -eq 1) 'Repeated run submitted another start.'
    $cases++; Write-Host 'PASS: CcmEval repeated apply is current'
    $null = Invoke-Case 'Recent' 'Already correct'
    $null = Invoke-Case 'RecentDisabled' 'Skipped' -EnableDisabled Yes
    $null = Invoke-Case 'Disabled' 'Skipped'
    $enabled = Invoke-Case 'Disabled' 'Changed' -EnableDisabled Yes -ExpectedStarts 1 -ExpectedEnables 1
    Assert-True $enabled.Result.EnabledByScript 'Enable was not reported.'
    $null = Invoke-Case 'Never' 'Changed' -ExpectedStarts 1
    $null = Invoke-Case 'NeverMin' 'Changed' -ExpectedStarts 1
    $null = Invoke-Case 'Never1999' 'Changed' -ExpectedStarts 1
    foreach ($scenario in @('Missing', 'Running', 'Queued', 'UnknownState', 'Inconsistent', 'Future', 'OldUnknown', 'WrongAction', 'WrongPrincipal', 'Arguments', 'MissingExecutable', 'DemandDisabled', 'Parallel', 'Queue', 'StopExisting', 'UnknownPolicy', 'RacePolicy', 'RaceActive', 'Disappear')) {
        $null = Invoke-Case $scenario 'Skipped'
    }
    $null = Invoke-Case 'RaceRecent' 'Already correct'
    foreach ($scenario in @('SentinelMismatch', 'MinMismatch', 'Malformed1899', 'InconsistentNever', 'UnknownResult', 'RunningResult')) { $null = Invoke-Case $scenario 'Skipped' }
    $null = Invoke-Case 'UnknownDemand' 'Skipped'
    $null = Invoke-Case 'UnknownEnabled' 'Skipped'
    $null = Invoke-Case 'InvalidLastRun' 'Skipped'
    $null = Invoke-Case 'ProviderFailure' 'Failed' -ExitCode 1
    $failure = Invoke-Case 'StartFailure' 'Failed' -ExpectedStarts 1 -ExitCode 1
    Assert-True $failure.Result.OutcomeUncertain 'Start failure concealed uncertainty.'
    $failure = Invoke-Case 'EnableFailure' 'Failed' -EnableDisabled Yes -ExpectedEnables 1 -ExitCode 1
    Assert-True $failure.Result.OutcomeUncertain 'Enable failure concealed uncertainty.'
    $partial = Invoke-Case 'EnableStartFailure' 'Failed' -EnableDisabled Yes -ExpectedEnables 1 -ExpectedStarts 1 -ExitCode 1
    Assert-True $partial.Result.EnabledByScript 'Partial enable was not reported.'
    $null = Invoke-Case 'EnableRace' 'Changed' -EnableDisabled Yes -ExpectedEnables 1
    $null = Invoke-Case 'EnableNoEffect' 'Failed' -EnableDisabled Yes -ExpectedEnables 1 -ExitCode 1
    $null = Invoke-Case 'Hang' 'Failed' -ExitCode 2 -TimeoutSeconds 5
    $null = Invoke-Case 'HangAfterEnable' 'Failed' -EnableDisabled Yes -ExpectedEnables 1 -ExitCode 2 -TimeoutSeconds 5
    $null = Invoke-Case 'HangStart' 'Failed' -ExpectedStarts 1 -ExitCode 2 -TimeoutSeconds 5
    $null = Invoke-Case 'BlockStdin' 'Failed' -ExitCode 2 -TimeoutSeconds 5
    foreach ($scenario in @('LongReason', 'UnknownStatus', 'ExtraField', 'MalformedResult')) { $null = Invoke-Case $scenario 'Failed' -ExitCode 1 }
    $noise = Invoke-Case 'NoisyOutput' 'Failed' -ExpectedStarts 1 -ExitCode 1
    Assert-True $noise.Result.OutcomeUncertain 'Invalid worker output concealed possible mutation.'
    $mutex = New-Object System.Threading.Mutex($false, 'Global\CSfC-Mecm-CcmEval')
    $held = $mutex.WaitOne(0)
    Assert-True $held 'Could not hold synthetic concurrency guard.'
    try {
        $overlap = Invoke-Case 'Overdue' 'Skipped'
        Assert-True ($overlap.Trace.Count -eq 0) 'Overlap reached task provider.'
    }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }

    foreach ($parameters in @(@{ Mode = 'Invalid' }, @{ EnableDisabled = 'Maybe' }, @{ OverdueHours = 0 }, @{ OverdueHours = 8761 }, @{ TimeoutSeconds = 4 }, @{ TimeoutSeconds = 121 })) {
        $fixture = New-Fixture 'Overdue'
        $rejected = $false
        try { & $fixture.Path @parameters | Out-Null } catch { $rejected = $true }
        Assert-True $rejected 'Invalid parameter was accepted.'
        Assert-True (-not [IO.File]::Exists($fixture.TracePath)) 'Invalid parameter reached a provider.'
        $cases++
    }
    Write-Host 'PASS: CcmEval rejects six invalid parameter cases before launching providers'
    Write-Output ("PASS: {0} CcmEval synthetic cases; actual isolated child-process and timeout paths exercised." -f $cases)
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('csfc-ccmeval-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
exit 0
