#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Sequential, offline Microsoft Defender security-intelligence deployment MVP.
.DESCRIPTION
Stages one Microsoft-signed package; uses Kerberos PowerShell remoting; copies
and verifies SHA-256; runs the package; evaluates version and age separately.
No downloads, Defender configuration changes, automatic retries, or reboots.
Use 64-bit Windows PowerShell 5.1 on the controller. Pilot before broad use.
A fresh CSV filename and an existing results parent directory are required.
WhatIf reads/validates inputs but creates no files and contacts no targets.
.NOTES
Exit codes: 0 = verified/recent; 1 = target failure/stale/unknown status;
2 = warning or incomplete version evidence; 3 = controller/preflight failure.
This script is intentionally sequential. See README.md for timeout limitations.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SystemsListPath,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ResultsFilePath,
    [ValidateNotNullOrEmpty()][string]$DestinationDirectory = 'C:\ProgramData\CSfC-DefenderUpdate-MVP',
    [ValidatePattern('(?i)^mpam-fe(?:x64)?\.exe$')][string]$ExecutableFilename = 'mpam-fe.exe',
    [ValidateRange(1, 8760)][int]$RecentThresholdHours = 24,
    [ValidateRange(1, 8760)][int]$StaleThresholdHours = 48,
    [ValidateRange(1, 600)][int]$ConnectionTimeoutSeconds = 30,
    [ValidateRange(1, 3600)][int]$RemoteCommandTimeoutSeconds = 60,
    [ValidateRange(1, 86400)][int]$InstallerTimeoutSeconds = 600,
    [ValidateRange(1, 3600)][int]$VerificationTimeoutSeconds = 120,
    [ValidateRange(1, 300)][int]$VerificationPollIntervalSeconds = 5,
    [ValidateRange(0, 1048576)][int]$MinimumFreeSpaceMB = 1024,
    [string]$ExpectedSignatureVersion,
    [string]$PackageReleaseTimeUtc,
    [string]$ApprovedSha256,
    [string[]]$InstallerArgumentList = @(),
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$UseSSL
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-SignatureVersion {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    [version]$parsed = $null
    if ($Value -match '^\d+\.\d+\.\d+\.\d+$' -and
        [version]::TryParse($Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-DefinitionRecency {
    param(
        [AllowNull()][AllowEmptyString()][string]$LastUpdatedUtc,
        [datetimeoffset]$ReferenceTimeUtc,
        [int]$RecentHours,
        [int]$StaleHours
    )
    $answer = [ordered]@{ Result = 'Unknown'; AgeHours = $null; Note = '' }
    [datetimeoffset]$updated = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($LastUpdatedUtc,
            [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None,
            [ref]$updated) -or $updated.Year -lt 1970) {
        $answer.Note = 'Missing or invalid last-updated timestamp.'
    } else {
        $age = ($ReferenceTimeUtc - $updated).TotalHours
        $answer.AgeHours = [math]::Round($age, 3)
        if ($age -lt 0) { $answer.Note = 'Last-updated timestamp is in the future.' }
        elseif ($age -lt $RecentHours) { $answer.Result = 'Recent' }
        elseif ($age -le $StaleHours) { $answer.Result = 'Aging' }
        else { $answer.Result = 'Stale' }
    }
    [pscustomobject]$answer
}

function Get-TargetName {
    param([string]$Path)
    $seen = @{}
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $name = $line.Trim().TrimEnd('.')
        if (-not $name -or $name.StartsWith('#')) { continue }
        $name = $name.ToLowerInvariant()
        [System.Net.IPAddress]$ip = $null
        if ($name.Length -gt 253 -or
            [System.Net.IPAddress]::TryParse($name, [ref]$ip) -or
            $name -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$') {
            throw "Invalid target '$name'. Use one DNS/NetBIOS hostname per line; not an IP address."
        }
        if (-not $seen.ContainsKey($name)) { $seen[$name] = $true; $name }
    }
}

function Get-PackageIdentity {
    param([string]$Path, [string]$ApprovedHash)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -le 0) { throw 'The source must be a nonempty executable file.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw "Package signature validation failed: $($signature.Status). Do not bypass certificate validation."
    }
    if ($signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'The package does not have a validated Microsoft Corporation publisher.'
    }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($ApprovedHash -and $hash -ne $ApprovedHash) { throw 'Package SHA-256 does not match ApprovedSha256.' }
    # This checks the executable architecture, not the contents of every payload.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D -or $stream.Length -lt 64) { throw 'Not a valid PE executable.' }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'Invalid PE header offset.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Invalid PE signature.' }
        $machine = $reader.ReadUInt16()
        $architecture = switch ($machine) {
            0x014C { 'x86' }
            0x8664 { 'x64' }
            0xAA64 { 'arm64' }
            default { throw ('Unsupported executable architecture: 0x{0:X4}' -f $machine) }
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
    [pscustomobject]@{
        Hash = $hash; Architecture = $architecture; Size = [long]$file.Length
        SignerThumbprint = $signature.SignerCertificate.Thumbprint
        FileDescription = $file.VersionInfo.FileDescription
        ProductName = $file.VersionInfo.ProductName
    }
}

# Reused locally and remotely. Existing directories are validated, not re-ACLed.
$PrepareDirectory = {
    param([string]$Directory, [long]$RequiredFreeBytes)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    if ($Directory -notmatch '^[A-Za-z]:\\[^:*?"<>|]+$' -or $Directory -match '[\[\]]') {
        throw 'Use a dedicated absolute local-drive directory without wildcards or alternate data streams.'
    }
    $Directory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    if ($Directory.Length -le 3) { throw 'A drive root cannot be used as the staging directory.' }
    $cursor = $Directory
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (-not $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Unsafe directory component (file or reparse point): $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    $created = -not (Test-Path -LiteralPath $Directory)
    if ($created) {
        $null = New-Item -Path $Directory -ItemType Directory -Force -ErrorAction Stop
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
            $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid, [Security.AccessControl.FileSystemRights]::FullControl,
                ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        Set-Acl -LiteralPath $Directory -AclObject $acl -ErrorAction Stop
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedWriters = @('S-1-5-18', 'S-1-5-32-544', $currentSid)
    $acl = Get-Acl -LiteralPath $Directory -ErrorAction Stop
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $allowedWriters) { throw "Unapproved staging-directory owner: $owner" }
    $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($ace.AccessControlType -eq 'Allow' -and
            ($ace.FileSystemRights -band $writeMask) -and
            $ace.IdentityReference.Value -notin $allowedWriters) {
            throw "Staging directory allows an unapproved writer: $($ace.IdentityReference.Value). Use a dedicated protected directory."
        }
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Directory))
    if ($drive.AvailableFreeSpace -lt $RequiredFreeBytes) { throw 'Insufficient free space on the staging volume.' }
    $probe = Join-Path $Directory ([guid]::NewGuid().ToString('N') + '.write-test')
    $probeStream = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $probeStream.Dispose()
    Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    $Directory
}

function Invoke-RemoteStep {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds,
        [string]$Step
    )
    $job = $null
    try {
        $job = Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob -ErrorAction Stop
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds -ErrorAction Stop
        if ($null -eq $completed) {
            throw [TimeoutException]::new("$Step exceeded $TimeoutSeconds seconds; remote outcome may be unresolved.")
        }
        $output = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($job.State -ne 'Completed') { throw "$Step ended with job state $($job.State)." }
        $output
    } finally {
        if ($null -ne $job) {
            if ($job.State -notin @('Completed', 'Failed', 'Stopped')) {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
            }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

$GetRemoteStatus = {
    param([string]$PendingDirectory)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The remote session is not running with administrative privileges.'
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw 'The target endpoint requires Windows PowerShell 5.1 or newer.' }
    $null = Get-Command Get-MpComputerStatus -ErrorAction Stop
    $status = Get-MpComputerStatus -ErrorAction Stop
    $updatedUtc = ''
    if ($null -ne $status.AntivirusSignatureLastUpdated) {
        # Defender reports local time. Convert ON THE TARGET before serialization.
        $updatedUtc = ([datetime]$status.AntivirusSignatureLastUpdated).ToUniversalTime().ToString('o')
    }
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
    $architecture = switch ($architecture) {
        'AMD64' { 'x64' }; 'x86' { 'x86' }; 'ARM64' { 'arm64' }; default { 'Unknown' }
    }
    $mode = 'Unknown'
    if ($null -ne $status.PSObject.Properties['AMRunningMode']) { $mode = [string]$status.AMRunningMode }
    $pendingMarker = ''
    if ($PendingDirectory) {
        $candidate = Join-Path $PendingDirectory 'DefenderUpdate-MVP.pending.json'
        if (Test-Path -LiteralPath $candidate) { $pendingMarker = $candidate }
    }
    [pscustomobject]@{
        PendingMarkerPath = $pendingMarker
        Version = [string]$status.AntivirusSignatureVersion; UpdatedUtc = $updatedUtc
        CollectedAtUtc = [datetime]::UtcNow.ToString('o'); Architecture = $architecture
        AMServiceEnabled = $status.AMServiceEnabled; AntivirusEnabled = $status.AntivirusEnabled
        AMRunningMode = $mode; RealTimeProtectionEnabled = $status.RealTimeProtectionEnabled
        RebootRequired = $status.RebootRequired
    }
}

$InstallRemotePackage = {
    param([string]$Path, [string]$Hash, [string[]]$Arguments, [string]$RunId)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $markerPath = Join-Path ([IO.Path]::GetDirectoryName($Path)) 'DefenderUpdate-MVP.pending.json'
    # A pending marker survives cancellation or controller loss. Never silently retry it.
    $guard = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) { throw 'Package changed before execution.' }
        $marker = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $text = [pscustomobject]@{ RunId = $RunId; Package = $Path; SHA256 = $Hash; StartedUtc = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($text)
            $marker.Write($bytes, 0, $bytes.Length)
            $marker.Flush()
        } finally { $marker.Dispose() }
        $parameters = @{ FilePath = $Path; Wait = $true; PassThru = $true; NoNewWindow = $true; ErrorAction = 'Stop' }
        if ($null -ne $Arguments -and $Arguments.Count -gt 0) { $parameters.ArgumentList = $Arguments }
        # Start-Process -Wait waits for the process tree; the controller times this command.
        $process = Start-Process @parameters
        $exitCode = $process.ExitCode
        $processId = $process.Id
        $process.Dispose()
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
        [pscustomobject]@{ ExitCode = $exitCode; ProcessId = $processId }
    } finally { $guard.Dispose() }
}

