#requires -Version 5.1
<#
.SYNOPSIS
Requests computer Group Policy refresh after an approved change.
.DESCRIPTION
Standalone offline Windows PowerShell 5.1 entry point for MECM Run Scripts.
Preview is the default and runs no native commands. Apply permits the request.
Native requests run once within a shared deadline; uncertain actions are not
retried. Read computer-policy-refresh.md before use. No live pilot has been completed.
.PARAMETER Mode
Preview describes the action. Apply permits the approved local request.
.PARAMETER TimeoutSeconds
Shared native execution budget, 60 by default; range 5 through 120 seconds.
#>
[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply')][string]$Mode = 'Preview',
    [ValidateRange(5, 120)][int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$clock = [Diagnostics.Stopwatch]::StartNew()

function Invoke-LocalCommand {
    param([ValidateSet('Refresh')][string]$Command)
    # This allowlist is the entire native command surface. Neither operator data
    # nor captured output is interpolated into a path or command-line argument.
    $commands = @{
        Refresh = @('gpupdate.exe', '/target:computer /wait:0')
    }
    $native = [pscustomobject]@{
        Command = $Command; Started = $false; Completed = $false
        TimedOut = $false; ExitCode = $null; Output = ''; ErrorCode = 'Startup'
        TerminationConfirmed = $false
    }
    $process = $null
    try {
        $remaining = [Math]::Max(0, [int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
        if ($remaining -eq 0) { $native.TimedOut = $true; $native.ErrorCode = 'Deadline'; return $native }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path ([Environment]::GetFolderPath('System')) $commands[$Command][0]
        $startInfo.Arguments = $commands[$Command][1]
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Native process did not start.' }
        $native.Started = $true
        # EOF prevents a native command from prompting on the unattended channel.
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $remaining = [Math]::Max(0, [int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
        if (-not $process.WaitForExit($remaining)) {
            $native.TimedOut = $true
            $native.ErrorCode = 'Deadline'
            $process.Kill()
            $native.TerminationConfirmed = $process.WaitForExit(2000)
            return $native
        }
        $native.Completed = $true
        $native.ExitCode = $process.ExitCode
        # Output drain shares a bounded two-second cleanup allowance.
        $drain = [Diagnostics.Stopwatch]::StartNew()
        if (-not $stdout.Wait(2000)) { $native.ErrorCode = 'OutputUnavailable'; return $native }
        $remainingDrain = [Math]::Max(0, 2000 - [int]$drain.ElapsedMilliseconds)
        if (-not $stderr.Wait($remainingDrain)) { $native.ErrorCode = 'OutputUnavailable'; return $native }
        if ([Text.Encoding]::UTF8.GetByteCount($stdout.Result) -gt 16384 -or
            [Text.Encoding]::UTF8.GetByteCount($stderr.Result) -gt 16384) {
            $native.ErrorCode = 'OutputLimit'
            return $native
        }
        # Stderr is deliberately not published: it can contain unrestricted
        # native diagnostics. Its presence does not override an explicit exit code.
        $native.Output = $stdout.Result
        $native.ErrorCode = 'None'
        return $native
    }
    catch {
        $native.ErrorCode = 'ProcessFailure'
        return $native
    }
    finally {
        if ($null -ne $process) {
            try {
                if ($native.Started -and -not $process.HasExited) {
                    $process.Kill()
                    $native.TerminationConfirmed = $process.WaitForExit(2000)
                }
            } catch { $native.TerminationConfirmed = $false }
            $process.Dispose()
        }
    }
}

function Assert-CommandResult {
    param($Value, [string]$Command)
    if ($null -eq $Value -or @($Value).Count -ne 1) { throw 'Invalid command result count.' }
    $fields = @('Command', 'Started', 'Completed', 'TimedOut', 'ExitCode', 'Output', 'ErrorCode', 'TerminationConfirmed')
    if (@($Value.PSObject.Properties).Count -ne $fields.Count) { throw 'Invalid command result shape.' }
    foreach ($field in $fields) { if ($null -eq $Value.PSObject.Properties[$field]) { throw 'Missing command result field.' } }
    if ($Value.Command -cne $Command) { throw 'Unexpected command identity.' }
    foreach ($flag in @('Started', 'Completed', 'TimedOut', 'TerminationConfirmed')) {
        if ($Value.$flag -isnot [bool]) { throw 'Invalid command result flag.' }
    }
    if ($null -ne $Value.ExitCode -and $Value.ExitCode -isnot [int]) { throw 'Invalid native exit code.' }
    if ($Value.Output -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($Value.Output) -gt 16384) { throw 'Invalid command output.' }
    if ($Value.ErrorCode -notin @('None', 'Startup', 'Deadline', 'OutputUnavailable', 'OutputLimit', 'ProcessFailure')) { throw 'Invalid command error code.' }
    if ($Value.Completed -and (-not $Value.Started -or $Value.TimedOut -or $null -eq $Value.ExitCode)) { throw 'Inconsistent completed command.' }
    if ($Value.ErrorCode -eq 'None' -and (-not $Value.Completed -or $Value.TimedOut)) { throw 'Inconsistent command success.' }
    if ($Value.TimedOut -and $Value.ErrorCode -notin @('Deadline', 'ProcessFailure')) { throw 'Inconsistent timeout result.' }
}

function Get-CompactEvidence {
    param([string]$Text)
    $value = ($Text -replace '[\x00-\x20\x7f]+', ' ').Trim()
    # Keep localized text as evidence, never parse it as proof of success.
    while ([Text.Encoding]::UTF8.GetByteCount($value) -gt 700) { $value = $value.Substring(0, $value.Length - 1) }
    return $value
}

$result = [ordered]@{
    Product = 'mecm-computer-policy-refresh'; Mode = $Mode; Status = 'Failed'
    Reason = 'Request did not complete; inspect before retry if Apply was selected.'
    Phase = 'Eligibility'; MutationAttempted = $false; CommandStarted = $false
    CommandCompleted = $false; RequestAccepted = $false; NativeExitCode = $null
    OutcomeUncertain = $false; TimedOut = $false; TerminationConfirmed = $false
    FollowUp = 'Review computer Group Policy events and resultant settings; arrange any required restart separately.'
    PolicyCompletionVerified = $false
}
$mutex = $null
$ownsMutex = $false
try {
    if ($Mode -eq 'Preview') {
        $result.Status = 'Skipped'
        $result.Reason = 'Preview only; would request computer policy refresh after an approved change.'
        return
    }
    $mutex = New-Object System.Threading.Mutex($false, 'Global\CSfC-Mecm-ComputerPolicyRefresh')
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        $result.Status = 'Skipped'
        $result.Reason = 'Another copy is active; no additional request was submitted.'
        return
    }
    $result.Phase = 'Request'
    $result.MutationAttempted = $true
    $result.RequestAccepted = $null
    $native = Invoke-LocalCommand 'Refresh'
    Assert-CommandResult $native 'Refresh'
    $result.CommandStarted = $native.Started
    $result.CommandCompleted = $native.Completed
    $result.NativeExitCode = $native.ExitCode
    $result.TimedOut = $native.TimedOut
    $result.TerminationConfirmed = $native.TerminationConfirmed
    if (-not $native.Started) {
        $result.RequestAccepted = $false
        $result.Reason = 'Native command did not start; no request was submitted. Inspect command availability and the deadline before repeating.'
        return
    }
    if ($native.ErrorCode -ne 'None' -or $native.ExitCode -ne 0) {
        $result.OutcomeUncertain = $true
        $result.Reason = 'Request command failed or timed out; effects may be partial or unknown. Inspect before any manual repeat.'
        return
    }
    $result.RequestAccepted = $true
    $result.Phase = 'RequestAccepted'
    $result.Status = 'Changed'
    $result.Reason = 'Computer policy refresh request accepted; processing can continue. Completion is unverified; review Group Policy events and any startup-only follow-up.'
}
catch {
    $result.Status = 'Failed'
    $result.OutcomeUncertain = $result.MutationAttempted
    $result.Reason = 'No trustworthy command result is available. Inspect the recorded phase before any manual repeat.'
}
finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
    $result.ElapsedMilliseconds = $clock.ElapsedMilliseconds
    $json = $result | ConvertTo-Json -Compress -Depth 3
    if ([Text.Encoding]::UTF8.GetByteCount($json) -ge 4096) {
        $result = [ordered]@{
            Product = 'mecm-computer-policy-refresh'; Mode = $Mode; Status = 'Failed'
            Reason = 'Result exceeded the reporting limit; inspect before retry.'
            OutcomeUncertain = $result.MutationAttempted; TimedOut = $result.TimedOut
        }
        $json = $result | ConvertTo-Json -Compress
    }
    $json
    if ($result.TimedOut) { exit 2 }
    if ($result.Status -eq 'Failed') { exit 1 }
    exit 0
}
