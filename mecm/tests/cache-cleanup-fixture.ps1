# Synthetic provider used only by check-cache-cleanup.ps1 inside disposable child processes.
param([string]$ConfigurationPath)
$script:CacheFixture = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
$script:CacheReads = 0
$script:CimReads = 0
$script:CacheCalls = @()
$script:FakeEntries = @($script:CacheFixture.Entries)
$script:FakeMetadata = @($script:CacheFixture.Metadata)
foreach ($entry in $script:FakeEntries) {
    if ($entry.LastReferenceTime -match '^DATE:') { $entry.LastReferenceTime = [datetime]$entry.LastReferenceTime.Substring(5) }
}
foreach ($entry in $script:FakeMetadata) {
    if ($entry.LastReferenced -match '^DATE:') { $entry.LastReferenced = [datetime]$entry.LastReferenced.Substring(5) }
}
function Save-CacheFixture {
    @{ Calls = @($script:CacheCalls); Reads = $script:CacheReads; CimReads = $script:CimReads
       Entries = @($script:FakeEntries); Metadata = @($script:FakeMetadata); WorkerPid = $PID } |
        ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $script:CacheFixture.Evidence -Encoding UTF8
}
Save-CacheFixture
if ($script:CacheFixture.Fault -eq 'Noise') { [Console]::Out.Write(('x' * 131072)) }
$script:FakeCache = [pscustomobject]@{}
$script:FakeCache | Add-Member -MemberType ScriptMethod -Name GetCacheElements -Value {
    $script:CacheReads++
    if ($script:CacheReads -eq 2) {
        switch ($script:CacheFixture.Race) {
            'Referenced' { $script:FakeEntries[0].ReferenceCount = 1 }
            'WmiReferenced' { $script:FakeMetadata[0].ReferenceCount = 1 }
            'Persistent' { $script:FakeMetadata[0].PersistInCache = 1 }
            'Fresh' { $script:FakeEntries[0].LastReferenceTime = [datetime]::UtcNow }
            'OldTimestampChanged' { $script:FakeEntries[0].LastReferenceTime = [datetime]::UtcNow.AddDays(-50) }
            'Replace' { $script:FakeEntries[0].ContentID = 'replacement'; $script:FakeMetadata[0].ContentId = 'replacement' }
            'Missing' { $script:FakeEntries = @() }
            'Duplicate' { $script:FakeEntries += $script:FakeEntries[0] }
            'Unknown' { $script:FakeMetadata[0].PersistInCache = $null }
        }
    }
    Save-CacheFixture
    if ($script:CacheFixture.Fault -eq 'Enumeration') { throw 'synthetic enumeration failure' }
    if ($script:CacheFixture.Fault -eq 'Verify' -and $script:CacheCalls.Count -gt 0) { throw 'synthetic verification failure' }
    return $script:FakeEntries
}
$script:FakeCache | Add-Member -MemberType ScriptMethod -Name DeleteCacheElement -Value {
    param([string]$Id)
    $script:CacheCalls += $Id
    Save-CacheFixture
    if ($script:CacheFixture.Fault -eq 'Delete' -or
        ($script:CacheFixture.Fault -eq 'SecondDelete' -and $script:CacheCalls.Count -eq 2)) { throw 'synthetic delete failure' }
    if ($script:CacheFixture.Fault -eq 'HangDelete') { Start-Sleep -Seconds 60 }
    if ($script:CacheFixture.Fault -ne 'NoOp') {
        $script:FakeEntries = @($script:FakeEntries | Where-Object { $_.CacheElementID -ne $Id })
        if ($script:CacheFixture.Fault -ne 'MetadataNoOp') {
            $script:FakeMetadata = @($script:FakeMetadata | Where-Object { ([string]$_.CacheId).Trim('{}') -ine $Id.Trim('{}') })
        }
    }
    Save-CacheFixture
}
$script:FakeManager = [pscustomobject]@{}
$script:FakeManager | Add-Member -MemberType ScriptMethod -Name GetCacheInfo -Value { return $script:FakeCache }
function New-Object {
    [CmdletBinding()]
    param([string]$ComObject)
    if ($ComObject -cne 'UIResource.UIResourceMgr') { throw 'Unexpected provider construction in fixture' }
    if ($script:CacheFixture.Fault -eq 'Provider') { throw 'synthetic missing provider' }
    if ($script:CacheFixture.Fault -eq 'HangInspection') { Start-Sleep -Seconds 60 }
    return $script:FakeManager
}
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$Namespace, [string]$ClassName)
    if ($Namespace -cne 'root\ccm\SoftMgmtAgent' -or $ClassName -cne 'CacheInfoEx') { throw 'Unexpected CIM request in fixture' }
    $script:CimReads++
    Save-CacheFixture
    if ($script:CacheFixture.Fault -eq 'Cim' -or
        ($script:CacheFixture.Fault -eq 'Revalidation' -and $script:CimReads -eq 2)) { throw 'synthetic CIM failure' }
    return $script:FakeMetadata
}
