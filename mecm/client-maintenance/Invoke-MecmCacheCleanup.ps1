#requires -Version 5.1
<#
.SYNOPSIS
Previews or removes eligible old MECM client cache entries through the client API.
.DESCRIPTION
Offline Windows PowerShell 5.1 client script. Preview is the default. Unknown,
persistent, incomplete, referenced and recent content is retained. This script
never deletes cache files directly. See cache-cleanup.md before an approved pilot.
.PARAMETER Mode
Preview (default) or Apply. Apply requires an approved retention policy.
.PARAMETER RetentionDays
Minimum whole days since both client last-reference timestamps. Default 30; 1-3650.
.PARAMETER TimeoutSeconds
Worker budget including inspection and deletion. Default 60; 5-120 seconds.
.OUTPUTS
One compact JSON summary. Exit 0 for evaluated results; 1 for failure; 2 for invalid parameters.
.EXAMPLE
.\Invoke-MecmCacheCleanup.ps1 -Mode Preview -RetentionDays 30 -TimeoutSeconds 60
#>
[CmdletBinding()]
param(
    [string]$Mode = 'Preview',
    [int]$RetentionDays = 30,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$summary = [ordered]@{
    Product = 'mecm-cache-cleanup'; Device = $env:COMPUTERNAME; Mode = $Mode
    Status = 'Failed'; Reason = 'WorkerNotStarted'; RetentionDays = $RetentionDays
    ExaminedCount = 0; EligibleCount = 0; RemovedCount = 0
    RetainedCount = 0; UnknownCount = 0; ChangedBeforeDeleteCount = 0
    PlannedContentSize = 0; RemovedContentSize = 0; SizeBasis = 'ClientMetadataUnitsUnverified'
    MayHaveChanged = $false; OutcomeUncertain = $false
}
if ([string]$summary.Device -and ([string]$summary.Device).Length -gt 128) { $summary.Device = 'Unavailable' }
if ($Mode -notin @('Preview', 'Apply') -or $RetentionDays -lt 1 -or $RetentionDays -gt 3650 -or
    $TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 120) {
    # Do not echo arbitrary invalid strings into MECM's small output field.
    $summary.Mode = 'Invalid'; $summary.Reason = 'InvalidParameter'
    $summary | ConvertTo-Json -Compress
    exit 2
}
$Mode = if ($Mode -ieq 'Apply') { 'Apply' } else { 'Preview' }
$summary.Mode = $Mode

# All client-provider calls stay in this owned child process. Killing the child
# bounds a hung COM/CIM call; it does not roll back an external provider action.
$worker = {
    param([string]$Mode, [int]$RetentionDays)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Set-StrictMode -Version 2.0
    $result = [ordered]@{
        Status = 'Failed'; Reason = 'InspectionFailed'; ExaminedCount = 0
        EligibleCount = 0; RemovedCount = 0; RetainedCount = 0; UnknownCount = 0
        ChangedBeforeDeleteCount = 0; PlannedContentSize = [long]0; RemovedContentSize = [long]0
        MayHaveChanged = $false; OutcomeUncertain = $false
    }
    $stage = 'Inspection'
    $mutationPending = $false

    function Get-UnsignedValue {
        param($Value)
        if ($null -eq $Value -or $Value -is [bool]) { return $null }
        $text = [string]$Value
        [long]$number = 0
        if ($text -notmatch '^[0-9]+$' -or
            -not [long]::TryParse($text, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
        return $number
    }
    function Get-FlagValue {
        param($Value)
        if ($Value -is [bool]) { return [int]$Value }
        $number = Get-UnsignedValue $Value
        if ($null -eq $number -or $number -gt 1) { return $null }
        return $number
    }
    function Get-CacheKey {
        param($Value)
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        [guid]$identity = [guid]::Empty
        if ([guid]::TryParse($text, [ref]$identity)) { return $identity.ToString('D') }
        return $text
    }
    function Get-EntryState {
        param($Entry, [object[]]$Metadata, [datetime]$NowUtc, [datetime]$CutoffUtc)
        try {
            foreach ($field in @('CacheElementID', 'ContentID', 'Location')) {
                if ([string]::IsNullOrWhiteSpace([string]$Entry.$field)) { return @{ State = 'Unknown' } }
            }
            $key = Get-CacheKey $Entry.CacheElementID
            $matches = @($Metadata | Where-Object { (Get-CacheKey $_.CacheId) -ieq $key })
            if ($matches.Count -ne 1) { return @{ State = 'Unknown' } }
            $metadataEntry = $matches[0]
            if ([string]::IsNullOrWhiteSpace([string]$metadataEntry.ContentId) -or
                [string]::IsNullOrWhiteSpace([string]$metadataEntry.Location) -or
                [string]$metadataEntry.ContentId -ine [string]$Entry.ContentID -or
                [string]$metadataEntry.Location -ine [string]$Entry.Location) { return @{ State = 'Unknown' } }

            $persistent = Get-FlagValue $metadataEntry.PersistInCache
            $complete = Get-FlagValue $metadataEntry.ContentComplete
            $comReferences = Get-UnsignedValue $Entry.ReferenceCount
            $wmiReferences = Get-UnsignedValue $metadataEntry.ReferenceCount
            $size = Get-UnsignedValue $Entry.ContentSize
            if ($null -eq $persistent -or $null -eq $complete -or $null -eq $comReferences -or
                $null -eq $wmiReferences -or $null -eq $size) { return @{ State = 'Unknown' } }
            if ($persistent -ne 0 -or $complete -ne 1 -or $comReferences -ne 0 -or $wmiReferences -ne 0) {
                return @{ State = 'Retained' }
            }
            # COM DATE and CIM datetime must arrive as DateTime, never an ambiguous
            # culture-dependent string. Unexpected provider types fail closed.
            if ($Entry.LastReferenceTime -isnot [datetime] -or $metadataEntry.LastReferenced -isnot [datetime]) {
                return @{ State = 'Unknown' }
            }
            $comTime = $Entry.LastReferenceTime.ToUniversalTime()
            $wmiTime = $metadataEntry.LastReferenced.ToUniversalTime()
            if ($comTime -lt [datetime]'1970-01-01Z' -or $wmiTime -lt [datetime]'1970-01-01Z' -or
                $comTime -gt $NowUtc -or $wmiTime -gt $NowUtc) { return @{ State = 'Unknown' } }
            if ($comTime -ge $CutoffUtc -or $wmiTime -ge $CutoffUtc) { return @{ State = 'Retained' } }
            return @{
                State = 'Eligible'; Id = [string]$Entry.CacheElementID; Key = $key
                ContentId = [string]$Entry.ContentID; Location = [string]$Entry.Location
                LastCom = $comTime; LastWmi = $wmiTime; Size = $size
            }
        } catch { return @{ State = 'Unknown' } }
    }

    try {
        $manager = New-Object -ComObject 'UIResource.UIResourceMgr' -ErrorAction Stop
        $cache = $manager.GetCacheInfo()
        $entries = @($cache.GetCacheElements())
        $metadata = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' -ErrorAction Stop)
        $now = [datetime]::UtcNow
        $cutoff = $now.AddDays(-$RetentionDays)
        $candidates = @()
        $result.ExaminedCount = $entries.Count
        foreach ($entry in $entries) {
            $state = Get-EntryState $entry $metadata $now $cutoff
            # Duplicate COM identities cannot safely select one deletion target.
            if ($state.State -eq 'Eligible' -and
                @($entries | Where-Object { (Get-CacheKey $_.CacheElementID) -ieq $state.Key }).Count -ne 1) {
                $state = @{ State = 'Unknown' }
            }
            if ($state.State -eq 'Eligible') {
                $candidates += $state
                $result.EligibleCount++
                $result.PlannedContentSize = [long]([decimal]$result.PlannedContentSize + [decimal]$state.Size)
            } elseif ($state.State -eq 'Unknown') { $result.UnknownCount++ }
            else { $result.RetainedCount++ }
        }
        if ($candidates.Count -eq 0) {
            $result.Status = if ($result.UnknownCount) { 'Skipped' } else { 'Already correct' }
            $result.Reason = if ($result.UnknownCount) { 'UnknownMetadataRetained' } else { 'NoEligibleContent' }
            return [pscustomobject]$result
        }
        if ($Mode -eq 'Preview') {
            $result.Status = 'Skipped'; $result.Reason = 'PreviewOnly'
            return [pscustomobject]$result
        }

        foreach ($candidate in $candidates) {
            $stage = 'Revalidation'
            $currentEntries = @($cache.GetCacheElements())
            $currentMetadata = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' -ErrorAction Stop)
            $matches = @($currentEntries | Where-Object { (Get-CacheKey $_.CacheElementID) -ieq $candidate.Key })
            if ($matches.Count -ne 1) { $result.ChangedBeforeDeleteCount++; continue }
            $current = Get-EntryState $matches[0] $currentMetadata ([datetime]::UtcNow) $cutoff
            if ($current.State -ne 'Eligible' -or $current.ContentId -ine $candidate.ContentId -or
                $current.Location -ine $candidate.Location -or $current.LastCom -ne $candidate.LastCom -or
                $current.LastWmi -ne $candidate.LastWmi -or $current.Size -ne $candidate.Size) {
                $result.ChangedBeforeDeleteCount++; continue
            }
            $stage = 'Deletion'
            $mutationPending = $true
            $result.MayHaveChanged = $true
            # No force/persistent override and no filesystem fallback. The final
            # read cannot lock the provider; concurrent-use protection inside
            # this API is a live-pilot assumption, not established by local tests.
            $null = $cache.DeleteCacheElement([string]$candidate.Id)
            $stage = 'Verification'
            $remaining = @($cache.GetCacheElements())
            $remainingMetadata = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' -ErrorAction Stop)
            if (@($remaining | Where-Object { (Get-CacheKey $_.CacheElementID) -ieq $candidate.Key }).Count -gt 0 -or
                @($remainingMetadata | Where-Object { (Get-CacheKey $_.CacheId) -ieq $candidate.Key }).Count -gt 0) {
                $result.Status = 'Failed'; $result.Reason = 'DeletionNotConfirmed'
                $result.OutcomeUncertain = $true
                return [pscustomobject]$result
            }
            $mutationPending = $false
            $result.RemovedCount++
            $result.RemovedContentSize = [long]([decimal]$result.RemovedContentSize + [decimal]$candidate.Size)
        }
        if ($result.RemovedCount -gt 0) {
            $result.Status = 'Changed'
            $result.Reason = if ($result.ChangedBeforeDeleteCount) { 'EligibleContentRemovedOthersChanged' } else { 'EligibleContentRemoved' }
        } else {
            $result.Status = 'Skipped'; $result.Reason = 'EligibilityChanged'
        }
        return [pscustomobject]$result
    } catch {
        $result.Status = 'Failed'; $result.Reason = $stage + 'Failed'
        $result.OutcomeUncertain = $mutationPending
        return [pscustomobject]$result
    }
}

$process = $null
$workerStarted = $false
$exitCode = 1
try {
    # Parameters are serialized data, not executable text. Only the resulting
    # Base64 command is passed to powershell.exe; no user shell interpolation.
    $settings = @{ Mode = $Mode; RetentionDays = $RetentionDays } | ConvertTo-Json -Compress
    $settings64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($settings))
    $command = '$ErrorActionPreference = ''Stop''; $ProgressPreference = ''SilentlyContinue''; $settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $settings64 + ''')) | ConvertFrom-Json; & {' +
        $worker.ToString() + '} -Mode $settings.Mode -RetentionDays $settings.RetentionDays | ConvertTo-Json -Compress -Depth 5'
    $command64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSHOME 'powershell.exe'
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $command64
    if (($start.FileName.Length + $start.Arguments.Length + 4) -ge 32767) { throw 'WorkerCommandTooLong' }
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'WorkerStartFailed' }
    $workerStarted = $true
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $summary.Reason = 'WorkerTimeout'
        $summary.MayHaveChanged = ($Mode -eq 'Apply'); $summary.OutcomeUncertain = ($Mode -eq 'Apply')
        # Observations died with the worker. Zero would falsely imply no effects.
        foreach ($key in @('ExaminedCount', 'EligibleCount', 'RemovedCount', 'RetainedCount', 'UnknownCount',
            'ChangedBeforeDeleteCount', 'PlannedContentSize', 'RemovedContentSize')) { $summary[$key] = $null }
        $process.Kill()
        if (-not $process.WaitForExit(2000)) { $summary.Reason = 'WorkerStopUnconfirmed' }
    } elseif ($process.ExitCode -ne 0 -or -not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) {
        $summary.Reason = 'WorkerFailed'
        $summary.MayHaveChanged = ($Mode -eq 'Apply'); $summary.OutcomeUncertain = ($Mode -eq 'Apply')
        foreach ($key in @('ExaminedCount', 'EligibleCount', 'RemovedCount', 'RetainedCount', 'UnknownCount',
            'ChangedBeforeDeleteCount', 'PlannedContentSize', 'RemovedContentSize')) { $summary[$key] = $null }
    } else {
        if ($stdout.Result.Length -gt 3500 -or $stderr.Result.Length -ne 0) { throw 'InvalidWorkerOutput' }
        $workerResult = $stdout.Result | ConvertFrom-Json -ErrorAction Stop
        if ($workerResult -isnot [pscustomobject] -or
            $workerResult.Status -notin @('Changed', 'Already correct', 'Skipped', 'Failed') -or
            $workerResult.Reason -notin @('InspectionFailed', 'RevalidationFailed', 'DeletionFailed', 'VerificationFailed',
                'DeletionNotConfirmed', 'UnknownMetadataRetained', 'NoEligibleContent', 'PreviewOnly',
                'EligibilityChanged', 'EligibleContentRemoved', 'EligibleContentRemovedOthersChanged')) { throw 'InvalidWorkerResult' }
        $counts = @('ExaminedCount', 'EligibleCount', 'RemovedCount', 'RetainedCount', 'UnknownCount',
            'ChangedBeforeDeleteCount', 'PlannedContentSize', 'RemovedContentSize')
        $expectedProperties = @('Status', 'Reason', 'MayHaveChanged', 'OutcomeUncertain') + $counts
        if (@($workerResult.PSObject.Properties).Count -ne $expectedProperties.Count -or
            @(Compare-Object @($workerResult.PSObject.Properties.Name) $expectedProperties -CaseSensitive).Count -ne 0) {
            throw 'InvalidWorkerSchema'
        }
        foreach ($key in $counts) {
            $value = $workerResult.$key
            if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0) { throw 'InvalidWorkerCount' }
        }
        if ($workerResult.MayHaveChanged -isnot [bool] -or $workerResult.OutcomeUncertain -isnot [bool]) { throw 'InvalidWorkerFlag' }
        foreach ($property in $workerResult.PSObject.Properties) {
            if ($summary.Contains($property.Name)) { $summary[$property.Name] = $property.Value }
        }
        if ($summary.Status -ne 'Failed') { $exitCode = 0 }
    }
} catch {
    if ($summary.Reason -ne 'WorkerTimeout') { $summary.Reason = 'WorkerFailed' }
    if ($null -ne $process) {
        try {
            if ($workerStarted -and -not $process.HasExited) {
                $process.Kill()
                if (-not $process.WaitForExit(2000)) { $summary.Reason = 'WorkerStopUnconfirmed' }
            }
        } catch { $summary.Reason = 'WorkerStopUnconfirmed' }
    }
    $summary.MayHaveChanged = ($Mode -eq 'Apply' -and $workerStarted)
    $summary.OutcomeUncertain = $summary.MayHaveChanged
    if ($workerStarted) {
        foreach ($key in @('ExaminedCount', 'EligibleCount', 'RemovedCount', 'RetainedCount', 'UnknownCount',
            'ChangedBeforeDeleteCount', 'PlannedContentSize', 'RemovedContentSize')) { $summary[$key] = $null }
    }
} finally {
    if ($null -ne $process) { $process.Dispose() }
}
$outputJson = $summary | ConvertTo-Json -Compress -Depth 5
if ([Text.Encoding]::UTF8.GetByteCount($outputJson) -ge 4096) {
    # Last-resort contract defense; no provider data should escape the fixed schema.
    $outputJson = '{"Product":"mecm-cache-cleanup","Status":"Failed","Reason":"OutputTooLarge","MayHaveChanged":true,"OutcomeUncertain":true}'
    $exitCode = 1
}
$outputJson
exit $exitCode
