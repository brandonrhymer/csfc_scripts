# Synthetic harness shared only by these four request-wrapper checks.
# Never execute the production script unchanged, including Preview.
[CmdletBinding()]
param([ValidateSet('ComputerPolicyRefresh', 'DnsCacheFlush', 'TimeSync', 'DnsRegistration')][string]$Product)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$started = [Diagnostics.Stopwatch]::StartNew()
$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\client-maintenance\Invoke-Mecm' + $Product + '.ps1')))
$source = [IO.File]::ReadAllText($scriptPath)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
$nativeAst = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-LocalCommand' }, $true)
if ($null -eq $nativeAst) { throw 'Missing native helper.' }
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('csfc-os-request-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$powershell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
$cases = 0

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

function Invoke-Isolated {
    param([string]$Code, [int]$LimitSeconds = 20)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Fixture did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($LimitSeconds * 1000)) { throw 'Fixture exceeded its outer deadline.' }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) { throw 'Fixture output was unavailable.' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result; ErrorText = $stderr.Result }
    }
    finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(2000) | Out-Null }
        $process.Dispose()
    }
}

$mockTemplate = @'
function Invoke-LocalCommand {
    param([string]$Command)
    $log = '__LOG__'
    [IO.File]::AppendAllText($log, $Command + [Environment]::NewLine)
    $call = [IO.File]::ReadAllLines($log).Count
    $scenario = '__SCENARIO__'
    $value = [pscustomobject]@{
        Command = $Command; Started = $true; Completed = $true
        TimedOut = $false; ExitCode = 0; Output = 'Synthetic status: no synchronized state is asserted.'
        ErrorCode = 'None'; TerminationConfirmed = $false
    }
    if ($scenario -eq 'Throw') { throw 'Synthetic provider failure.' }
    if ($scenario -eq 'Fail' -or ($scenario -eq 'BeforeFail' -and $call -eq 1) -or ($scenario -eq 'ResyncFail' -and $call -eq 2) -or ($scenario -eq 'AfterFail' -and $call -eq 3)) {
        $value.ExitCode = 5
    }
    if ($scenario -eq 'Timeout' -or ($scenario -eq 'ResyncTimeout' -and $call -eq 2) -or ($scenario -eq 'AfterTimeout' -and $call -eq 3)) {
        $value.Completed = $false; $value.ExitCode = $null; $value.TimedOut = $true
        $value.ErrorCode = 'Deadline'; $value.TerminationConfirmed = $true
    }
    if ($scenario -eq 'Missing') { $value.Started = $false; $value.Completed = $false; $value.ExitCode = $null; $value.ErrorCode = 'Startup' }
    if ($scenario -eq 'WrongIdentity') { $value.Command = 'Unapproved' }
    if ($scenario -eq 'WrongFlag') { $value.Started = 'true' }
    if ($scenario -eq 'WrongExitType') { $value.ExitCode = '0' }
    if ($scenario -eq 'ExtraField') { $value | Add-Member NoteProperty Unexpected $true }
    if ($scenario -eq 'Duplicate') { $value }
    if ($scenario -eq 'Incomplete') { $value.Completed = $false }
    if ($scenario -eq 'HugeOutput') { $value.Output = 'x' * 17000 }
    if ($scenario -eq 'Localized') { $value.Output = [string][char]0x6642 + ' : synthetic; same before and after.' }
    if ($scenario -eq 'LongEvidence') { $value.Output = ('synthetic evidence ' * 200) }
    if ($scenario -eq 'EmptyBefore' -and $call -eq 1) { $value.Output = '' }
    if ($scenario -eq 'EmptyAfter' -and $call -eq 3) { $value.Output = '' }
    $value
}
'@

