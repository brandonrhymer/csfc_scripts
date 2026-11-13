#requires -Version 5.1
<#
.SYNOPSIS
Enables one approved existing scheduled task without requesting a run.
.DESCRIPTION
Offline Windows PowerShell 5.1. Preview is default. Requires approved local JSON
policy bytes and a separately approved SHA256. See task-enable.md.
.PARAMETER Mode
Preview or Apply. Preview never mutates a target.
.PARAMETER PolicyPath
Absolute fixed-drive JSON path without reparse points, UNC or device syntax.
.PARAMETER PolicySha256
Expected SHA256 of the exact approved policy bytes, 64 hexadecimal characters.
.PARAMETER TimeoutSeconds
Whole worker budget including input and provider calls, 5-120; default 60.
.OUTPUTS
Compact JSON. Exit 0 evaluated; 1 failed; 2 invalid input or worker timeout.
#>
[CmdletBinding()]
param([string]$Mode = 'Preview', [string]$PolicyPath = '', [string]$PolicySha256 = '', [int]$TimeoutSeconds = 60)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$result = [ordered]@{ Product = 'mecm-task-enable'; Mode = 'Invalid'; Status = 'Failed'; Reason = 'InvalidParameter'; Phase = 'Validation'; LastState = 'Unknown'; MayHaveChanged = $false; OutcomeUncertain = $false; TimedOut = $false }
if ($Mode -notin @('Preview','Apply') -or $TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 120 -or
    $PolicySha256 -notmatch '^[a-fA-F0-9]{64}$' -or $PolicyPath.Length -gt 240 -or
    $PolicyPath -notmatch '^[A-Za-z]:\\[^:*?"<>|]+\.json$' -or $PolicyPath -match '[\x00-\x1f]' -or
    $PolicyPath -match '(?:^|\\)\.{1,2}(?:\\|$)') {
    $result | ConvertTo-Json -Compress; exit 2
}
$Mode = if ($Mode -ieq 'Apply') { 'Apply' } else { 'Preview' }
$result.Mode = $Mode; $result.Reason = 'WorkerFailed'; $result.Phase = 'WorkerStartup'
$worker = {
    param([Parameter(Mandatory = $true)][ValidateSet('Preview','Apply')][string]$Mode, [string]$PolicyPath, [string]$PolicySha256, [ValidateRange(5,120)][int]$TimeoutSeconds)
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
    Set-StrictMode -Version 2.0
    $r = [ordered]@{ Status = 'Failed'; Reason = 'PolicyInvalid'; Phase = 'Policy'; LastState = 'Unknown'; MayHaveChanged = $false; OutcomeUncertain = $false }
    $mutex = $null; $ownsMutex = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    function Send-Record {
        param([string]$Kind)
        $record = [ordered]@{ Kind = $Kind }
        foreach ($key in $r.Keys) { $record[$key] = $r[$key] }
        [Console]::Out.WriteLine(($record | ConvertTo-Json -Compress)); [Console]::Out.Flush()
    }
    function Assert-Shape {
        param($Value, [string[]]$Fields)
        if ($Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Fields.Count -or
            @(Compare-Object @($Value.PSObject.Properties.Name) $Fields -CaseSensitive).Count -ne 0) { throw 'PolicyInvalid' }
    }
    function Get-Digest {
        param([byte[]]$Bytes)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    function Read-Policy {
        # Hash and parse the same bytes while excluding writers from this handle.
        if ((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($PolicyPath))).DriveType -ne [IO.DriveType]::Fixed) { throw 'PolicyInvalid' }
        $current = Get-Item -LiteralPath $PolicyPath -Force -ErrorAction Stop
        if ($current.PSIsContainer -or $current.Length -gt 65536 -or $current.Length -eq 0) { throw 'PolicyInvalid' }
        while ($null -ne $current) {
            if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PolicyInvalid' }
            $current = if ($current -is [IO.FileInfo]) { $current.Directory } else { $current.Parent }
        }
        $stream = New-Object IO.FileStream($PolicyPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 65536 -or $stream.Length -lt 1) { throw 'PolicyInvalid' }
            $bytes = New-Object byte[] ([int]$stream.Length)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($read -le 0) { throw 'PolicyInvalid' }; $offset += $read
            }
        } finally { $stream.Dispose() }
        if ((Get-Digest $bytes) -ine $PolicySha256) { throw 'PolicyHashMismatch' }
        $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes).TrimStart([char]0xfeff)
        $p = $text | ConvertFrom-Json -ErrorAction Stop
        Assert-Shape $p @('SchemaVersion','Product','Example','Target')
        if ($p.SchemaVersion -isnot [int] -or $p.SchemaVersion -ne 1 -or $p.Product -cne 'mecm-task-enable' -or $p.Example -isnot [bool]) { throw 'PolicyInvalid' }
        if ($p.Example) { throw 'ExamplePolicyRejected' }
        return $p
    }
    try {
        $policy = Read-Policy
        $target = $policy.Target
        Assert-Shape $target @('TaskPath','TaskName','DefinitionSha256')
        if ($target.TaskPath -isnot [string] -or $target.TaskName -isnot [string] -or $target.DefinitionSha256 -isnot [string] -or
            $target.TaskPath -notmatch '^\\(?:[A-Za-z0-9 _.-]+\\)*$' -or $target.TaskPath.Length -gt 200 -or
            $target.TaskPath -match '(?:^|\\)\.{1,2}(?:\\|$)' -or $target.TaskName -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,127}$' -or
            $target.DefinitionSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'PolicyInvalid' }
        if ($target.TaskPath -imatch '^\\(?:Microsoft|Windows|Configuration Manager)(?:\\|$)' -or
            ($target.TaskPath + $target.TaskName) -imatch '(ccm|sms|defender|security|antivirus|antimalware|crowdstrike|sentinel|nessus|tenable|qualys)') { throw 'TargetExcluded' }
        function Read-Task {
            # Enumerate and compare literally; names never become wildcard selectors.
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -ieq $target.TaskPath -and $_.TaskName -ieq $target.TaskName })
            if ($tasks.Count -eq 0) { throw 'TargetMissing' }
            if ($tasks.Count -ne 1) { throw 'TargetAmbiguous' }
            $task = $tasks[0]
            if ($task.Settings.Enabled -isnot [bool]) { throw 'IdentityMismatch' }
            $r.LastState = if ($task.Settings.Enabled) { 'Enabled' } else { 'Disabled' }
            $xmlText = Export-ScheduledTask -TaskPath $target.TaskPath -TaskName $target.TaskName -ErrorAction Stop
            if ($xmlText -isnot [string] -or $xmlText.Length -gt 262144) { throw 'IdentityMismatch' }
            $settings = New-Object Xml.XmlReaderSettings; $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
            $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader $xmlText), $settings)
            $xml = New-Object Xml.XmlDocument; $xml.PreserveWhitespace = $false; $xml.XmlResolver = $null
            try { $xml.Load($reader) } finally { $reader.Dispose() }
            $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable); $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
            if ($null -eq $xml.SelectSingleNode('/t:Task', $ns)) { throw 'IdentityMismatch' }
            $enabled = @($xml.SelectNodes('/t:Task/t:Settings/t:Enabled', $ns))
            if ($enabled.Count -gt 1) { throw 'IdentityMismatch' }
            foreach ($node in $enabled) { $null = $node.ParentNode.RemoveChild($node) }
            $digest = Get-Digest ([Text.Encoding]::UTF8.GetBytes($xml.OuterXml))
            if ($digest -ine $target.DefinitionSha256) { throw 'IdentityMismatch' }
            return $task
        }
        $r.Phase = 'Inspect'
        $mutexKey = Get-Digest ([Text.Encoding]::UTF8.GetBytes(($target.TaskPath + $target.TaskName).ToLowerInvariant()))
        $mutex = New-Object Threading.Mutex($false, ('Global\CsfcMecmTask-' + $mutexKey))
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true; throw 'RevalidationChanged' }
        if (-not $ownsMutex) { $r.Status = 'Skipped'; $r.Reason = 'AnotherOperationActive' }
        else {
            $task = Read-Task
            if ($task.Settings.Enabled) { $r.Status = 'Already correct'; $r.Reason = 'TaskEnabled' }
            elseif ($Mode -eq 'Preview') { $r.Status = 'Skipped'; $r.Reason = 'PreviewOnly' }
            else {
                $r.Phase = 'Recheck'; $task = Read-Task
                if ($task.Settings.Enabled) { throw 'RevalidationChanged' }
                $r.Phase = 'Enable'; $r.MayHaveChanged = $true; Send-Record 'Progress'
                $null = Enable-ScheduledTask -InputObject $task -ErrorAction Stop
                $r.Phase = 'Verify'; $task = Read-Task
                if (-not $task.Settings.Enabled) { throw 'EnableNotConfirmed' }
                $r.Status = 'Changed'; $r.Reason = 'TaskEnabled'; $r.OutcomeUncertain = $false
            }
        }
    } catch {
        $r.Status = 'Failed'
        $known = @('PolicyInvalid','PolicyHashMismatch','ExamplePolicyRejected','TargetExcluded','TargetMissing','TargetAmbiguous','IdentityMismatch','DependencyRefused','StateNotEligible','RevalidationChanged','StopRejected','StartRejected','StopNotConfirmed','StartNotConfirmed','EnableNotConfirmed')
        $r.Reason = if ($_.Exception.Message -in $known) { $_.Exception.Message } else { $r.Phase + 'Failed' }
        $r.OutcomeUncertain = $r.MayHaveChanged
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
    Send-Record 'Result'
}