function Set-ResultSnapshot {
    param([System.Collections.IDictionary]$Result, [object]$Snapshot, [int]$RecentHours, [int]$StaleHours)
    $Result.AfterVersion = $Snapshot.Version
    $Result.AfterUpdatedUtc = $Snapshot.UpdatedUtc
    $Result.CollectedAtUtc = $Snapshot.CollectedAtUtc
    $collected = [datetimeoffset]::Parse($Snapshot.CollectedAtUtc, [cultureinfo]::InvariantCulture)
    $Result.ClockSkewSeconds = [math]::Round(([datetimeoffset]::UtcNow - $collected).TotalSeconds, 1)
    $recency = Get-DefinitionRecency $Snapshot.UpdatedUtc $collected $RecentHours $StaleHours
    $Result.RecencyResult = $recency.Result
    $Result.DefinitionAgeHours = $recency.AgeHours
    if ($recency.Note -and -not $Result.Notes.Contains($recency.Note)) { $Result.Notes += $recency.Note + ' ' }
    if ([math]::Abs($Result.ClockSkewSeconds) -gt 300) {
        $Result.RecencyResult = 'Unknown'
        $Result.Notes += 'Controller/target observation differs by over five minutes; inspect clock synchronization. '
    }
    foreach ($property in @('AMServiceEnabled', 'AntivirusEnabled', 'AMRunningMode', 'RealTimeProtectionEnabled', 'RebootRequired')) {
        $Result[$property] = $Snapshot.$property
    }
}