function Invoke-Case {
    param([string]$Name, [hashtable]$Parameters, [string]$ExpectedStatus, [int]$ExpectedCalls, [int]$ExpectedExit = 0)
    $log = Join-Path $fixtureRoot ($Name + '.calls')
    $mock = $mockTemplate.Replace('__LOG__', $log.Replace("'", "''")).Replace('__SCENARIO__', $Name)
    $copy = $source.Substring(0, $nativeAst.Extent.StartOffset) + $mock + $source.Substring($nativeAst.Extent.EndOffset)
    $copyPath = Join-Path $fixtureRoot ($Name + '.ps1')
    [IO.File]::WriteAllText($copyPath, $copy, (New-Object Text.UTF8Encoding($true)))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($Parameters)))
    $entry = '$global:LASTEXITCODE = 1; $p = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $encoded + '''))); & ''' + $copyPath.Replace("'", "''") + ''' @p; exit $LASTEXITCODE'
    $run = Invoke-Isolated $entry
    Assert-True ($run.ExitCode -eq $ExpectedExit) "$Product / $Name exit code $($run.ExitCode), expected $ExpectedExit. $($run.Output) $($run.ErrorText)"
    Assert-True ([Text.Encoding]::UTF8.GetByteCount($run.Output) -lt 4096) "$Name output exceeded 4KB."
    $lines = @($run.Output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($lines.Count -eq 1) "$Name did not return one JSON record."
    $value = $lines[0] | ConvertFrom-Json
    Assert-True ($value.Status -eq $ExpectedStatus) "$Name status $($value.Status), expected $ExpectedStatus. $($value.Reason)"
    $calls = @()
    if ([IO.File]::Exists($log)) { $calls = @([IO.File]::ReadAllLines($log)) }
    Assert-True ($calls.Count -eq $ExpectedCalls) "$Name made $($calls.Count) native calls, expected $ExpectedCalls."
    $allowed = switch ($Product) { 'ComputerPolicyRefresh' { @('Refresh') } 'DnsCacheFlush' { @('Flush') } 'TimeSync' { @('Status', 'Resync') } 'DnsRegistration' { @('Register') } }
    foreach ($call in $calls) { Assert-True ($call -in $allowed) "$Name invoked unapproved $call." }
    $mutations = @($calls | Where-Object { $_ -ne 'Status' })
    Assert-True ($mutations.Count -le 1) "$Name retried a mutation."
    if ($ExpectedCalls -eq 0) { Assert-True (-not $value.MutationAttempted -and -not $value.RequestAccepted) "$Name claimed a mutation." }
    if ($ExpectedStatus -eq 'Changed') { Assert-True ($value.RequestAccepted -and $value.CommandCompleted -and $value.NativeExitCode -eq 0) "$Name claimed success without accepted command." }
    if ($Product -eq 'TimeSync') { Assert-True (-not $value.SyncVerified) "$Name invented verified sync." }
    if ($Product -eq 'DnsRegistration') { Assert-True (-not $value.RegistrationVerified) "$Name invented verified DNS registration." }
    if ($Product -eq 'ComputerPolicyRefresh') { Assert-True (-not $value.PolicyCompletionVerified) "$Name invented completed policy." }
    if ($Product -eq 'DnsCacheFlush') { Assert-True (-not $value.UpstreamRecoveryVerified) "$Name invented upstream recovery." }
    $script:cases++
    return $value
}