# This owned child contains every provider call. Its termination cannot roll back
# an action already submitted. Input transfer shares the worker deadline.
$process = $null; $started = $false; $timedOut = $false
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    $data = @{ Mode = $Mode; PolicyPath = $PolicyPath; PolicySha256 = $PolicySha256; TimeoutSeconds = $TimeoutSeconds } | ConvertTo-Json -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))
    $childSource = '$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $encoded + ''')) | ConvertFrom-Json; & {' + [Environment]::NewLine + $worker.ToString() + [Environment]::NewLine + '} -Mode $p.Mode -PolicyPath $p.PolicyPath -PolicySha256 $p.PolicySha256 -TimeoutSeconds $p.TimeoutSeconds'
    $entry = '$ProgressPreference = ''SilentlyContinue''; $ErrorActionPreference = ''Stop''; $reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding($false, $true)), $true); $source = $reader.ReadToEnd().TrimStart([char]0xfeff); & ([scriptblock]::Create($source))'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($entry))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
    if (-not $process.Start()) { throw 'WorkerStartFailed' }; $started = $true
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    $inputWriter = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false, $true)))
    $inputWriter.AutoFlush = $true
    $write = $inputWriter.WriteAsync($childSource)
    $remaining = [Math]::Max(0, [int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
    if (-not $write.Wait($remaining)) { $timedOut = $true }
    if (-not $timedOut) {
        $inputWriter.Close()
        $remaining = [Math]::Max(0, [int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
        if (-not $process.WaitForExit($remaining)) { $timedOut = $true }
    }
    if ($timedOut) {
        $process.Kill()
        if (-not $process.WaitForExit(2000)) { throw 'WorkerStopUnconfirmed' }
    }
    if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000) -or $stderr.Result.Length -gt 0 -or
        [Text.Encoding]::UTF8.GetByteCount($stdout.Result) -gt 8192) { throw 'WorkerProtocolFailed' }
    $records = @(); $finalCount = 0
    foreach ($line in ($stdout.Result -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $record = $line | ConvertFrom-Json -ErrorAction Stop
        $fields = @('Kind','Status','Reason','Phase','LastState','MayHaveChanged','OutcomeUncertain')
        if ($record -isnot [pscustomobject] -or @($record.PSObject.Properties).Count -ne $fields.Count -or
            @(Compare-Object @($record.PSObject.Properties.Name) $fields -CaseSensitive).Count -ne 0 -or
            $record.Kind -notin @('Progress','Result') -or $record.Status -notin @('Changed','Already correct','Skipped','Failed') -or
            $record.Reason -isnot [string] -or $record.Reason -notmatch '^[A-Za-z]{1,64}$' -or
            $record.Phase -notin @('Policy','Inspect','Recheck','Stop','WaitStopped','Start','WaitRunning','Enable','Verify') -or
            $record.LastState -notin @('Unknown','Stopped','Running','Start Pending','Stop Pending','Paused','Pause Pending','Continue Pending','Disabled','Enabled','Ready','Queued') -or
            $record.MayHaveChanged -isnot [bool] -or $record.OutcomeUncertain -isnot [bool] -or $finalCount -gt 0) { throw 'WorkerProtocolFailed' }
        if ($record.Kind -eq 'Result') { $finalCount++ }
        $records += $record
    }
    foreach ($record in $records) {
        foreach ($key in @('Phase','LastState','MayHaveChanged','OutcomeUncertain')) { $result[$key] = $record.$key }
        if ($record.Kind -eq 'Result' -and -not $timedOut -and $process.ExitCode -eq 0) {
            $result.Status = $record.Status; $result.Reason = $record.Reason
        }
    }
    if ($timedOut) { $result.Status = 'Failed'; $result.Reason = 'WorkerTimeout'; $result.MayHaveChanged = ($Mode -eq 'Apply'); $result.OutcomeUncertain = ($Mode -eq 'Apply') }
    elseif ($finalCount -ne 1 -or $process.ExitCode -ne 0) { throw 'WorkerProtocolFailed' }
} catch {
    $result.Status = 'Failed'; $result.Reason = 'WorkerFailed'
    $result.MayHaveChanged = ($Mode -eq 'Apply' -and $started); $result.OutcomeUncertain = $result.MayHaveChanged
} finally {
    if ($null -ne $process) {
        try { if ($started -and -not $process.HasExited) { $process.Kill(); if (-not $process.WaitForExit(2000)) { $result.Reason = 'WorkerStopUnconfirmed' } } }
        catch { $result.Reason = 'WorkerStopUnconfirmed' }
        $process.Dispose()
    }
}
$result.TimedOut = $timedOut
$json = $result | ConvertTo-Json -Compress
if ([Text.Encoding]::UTF8.GetByteCount($json) -ge 4096) { $json = '{"Status":"Failed","Reason":"OutputTooLarge","OutcomeUncertain":true}'; $result.Status = 'Failed' }
$json
if ($timedOut) { exit 2 }
if ($result.Status -eq 'Failed') { exit 1 }
exit 0