$runId = [guid]::NewGuid().ToString('N')
$allResults = [Collections.Generic.List[object]]::new()
$reportWriter = $null
$reportStream = $null
$sourceGuard = $null
$runLock = $null
$stageDirectory = $null
$exitCode = 0
$wroteHeader = $false

try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Run this MVP in 64-bit Windows PowerShell.' }
    if ($StaleThresholdHours -le $RecentThresholdHours) { throw 'StaleThresholdHours must exceed RecentThresholdHours.' }
    if ($VerificationPollIntervalSeconds -gt $VerificationTimeoutSeconds) { throw 'Verification poll interval exceeds the verification timeout.' }
    $expectedVersion = $null
    if ($ExpectedSignatureVersion) {
        $expectedVersion = ConvertTo-SignatureVersion $ExpectedSignatureVersion
        if ($null -eq $expectedVersion) { throw 'ExpectedSignatureVersion must contain four numeric components.' }
    }
    if ($ApprovedSha256 -and $ApprovedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'ApprovedSha256 must be a 64-character SHA-256 value.' }
    $packageRecency = 'NotProvided'
    $packageAge = $null
    if ($PackageReleaseTimeUtc) {
        [datetimeoffset]$release = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($PackageReleaseTimeUtc, [cultureinfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$release) -or
            $release.Offset -ne [timespan]::Zero -or $release.Year -lt 1970 -or
            $release -gt [datetimeoffset]::UtcNow) { throw 'PackageReleaseTimeUtc must be a valid, non-future UTC timestamp, including Z or +00:00.' }
        if ($PackageReleaseTimeUtc -notmatch '(Z|\+00:00)$') { throw 'PackageReleaseTimeUtc must explicitly include Z or +00:00.' }
        $PackageReleaseTimeUtc = $release.ToString('o')
        $age = Get-DefinitionRecency $PackageReleaseTimeUtc ([datetimeoffset]::UtcNow) $RecentThresholdHours $StaleThresholdHours
        $packageRecency = $age.Result; $packageAge = $age.AgeHours
    }
    $list = Get-Item -LiteralPath $SystemsListPath -ErrorAction Stop
    if ($list.PSIsContainer) { throw 'SystemsListPath is a directory, not a file.' }
    $targets = @(Get-TargetName -Path $list.FullName)
    if ($targets.Count -eq 0) { throw 'The systems list contains no valid targets.' }
    $sourceFile = Join-Path $SourceDirectory $ExecutableFilename
    $source = Get-Item -LiteralPath $sourceFile -ErrorAction Stop
    $sourceFile = $source.FullName
    $ResultsFilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsFilePath)
    $reportParent = Split-Path -Path $ResultsFilePath -Parent
    if (-not (Test-Path -LiteralPath $reportParent -PathType Container)) { throw 'Create the results parent directory before running the script.' }
    if (Test-Path -LiteralPath $ResultsFilePath) { throw 'ResultsFilePath already exists. Use a new CSV filename for each run.' }
    if ($DestinationDirectory -notmatch '^[A-Za-z]:\\[^:*?"<>|]+$' -or $DestinationDirectory -match '[\[\]]') {
        throw 'DestinationDirectory must be a dedicated absolute local-drive directory without wildcards.'
    }
    $DestinationDirectory = [IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\')
    if ($DestinationDirectory.Length -le 3) { throw 'DestinationDirectory cannot be a drive root.' }
    $remoteFile = Join-Path $DestinationDirectory $ExecutableFilename

    if ($WhatIfPreference) {
        $preview = Get-PackageIdentity $sourceFile $ApprovedSha256
        Write-Host "Preview: $($targets.Count) target(s); package SHA256 $($preview.Hash); architecture $($preview.Architecture)."
        foreach ($computer in $targets) { $null = $PSCmdlet.ShouldProcess($computer, "Inspect Defender, stage $remoteFile, run package, and verify") }
        Write-Host 'No files created; no target connections. Report writability, target ACLs, and target readiness are not tested by this preview.'
        exit 0
    }

    $workspace = Join-Path $env:ProgramData 'CSfC-DefenderUpdate-MVP-Controller'
    $null = & $PrepareDirectory $workspace ([long]$source.Length + 64MB)
    # Fixed controller-wide lock, independent of the CSV filename.
    $runLock = [IO.File]::Open((Join-Path $workspace 'run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stageDirectory = Join-Path $workspace $runId
    $null = & $PrepareDirectory $stageDirectory ([long]$source.Length + 64MB)
    $stagedFile = Join-Path $stageDirectory $ExecutableFilename
    Copy-Item -LiteralPath $sourceFile -Destination $stagedFile -Force -ErrorAction Stop
    $sourceGuard = [IO.File]::Open($stagedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $package = Get-PackageIdentity $stagedFile $ApprovedSha256
    # Opening the actual report is the writability check; existing reports are never overwritten.
    $reportStream = [IO.File]::Open($ResultsFilePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $reportWriter = [IO.StreamWriter]::new($reportStream, [Text.UTF8Encoding]::new($true))
    $reportWriter.AutoFlush = $true
    Write-Host "Run $runId | $($targets.Count) target(s) | $($package.Architecture) | SHA256 $($package.Hash)"
    Write-Host "Package description: $($package.FileDescription) | Product: $($package.ProductName)"
    if (-not $expectedVersion) { Write-Warning 'No expected signature version supplied. An observed increase will not be reported as package-version verification.' }
    if ($packageRecency -in @('Aging', 'Stale')) { Write-Warning "The supplied package release metadata is $packageRecency ($packageAge hours)." }

    foreach ($computer in $targets) {
        $session = $null
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $row = [ordered]@{
            RunId = $runId; ComputerName = $computer; StartTimeUtc = [datetime]::UtcNow.ToString('o')
            EndTimeUtc = ''; DurationSeconds = $null; Stage = 'Connect'; DeploymentResult = 'Failed'
            RecencyResult = 'Unknown'; DefinitionAgeHours = $null
            BeforeVersion = ''; AfterVersion = ''; BeforeUpdatedUtc = ''; AfterUpdatedUtc = ''; CollectedAtUtc = ''
            ClockSkewSeconds = $null; ExpectedSignatureVersion = $ExpectedSignatureVersion
            PackageReleaseTimeUtc = $PackageReleaseTimeUtc; PackageAgeHours = $packageAge; PackageRecencyResult = $packageRecency
            PackageSha256 = $package.Hash; PackageArchitecture = $package.Architecture; SignerThumbprint = $package.SignerThumbprint
            RemoteExecutablePath = $remoteFile; InstallerExitCode = $null; InstallerProcessId = $null; InstallerState = 'NotStarted'
            AMServiceEnabled = $null; AntivirusEnabled = $null; AMRunningMode = ''; RealTimeProtectionEnabled = $null
            RebootRequired = $null; Notes = ''; Error = ''
        }
        try {
            if (-not $PSCmdlet.ShouldProcess($computer, "Inspect Defender, stage $remoteFile, run package if needed, and verify")) {
                $row.DeploymentResult = 'SkippedByOperator'; $row.Notes = 'Operator declined this target.'
                continue
            }
            $sessionOptions = New-PSSessionOption -OpenTimeout ($ConnectionTimeoutSeconds * 1000) -CancelTimeout 10000 -MaxConnectionRetryCount 0
            $connection = @{ ComputerName = $computer; Authentication = 'Kerberos'; ConfigurationName = 'Microsoft.PowerShell'; SessionOption = $sessionOptions; ErrorAction = 'Stop' }
            if ($null -ne $Credential) { $connection.Credential = $Credential }
            if ($UseSSL) { $connection.UseSSL = $true }
            $session = New-PSSession @connection
            $row.Stage = 'Inspect'
            $before = Invoke-RemoteStep $session $GetRemoteStatus @($DestinationDirectory) $RemoteCommandTimeoutSeconds 'Inspect Defender'
            $row.BeforeVersion = $before.Version; $row.BeforeUpdatedUtc = $before.UpdatedUtc
            if ($before.PendingMarkerPath) { throw "Unresolved installation marker: $($before.PendingMarkerPath). Inspect the earlier attempt before retrying." }
            $beforeVersion = ConvertTo-SignatureVersion $before.Version
            if ($before.Architecture -ne $package.Architecture) { throw "Package architecture $($package.Architecture) does not match target $($before.Architecture)." }
            if (-not $before.AMServiceEnabled) { throw 'Defender antimalware service is not enabled. No service or policy changes will be attempted.' }
            if ($null -ne $expectedVersion -and $null -ne $beforeVersion -and $beforeVersion -ge $expectedVersion) {
                Set-ResultSnapshot $row $before $RecentThresholdHours $StaleThresholdHours
                $row.DeploymentResult = 'AlreadyAtOrAbovePackage'; $row.Stage = 'Complete'
                continue
            }
            $row.Stage = 'PrepareDestination'
            $requiredSpace = [long]$package.Size + ([long]$MinimumFreeSpaceMB * 1MB)
            $null = Invoke-RemoteStep $session $PrepareDirectory @($DestinationDirectory, $requiredSpace) $RemoteCommandTimeoutSeconds 'Prepare directory'
            $null = Invoke-RemoteStep $session {
                param($directory, $path)
                $ErrorActionPreference = 'Stop'
                $pending = Join-Path $directory 'DefenderUpdate-MVP.pending.json'
                if (Test-Path -LiteralPath $pending) { throw "Unresolved installation marker: $pending. Inspect the previous attempt before retrying." }
                if (Test-Path -LiteralPath $path) {
                    $item = Get-Item -LiteralPath $path -Force
                    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Destination executable is a directory or reparse point.' }
                    # Remove only the previous package file so the replacement inherits the protected directory ACL.
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                }
            } @($DestinationDirectory, $remoteFile) $RemoteCommandTimeoutSeconds 'Check destination'
            $row.Stage = 'Copy'
            Copy-Item -LiteralPath $stagedFile -Destination $remoteFile -ToSession $session -Force -ErrorAction Stop
            $row.Stage = 'VerifyCopy'
            $remoteHash = Invoke-RemoteStep $session {
                param($path)
                $ErrorActionPreference = 'Stop'
                (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
            } @($remoteFile) $RemoteCommandTimeoutSeconds 'Verify copied package'
            if ($remoteHash -ne $package.Hash) { throw 'Remote SHA-256 mismatch. The package will not be executed.' }
            $row.Stage = 'Install'; $row.InstallerState = 'Attempted'
            $installArgs = New-Object 'object[]' 4
            $installArgs[0] = $remoteFile; $installArgs[1] = $package.Hash
            $installArgs[2] = [string[]]$InstallerArgumentList; $installArgs[3] = $runId
            $execution = Invoke-RemoteStep $session $InstallRemotePackage $installArgs $InstallerTimeoutSeconds 'Installer'
            $row.InstallerState = 'Completed'; $row.InstallerExitCode = $execution.ExitCode; $row.InstallerProcessId = $execution.ProcessId
            if ($null -eq $execution.ExitCode -or $execution.ExitCode -ne 0) {
                $row.DeploymentResult = 'ExecutionFailed'; $row.Error = "Installer returned exit code '$($execution.ExitCode)'; only 0 is accepted."
                try {
                    $after = Invoke-RemoteStep $session $GetRemoteStatus @() $RemoteCommandTimeoutSeconds 'Read failed-install status'
                    Set-ResultSnapshot $row $after $RecentThresholdHours $StaleThresholdHours
                } catch { $row.Notes += 'Final Defender status could not be read: ' + $_.Exception.Message }
                continue
            }
            $row.Stage = 'VerifyDefinitions'
            $verification = [Diagnostics.Stopwatch]::StartNew()
            $row.DeploymentResult = 'VerificationFailed'
            do {
                $remaining = [int][math]::Ceiling($VerificationTimeoutSeconds - $verification.Elapsed.TotalSeconds)
                if ($remaining -le 0) { break }
                $callTimeout = [math]::Min($RemoteCommandTimeoutSeconds, $remaining)
                $after = Invoke-RemoteStep $session $GetRemoteStatus @() $callTimeout 'Verify definitions'
                Set-ResultSnapshot $row $after $RecentThresholdHours $StaleThresholdHours
                $afterVersion = ConvertTo-SignatureVersion $after.Version
                if ($null -ne $expectedVersion -and $null -ne $afterVersion -and $afterVersion -ge $expectedVersion) {
                    $row.DeploymentResult = 'TargetVersionVerified'; break
                }
                if ($null -eq $expectedVersion -and $null -ne $beforeVersion -and $null -ne $afterVersion -and $afterVersion -gt $beforeVersion) {
                    $row.DeploymentResult = 'VersionIncreaseObserved'
                    $row.Notes += 'Version increased, but package-version verification is unavailable without ExpectedSignatureVersion. '
                    break
                }
                $sleepMs = [int][math]::Min(($VerificationPollIntervalSeconds * 1000),
                    [math]::Max(0, (($VerificationTimeoutSeconds - $verification.Elapsed.TotalSeconds) * 1000)))
                if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
            } while ($verification.Elapsed.TotalSeconds -lt $VerificationTimeoutSeconds)
            if ($row.DeploymentResult -eq 'VerificationFailed') {
                if ($null -eq $expectedVersion) {
                    $row.DeploymentResult = 'NoVerifiedVersionChange'
                    $row.Notes += 'No verifiable version increase; the target may already be current. Expected package version was not supplied. '
                } else { $row.Error = 'The expected signature version was not observed before the verification deadline.' }
            } else { $row.Stage = 'Complete' }
        } catch {
            $row.Error = $_.Exception.Message
            if ($row.InstallerState -eq 'Attempted') {
                $row.InstallerState = 'Unresolved'; $row.DeploymentResult = 'Unverified'
                $row.Notes += 'Do not blindly retry. Inspect the remote pending marker and installer state. Session closure may terminate remote processes. '
            }
            if ($_.Exception -is [TimeoutException]) { $row.DeploymentResult = 'TimedOutUnverified' }
        } finally {
            if ($null -ne $session) {
                try { Remove-PSSession -Session $session -ErrorAction Stop }
                catch { $row.Notes += 'Session cleanup failed: ' + $_.Exception.Message + ' ' }
            }
            $row.EndTimeUtc = [datetime]::UtcNow.ToString('o')
            $row.DurationSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
            $result = [pscustomobject]$row
            $allResults.Add($result)
            try {
                $csvLines = @($result | ConvertTo-Csv -NoTypeInformation)
                if (-not $wroteHeader) { $reportWriter.WriteLine($csvLines[0]); $wroteHeader = $true }
                foreach ($csvLine in $csvLines[1..($csvLines.Count - 1)]) { $reportWriter.WriteLine($csvLine) }
                $reportWriter.Flush()
            } catch {
                Write-Warning ('Could not save result; stopping dispatch. Unsaved result: ' + ($result | ConvertTo-Json -Compress))
                throw
            }
            Write-Host ("{0}: {1}; recency={2}; {3} -> {4}" -f $computer, $row.DeploymentResult, $row.RecencyResult, $row.BeforeVersion, $row.AfterVersion)
        }
    }
    $verified = @('AlreadyAtOrAbovePackage', 'TargetVersionVerified')
    $warningResults = @('VersionIncreaseObserved', 'NoVerifiedVersionChange', 'SkippedByOperator')
    foreach ($result in $allResults) {
        if ($result.DeploymentResult -eq 'SkippedByOperator') { if ($exitCode -eq 0) { $exitCode = 2 }; continue }
        if (($result.DeploymentResult -notin $verified -and $result.DeploymentResult -notin $warningResults) -or
            $result.RecencyResult -in @('Stale', 'Unknown') -or $packageRecency -eq 'Stale') { $exitCode = 1 }
        elseif ($exitCode -eq 0 -and ($result.DeploymentResult -in $warningResults -or
                $result.RecencyResult -eq 'Aging' -or $packageRecency -eq 'Aging')) { $exitCode = 2 }
    }
    Write-Host ($allResults | Select-Object ComputerName, DeploymentResult, RecencyResult, AfterVersion, Stage | Format-Table -AutoSize | Out-String)
    Write-Host "Results: $ResultsFilePath | Exit code: $exitCode"
} catch {
    $exitCode = 3
    Write-Error -Message ("Controller/preflight failure: " + $_.Exception.Message) -ErrorAction Continue
    Write-Warning 'New target dispatch stopped. Completed CSV rows remain available; absent targets were not completed by this run.'
} finally {
    foreach ($resource in @($reportWriter, $reportStream, $sourceGuard)) {
        if ($null -ne $resource) {
            try { $resource.Dispose() } catch { Write-Warning ('Resource cleanup failed: ' + $_.Exception.Message) }
        }
    }
    if ($stageDirectory -and (Test-Path -LiteralPath $stageDirectory)) {
        try { Remove-Item -LiteralPath $stageDirectory -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Could not remove local staged package: $stageDirectory" }
    }
    if ($null -ne $runLock) { $runLock.Dispose() }
}
exit $exitCode
