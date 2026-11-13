#requires -Version 5.1
<#
.SYNOPSIS
Previews or starts the existing overdue Configuration Manager health evaluation task.
.DESCRIPTION
Runs locally, offline, without prompts. Preview is the default. Apply never creates
a task and enables an existing disabled task only with EnableDisabled Yes. A start
request does not establish client health. See ccmeval.md before pilot use.
.PARAMETER Mode
Preview reports the proposed action. Apply permits an eligible task start.
.PARAMETER EnableDisabled
No preserves a disabled task. Yes permits enabling it only when overdue in Apply.
.PARAMETER OverdueHours
Minimum hours since the last run; 72 by default. A never-run task is overdue.
.PARAMETER TimeoutSeconds
Worker budget in seconds, including provider calls. Default 60; range 5 to 120.
#>
[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply')][string]$Mode = 'Preview',
    [ValidateSet('No', 'Yes')][string]$EnableDisabled = 'No',
    [ValidateRange(1, 8760)][int]$OverdueHours = 72,
    [ValidateRange(5, 120)][int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
# Keep all provider operations inside the owned child process. The parent can
# terminate its worker even when a task provider call does not return.
$worker = {
    param([string]$Mode, [string]$EnableDisabled, [int]$OverdueHours)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 2.0
    $taskName = 'Configuration Manager Health Evaluation'
    $taskPath = '\Microsoft\Configuration Manager\'
    $phase = 'Inspect'
    $enabledByScript = $false
    $mutationAttempted = $false
    $lastRunUtc = $null
    $lastTaskResult = $null
    $script:lastRunUtc = $null
    $script:lastTaskResult = $null
    $mutex = $null
    $ownsMutex = $false

    function Send-Result {
        param([string]$Status, [string]$Reason, [string]$ProposedAction = 'None', [bool]$StartRequested = $false)
        [ordered]@{
            Kind = 'Result'; Product = 'mecm-ccmeval'; Mode = $Mode
            Status = $Status; Reason = $Reason; ProposedAction = $ProposedAction
            EnabledByScript = $enabledByScript; StartRequested = $StartRequested
            MutationAttempted = $mutationAttempted; LastRunUtc = $lastRunUtc
            LastTaskResult = $lastTaskResult; OverdueHours = $OverdueHours
            Phase = $phase
        } | ConvertTo-Json -Compress
    }
    function Send-Progress {
        [ordered]@{ Kind = 'Progress'; Phase = $phase; EnabledByScript = $enabledByScript; MutationAttempted = $mutationAttempted } | ConvertTo-Json -Compress
    }
    function Read-Task {
        # Enumerating avoids treating access/provider errors as a missing task.
        $found = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskName -eq $taskName -and $_.TaskPath -eq $taskPath
        })
        if ($found.Count -gt 1) { throw 'Ambiguous task identity.' }
        if ($found.Count -eq 0) { return $null }
        return $found[0]
    }
    function Test-Identity {
        param($Task)
        $actions = @($Task.Actions)
        if ($actions.Count -ne 1 -or $null -eq $actions[0]) { return $false }
        if ([string]$Task.Principal.UserId -notin @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')) { return $false }
        if (-not [string]::IsNullOrWhiteSpace([string]$actions[0].Arguments)) { return $false }
        $expected = [IO.Path]::GetFullPath((Join-Path $env:windir 'CCM\CcmEval.exe'))
        $execute = [Environment]::ExpandEnvironmentVariables([string]$actions[0].Execute).Trim()
        if ($execute.StartsWith('"') -and $execute.EndsWith('"')) { $execute = $execute.Substring(1, $execute.Length - 2) }
        if (-not [IO.Path]::IsPathRooted($execute) -or [IO.Path]::GetFullPath($execute) -ine $expected) { return $false }
        $workingDirectory = [Environment]::ExpandEnvironmentVariables([string]$actions[0].WorkingDirectory).Trim()
        if ($workingDirectory -and [IO.Path]::GetFullPath($workingDirectory).TrimEnd('\') -ine [IO.Path]::GetDirectoryName($expected)) { return $false }
        return (Test-Path -LiteralPath $expected -PathType Leaf)
    }
    function Read-Eligibility {
        param($Task)
        if (-not (Test-Identity $Task)) { return 'UnexpectedTaskDefinition' }
        $state = [string]$Task.State
        if ($state -in @('Running', 'Queued')) { return 'Active' }
        if ($state -notin @('Ready', 'Disabled')) { return 'UnknownTaskState' }
        if ($Task.Settings.Enabled -isnot [bool]) { return 'UnknownEnabledState' }
        if (($state -eq 'Disabled') -eq $Task.Settings.Enabled) { return 'InconsistentTaskState' }
        $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        if ($null -eq $info -or $info.LastRunTime -isnot [datetime]) { return 'UnknownLastRun' }
        $script:lastRunUtc = $null
        $script:lastTaskResult = $null
        # These assignments target the worker's script scope; the main body reads
        # the result object below instead of relying on provider text.
        $stamp = $info.LastRunTime
        $now = [datetime]::Now
        if ($stamp -gt $now.AddMinutes(5)) { return 'FutureLastRun' }
        if ($stamp.Year -ge 2000) {
            $script:lastRunUtc = $stamp.ToUniversalTime().ToString('o')
        }
        $parsedResult = [long]0
        if (-not [long]::TryParse([string]$info.LastTaskResult, [ref]$parsedResult) -or $parsedResult -lt [int]::MinValue -or $parsedResult -gt [uint32]::MaxValue) { return 'UnknownLastResult' }
        $script:lastTaskResult = $parsedResult
        # A pre-2000 timestamp alone is not proof of never-run. Require the
        # documented SCHED_S_TASK_HAS_NOT_RUN result (0x00041303) as well.
        if ($stamp.Year -lt 2000 -and $parsedResult -ne 0x00041303) { return 'UnknownLastRun' }
        if ($stamp.Year -ge 2000 -and $parsedResult -eq 0x00041303) { return 'InconsistentLastRun' }
        if ($parsedResult -eq 0x00041301) { return 'InconsistentRunningResult' }
        if ($stamp.Year -ge 2000 -and ($now - $stamp).TotalHours -lt $OverdueHours) {
            if ($state -eq 'Disabled') { return 'RecentDisabled' }
            return 'Recent'
        }
        if ($Task.Settings.AllowDemandStart -isnot [bool]) { return 'UnknownDemandStartState' }
        if (-not $Task.Settings.AllowDemandStart) { return 'DemandStartDisabled' }
        if ([string]$Task.Settings.MultipleInstances -ne 'IgnoreNew') { return 'UnsafeMultipleInstancesPolicy' }
        if ($state -eq 'Disabled') { return 'OverdueDisabled' }
        return 'OverdueReady'
    }
    function Report-Ineligible {
        param([string]$Eligibility)
        switch ($Eligibility) {
            'Recent' { Send-Result 'Already correct' 'Task ran within the selected interval; client health is not assessed.' }
            'RecentDisabled' { Send-Result 'Skipped' 'Task is disabled but ran recently; it is not overdue, so no enable or start was requested.' }
            'Active' { Send-Result 'Skipped' 'Task is running or queued; no additional start requested.' }
            'OverdueDisabled' { Send-Result 'Skipped' 'Task is overdue and disabled; EnableDisabled Yes is required.' }
            default { Send-Result 'Skipped' ('Task cannot be safely selected: ' + $Eligibility + '.') }
        }
    }
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\CSfC-Mecm-CcmEval')
        try { $ownsMutex = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { Send-Result 'Skipped' 'Another copy of this script is active; no task change was attempted.'; return }
        $task = Read-Task
        if ($null -eq $task) { Send-Result 'Skipped' 'Existing CcmEval task is missing; no task was created.'; return }
        $eligibility = Read-Eligibility $task
        $lastRunUtc = $script:lastRunUtc
        $lastTaskResult = $script:lastTaskResult
        $approvedDisabled = $eligibility -eq 'OverdueDisabled' -and $EnableDisabled -eq 'Yes'
        if ($eligibility -ne 'OverdueReady' -and -not $approvedDisabled) { Report-Ineligible $eligibility; return }
        $action = 'Start existing task'
        if ($approvedDisabled) { $action = 'Enable and start existing task' }
        if ($Mode -eq 'Preview') { Send-Result 'Skipped' 'Preview only; task is overdue and eligible.' $action; return }

        # A fresh read narrows the race with normal scheduled runs or policy changes.
        $phase = 'Recheck'
        $task = Read-Task
        if ($null -eq $task) { Send-Result 'Skipped' 'Task disappeared before apply; no task was created.'; return }
        $eligibility = Read-Eligibility $task
        $lastRunUtc = $script:lastRunUtc
        $lastTaskResult = $script:lastTaskResult
        if ($eligibility -eq 'OverdueDisabled' -and $EnableDisabled -eq 'Yes') {
            $phase = 'Enable'
            $mutationAttempted = $true
            Send-Progress
            Enable-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop | Out-Null
            $enabledByScript = $true
            Send-Progress
            $phase = 'RecheckAfterEnable'
            $task = Read-Task
            if ($null -eq $task) { Send-Result 'Failed' 'Enable returned successfully but task disappeared; inspect before retry.'; return }
            $eligibility = Read-Eligibility $task
            $lastRunUtc = $script:lastRunUtc
            $lastTaskResult = $script:lastTaskResult
            if ($eligibility -in @('Active', 'Recent')) {
                Send-Result 'Changed' 'Task enabled; another run became active or recent, so no start was requested.'
                return
            }
            if ($eligibility -ne 'OverdueReady') {
                Send-Result 'Failed' ('Task enabled but cannot be safely started: ' + $eligibility + '; inspect before retry.')
                return
            }
        }
        elseif ($eligibility -ne 'OverdueReady') { Report-Ineligible $eligibility; return }

        $phase = 'Start'
        $mutationAttempted = $true
        Send-Progress
        Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop | Out-Null
        $phase = 'StartAccepted'
        Send-Result 'Changed' 'Task Scheduler accepted the start request; completion and client health are not verified.' 'None' $true
    }
    catch {
        $reason = 'Task provider or task metadata failed; no further action was attempted.'
        if ($mutationAttempted) { $reason = 'A task change was attempted; its final outcome may be partial or unknown. Inspect the task and CcmEval.log before retry.' }
        Send-Result 'Failed' $reason
    }
    finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

$result = [ordered]@{
    Product = 'mecm-ccmeval'; Mode = $Mode; Status = 'Failed'
    Reason = 'Worker could not complete; inspect the task before retry if Apply was selected.'
    Phase = 'WorkerStartup'; EnabledByScript = $false; StartRequested = $false
    MutationAttempted = $false; OutcomeUncertain = $false; OverdueHours = $OverdueHours
}
$process = $null
$timedOut = $false
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    $parameters = @{ Mode = $Mode; EnableDisabled = $EnableDisabled; OverdueHours = $OverdueHours }
    $serialized = [Management.Automation.PSSerializer]::Serialize($parameters)
    $encodedParameters = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serialized))
    # Operator parameters are serialized data, never PowerShell source.
    $childSource = '$parameters = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $encodedParameters + '''))); & {' + [Environment]::NewLine + $worker.ToString() + [Environment]::NewLine + '} @parameters'
    $entry = '$source = [Console]::In.ReadToEnd(); & ([scriptblock]::Create($source))'
    $encodedEntry = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($entry))
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedEntry
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Worker did not start.' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    # Input transfer shares the worker deadline. AutoFlush ensures Close cannot
    # perform a new blocking flush after a completed write; never close a writer
    # with a pending write until its owned process has been terminated.
    $process.StandardInput.AutoFlush = $true
    $write = $process.StandardInput.WriteAsync($childSource)
    $remaining = [Math]::Max(0, [int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
    if (-not $write.Wait($remaining)) { $timedOut = $true }
    if (-not $timedOut) {
        $process.StandardInput.Close()
        $remaining = [Math]::Max(0, [int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
        if (-not $process.WaitForExit($remaining)) { $timedOut = $true }
    }
    if ($timedOut) {
        $process.Kill()
        if (-not $process.WaitForExit(5000)) { throw 'Worker termination was not confirmed.' }
    }
    if (-not $stdout.Wait(5000)) { throw 'Worker output was not available.' }
    if ([Text.Encoding]::UTF8.GetByteCount($stdout.Result) -gt 8192) { throw 'Worker output exceeded its protocol limit.' }
    $records = @()
    foreach ($line in ($stdout.Result -split '\r?\n')) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $records += ($line | ConvertFrom-Json) }
    }
    foreach ($record in $records) {
        if ($record.Kind -eq 'Progress') {
            $result.Phase = [string]$record.Phase
            $result.EnabledByScript = [bool]$record.EnabledByScript
            $result.MutationAttempted = [bool]$record.MutationAttempted
        }
    }
    $final = @($records | Where-Object { $_.Kind -eq 'Result' })
    if ($timedOut) {
        $result.Reason = 'Worker timed out and was terminated. Task actions already submitted can continue; inspect before retry.'
        $result.OutcomeUncertain = $Mode -eq 'Apply'
    }
    elseif ($process.ExitCode -eq 0 -and $final.Count -eq 1) {
        $candidate = $final[0]
        $fields = @('Kind', 'Product', 'Mode', 'Status', 'Reason', 'ProposedAction', 'EnabledByScript', 'StartRequested', 'MutationAttempted', 'LastRunUtc', 'LastTaskResult', 'OverdueHours', 'Phase')
        if (@($candidate.PSObject.Properties).Count -ne $fields.Count) { throw 'Invalid result shape.' }
        foreach ($field in $fields) { if ($null -eq $candidate.PSObject.Properties[$field]) { throw 'Missing result field.' } }
        if ($candidate.Product -ne 'mecm-ccmeval' -or $candidate.Mode -ne $Mode -or $candidate.OverdueHours -ne $OverdueHours) { throw 'Invalid result identity.' }
        if ($candidate.Status -notin @('Changed', 'Already correct', 'Skipped', 'Failed')) { throw 'Invalid result status.' }
        if ($candidate.Reason -isnot [string] -or $candidate.Reason.Length -gt 400 -or $candidate.Reason.Length -eq 0) { throw 'Invalid result reason.' }
        if ($candidate.ProposedAction -notin @('None', 'Start existing task', 'Enable and start existing task')) { throw 'Invalid proposed action.' }
        if ($candidate.Phase -notin @('Inspect', 'Recheck', 'Enable', 'RecheckAfterEnable', 'Start', 'StartAccepted')) { throw 'Invalid result phase.' }
        foreach ($flag in @('EnabledByScript', 'StartRequested', 'MutationAttempted')) { if ($candidate.$flag -isnot [bool]) { throw 'Invalid result flag.' } }
        if ($null -ne $candidate.LastRunUtc -and ($candidate.LastRunUtc -isnot [string] -or $candidate.LastRunUtc.Length -gt 64)) { throw 'Invalid run timestamp.' }
        if ($null -ne $candidate.LastTaskResult -and $candidate.LastTaskResult -isnot [long] -and $candidate.LastTaskResult -isnot [int]) { throw 'Invalid task result.' }
        $result = [ordered]@{}
        foreach ($property in $candidate.PSObject.Properties) {
            if ($property.Name -ne 'Kind') { $result[$property.Name] = $property.Value }
        }
        $result.OutcomeUncertain = $result.Status -eq 'Failed' -and $result.MutationAttempted
    }
    else {
        $result.Reason = 'Worker returned no trustworthy result; inspect before retry if Apply was selected.'
        $result.OutcomeUncertain = $Mode -eq 'Apply'
    }
}
catch {
    $result.Status = 'Failed'
    $result.OutcomeUncertain = $Mode -eq 'Apply'
}
finally {
    if ($null -ne $process) {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }
        $process.Dispose()
    }
}
$result.TimedOut = $timedOut
$json = $result | ConvertTo-Json -Compress -Depth 4
if ([Text.Encoding]::UTF8.GetByteCount($json) -ge 4096) {
    $result = [ordered]@{ Product = 'mecm-ccmeval'; Status = 'Failed'; Reason = 'Result exceeded the reporting limit; inspect before retry.'; OutcomeUncertain = ($Mode -eq 'Apply'); TimedOut = $timedOut }
    $json = $result | ConvertTo-Json -Compress
}
$json
if ($timedOut) { exit 2 }
if ($result.Status -eq 'Failed') { exit 1 }
exit 0