function Invoke-NativeFixture {
    param([string]$Name, [string]$ChildCode, [string]$ExpectedError, [int]$ExpectedExit = 0, [int]$Budget = 5)
    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ChildCode))
    $nativeSource = $nativeAst.Extent.Text
    $oldPath = '$startInfo.FileName = Join-Path ([Environment]::GetFolderPath(''System'')) $commands[$Command][0]'
    $oldArguments = '$startInfo.Arguments = $commands[$Command][1]'
    Assert-True ($nativeSource.Contains($oldPath) -and $nativeSource.Contains($oldArguments)) 'Native seam changed; refuse to run real commands.'
    $fixtureExecutable = $powershell
    if ($Name -eq 'NativeMissing') { $fixtureExecutable = Join-Path $fixtureRoot 'synthetic-missing.exe' }
    $nativeSource = $nativeSource.Replace($oldPath, '$startInfo.FileName = ''' + $fixtureExecutable.Replace("'", "''") + '''')
    $nativeSource = $nativeSource.Replace($oldArguments, '$startInfo.Arguments = ''-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedChild + '''')
    $command = switch ($Product) { 'ComputerPolicyRefresh' { 'Refresh' } 'DnsCacheFlush' { 'Flush' } 'TimeSync' { 'Status' } 'DnsRegistration' { 'Register' } }
    $helperPath = Join-Path $fixtureRoot ($Name + '-helper.ps1')
    $helper = '$ErrorActionPreference = ''Stop''; Set-StrictMode -Version 2.0; $TimeoutSeconds = ' + $Budget + '; $clock = [Diagnostics.Stopwatch]::StartNew()' + [Environment]::NewLine + $nativeSource + [Environment]::NewLine + 'Invoke-LocalCommand ''' + $command + ''' | ConvertTo-Json -Compress'
    [IO.File]::WriteAllText($helperPath, $helper, (New-Object Text.UTF8Encoding($true)))
    $run = Invoke-Isolated ('& ''' + $helperPath.Replace("'", "''") + '''')
    Assert-True ($run.ExitCode -eq 0) "$Name helper fixture failed: $($run.ErrorText)"
    $value = $run.Output | ConvertFrom-Json
    Assert-True ($value.ErrorCode -eq $ExpectedError) "$Name error $($value.ErrorCode), expected $ExpectedError."
    if ($ExpectedError -eq 'None') { Assert-True ($value.Completed -and $value.ExitCode -eq $ExpectedExit) "$Name native exit protocol failed." }
    if ($ExpectedError -eq 'Deadline' -and $Budget -gt 0) { Assert-True ($value.TimedOut -and $value.TerminationConfirmed -and -not $value.Completed) "$Name did not confirm termination." }
    if ($Budget -eq 0 -or $Name -eq 'NativeMissing') { Assert-True (-not $value.Started -and -not $value.Completed) "$Name unexpectedly started a command." }
    $script:cases++
    return $value
}

try {
    # Static command surface must match the reviewed exact command strings.
    $expected = switch ($Product) {
        'ComputerPolicyRefresh' { "Refresh = @('gpupdate.exe', '/target:computer /wait:0')" }
        'DnsCacheFlush' { "Flush = @('ipconfig.exe', '/flushdns')" }
        'TimeSync' { "Status = @('w32tm.exe', '/query /status /verbose')"; "Resync = @('w32tm.exe', '/resync /nowait')" }
        'DnsRegistration' { "Register = @('ipconfig.exe', '/registerdns')" }
    }
    foreach ($line in $expected) { Assert-True ($nativeAst.Extent.Text.Contains($line)) "Unreviewed native command mapping: $line" }
    Assert-True (-not [regex]::IsMatch($source, '(?im)^\s*(Start-Service|Stop-Service|Restart-Service|Set-Service|Set-DnsClient|Clear-DnsClientCache|Register-DnsClient|Get-CimInstance|Invoke-CimMethod|Invoke-Expression|Restart-Computer|Stop-Computer)\b')) 'Unmocked operational command found.'
    $approved = @{ Mode = 'Apply' }
    if ($Product -eq 'DnsRegistration') { $approved.RegistrationOwnership = 'Client'; $approved.AllAdaptersApproved = 'Yes' }
    $preview = $approved.Clone(); $preview.Mode = 'Preview'
    Invoke-Case 'Default' @{} 'Skipped' 0 | Out-Null
    Invoke-Case 'Preview' $preview 'Skipped' 0 | Out-Null
    $held = New-Object Threading.Mutex($false, ('Global\CSfC-Mecm-' + $Product))
    $heldOwned = $false
    try {
        $heldOwned = $held.WaitOne(0)
        Assert-True $heldOwned 'Fixture could not acquire its product mutex.'
        Invoke-Case 'MutexHeld' $approved 'Skipped' 0 | Out-Null
    }
    finally { if ($heldOwned) { $held.ReleaseMutex() }; $held.Dispose() }
    $goodCalls = 1
    if ($Product -eq 'TimeSync') { $goodCalls = 3 }
    $success = Invoke-Case 'Success' $approved 'Changed' $goodCalls
    Invoke-Case 'Localized' $approved 'Changed' $goodCalls | Out-Null
    foreach ($scenario in @('Fail', 'Missing', 'Throw', 'WrongIdentity', 'WrongFlag', 'WrongExitType', 'ExtraField', 'Duplicate', 'Incomplete', 'HugeOutput')) {
        $failure = Invoke-Case $scenario $approved 'Failed' 1 1
        if ($Product -ne 'TimeSync' -and $scenario -ne 'Missing') { Assert-True $failure.OutcomeUncertain "$scenario concealed uncertainty." }
        if ($scenario -eq 'Missing') { Assert-True (-not $failure.OutcomeUncertain -and -not $failure.RequestAccepted) 'Missing executable claimed an uncertain submission.' }
    }
    $timeout = Invoke-Case 'Timeout' $approved 'Failed' 1 2
    Assert-True ($timeout.TimedOut -and $timeout.TerminationConfirmed) 'Timeout lost process evidence.'
    if ($Product -eq 'TimeSync') {
        Assert-True ($null -ne $success.BeforeStatus -and $null -ne $success.AfterStatus -and $null -ne $success.BeforeCapturedUtc -and $null -ne $success.AfterCapturedUtc) 'Missing time evidence.'
        foreach ($scenario in @('BeforeFail', 'EmptyBefore')) {
            $before = Invoke-Case $scenario $approved 'Failed' 1 1
            Assert-True (-not $before.MutationAttempted) "$scenario attempted resync without before evidence."
        }
        foreach ($scenario in @('AfterFail', 'EmptyAfter')) {
            $after = Invoke-Case $scenario $approved 'Failed' 3 1
            Assert-True ($after.RequestAccepted -and $after.OutcomeUncertain -and $after.Phase -eq 'AfterStatus') "$scenario hid accepted request."
        }
        $afterTimeout = Invoke-Case 'AfterTimeout' $approved 'Failed' 3 2
        Assert-True $afterTimeout.RequestAccepted 'After timeout hid accepted request.'
        $resyncFailure = Invoke-Case 'ResyncFail' $approved 'Failed' 2 1
        Assert-True ($resyncFailure.MutationAttempted -and $resyncFailure.OutcomeUncertain -and $null -eq $resyncFailure.RequestAccepted) 'Resync failure hid uncertainty.'
        $resyncTimeout = Invoke-Case 'ResyncTimeout' $approved 'Failed' 2 2
        Assert-True ($resyncTimeout.MutationAttempted -and $resyncTimeout.OutcomeUncertain -and $null -eq $resyncTimeout.RequestAccepted) 'Resync timeout hid uncertainty.'
        $long = Invoke-Case 'LongEvidence' $approved 'Changed' 3
        Assert-True $long.EvidenceTruncated 'Truncated evidence was not marked.'
    }
    if ($Product -eq 'DnsRegistration') {
        foreach ($ownership in @('Unknown', 'Dhcp', 'Other')) {
            $denied = $approved.Clone(); $denied.RegistrationOwnership = $ownership
            Invoke-Case ('Owner' + $ownership) $denied 'Skipped' 0 | Out-Null
        }
        $denied = $approved.Clone(); $denied.AllAdaptersApproved = 'No'
        Invoke-Case 'AllAdaptersNotApproved' $denied 'Skipped' 0 | Out-Null
    }
    # Parameter binding is exercised on mocked copies so accidental defaults can
    # never reach a real provider if a validation regression occurs.
    $invalidInputs = @(@{ Mode = 'Other' }, @{ TimeoutSeconds = 4 }, @{ TimeoutSeconds = 121 })
    if ($Product -eq 'DnsRegistration') { $invalidInputs += @{ RegistrationOwnership = 'Mixed' }; $invalidInputs += @{ AllAdaptersApproved = 'Maybe' } }
    foreach ($invalid in $invalidInputs) {
        $copyPath = Join-Path $fixtureRoot 'Default.ps1'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($invalid)))
        $run = Invoke-Isolated ('$global:LASTEXITCODE = 1; $p = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $encoded + '''))); & ''' + $copyPath.Replace("'", "''") + ''' @p; exit $LASTEXITCODE')
        Assert-True ($run.ExitCode -ne 0) 'Invalid parameter passed binding.'
        $cases++
    }
    Invoke-NativeFixture 'NativeSuccess' "[Console]::Out.Write('synthetic child'); exit 0" 'None' | Out-Null
    Invoke-NativeFixture 'NativeFailure' "[Console]::Error.Write('synthetic diagnostic'); exit 7" 'None' 7 | Out-Null
    Invoke-NativeFixture 'NativeOversize' "[Console]::Out.Write(('x' * 17000)); exit 0" 'OutputLimit' | Out-Null
    Invoke-NativeFixture 'NativeExpiredBudget' "throw 'Must not run'" 'Deadline' 0 0 | Out-Null
    Invoke-NativeFixture 'NativeMissing' "throw 'Must not run'" 'ProcessFailure' | Out-Null
    $pidPath = Join-Path $fixtureRoot 'owned-child.pid'
    $slow = '[IO.File]::WriteAllText(''' + $pidPath.Replace("'", "''") + ''', [string]$PID); Start-Sleep -Seconds 30'
    Invoke-NativeFixture 'NativeTimeout' $slow 'Deadline' | Out-Null
    Assert-True ([IO.File]::Exists($pidPath)) 'Owned timeout child never reached fixture code.'
    $childId = [int][IO.File]::ReadAllText($pidPath)
    $stillActive = $false
    try { $child = [Diagnostics.Process]::GetProcessById($childId); $stillActive = -not $child.HasExited; $child.Dispose() }
    catch [ArgumentException] { }
    Assert-True (-not $stillActive) 'Owned native timeout child survived termination.'
    Write-Output ("PASS {0}: {1} isolated synthetic checks in {2:N1}s; no operational providers executed." -f $Product, $cases, $started.Elapsed.TotalSeconds)
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'csfc-os-request-*') { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
