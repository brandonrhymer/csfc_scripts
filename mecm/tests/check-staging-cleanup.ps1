#requires -Version 5.1
# Run in a fresh Windows PowerShell process. Real temp files; no operational paths.
. (Join-Path $PSScriptRoot 'file-maintenance-fixture.ps1')
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\client-maintenance\Invoke-MecmStagingCleanup.ps1'))
function New-StagingCase([string]$Name) {
    $case=New-Case $Name
    $root=New-FixtureDirectory (Join-Path $case.App 'DisposableStaging')
    Write-Utf8 (Join-Path $root 'maintenance.guard') ''
    $file=Join-Path $root 'chunk-old.disposable'; Write-Utf8 $file '1234567890'
    [IO.File]::SetCreationTimeUtc($file,[datetime]::UtcNow.AddDays(-90))
    [IO.File]::SetLastWriteTimeUtc($file,[datetime]::UtcNow.AddDays(-90))
    $case | Add-Member NoteProperty Root $root
    $case | Add-Member NoteProperty File $file
    $case | Add-Member NoteProperty Policy ([ordered]@{
        SchemaVersion=1; Approved=$true; ApprovalReference='SYNTHETIC-FIXTURE'; ApplicationId='SyntheticMaintenanceAgent'; Root=$root;
        ActivityProtocol='ExclusiveMaintenanceGuard/v1'; FileNamePatterns=@('chunk-*.disposable'); MinimumAgeDays=30;
        MaximumEntries=100; MaximumDeleteBytes=1048576; ActivityMarkers=@('transfer.active'); ProcessNames=@('SyntheticMaintenanceAgent')
    })
    return $case
}
try {
    $c=New-StagingCase 'normal'
    foreach($name in @('evidence.log','setup.msi','unapproved.tmp','chunk-log.disposable')) { Write-Utf8 (Join-Path $c.Root $name) 'retain' }
    $nested=New-FixtureDirectory (Join-Path $c.Root 'nested'); Write-Utf8 (Join-Path $nested 'chunk-old.disposable') 'retain'
    $before=Get-Hash $c.File
    $r=Invoke-Product $source $c $c.Policy
    Assert-True ($r.Exit -eq 0 -and $r.Result.Reason -eq 'PreviewOnly' -and $r.Result.PlannedBytes -eq 10 -and $r.Result.RemovedCount -eq 0) ('Preview failed: '+$r.Raw)
    Assert-True ((Get-Hash $c.File) -eq $before) 'Preview changed content'
    $r=Invoke-Product $source $c $c.Policy 'Apply'
    Assert-True ($r.Exit -eq 0 -and $r.Result.Status -eq 'Changed' -and $r.Result.RemovedBytes -eq 10 -and -not (Test-Path -LiteralPath $c.File)) ('Apply failed: '+$r.Raw)
    foreach($name in @('evidence.log','setup.msi','unapproved.tmp','chunk-log.disposable','nested\chunk-old.disposable')) { Assert-True (Test-Path -LiteralPath (Join-Path $c.Root $name)) ('Unexpected deletion: '+$name) }
    $r=Invoke-Product $source $c $c.Policy 'Apply'; Assert-True ($r.Result.Status -eq 'Already correct') 'Repeat changed state'
    $defaultOutput=& powershell.exe -NoProfile -NonInteractive -File $source -PolicyPath $c.PolicyPath -PolicySha256 (Get-Hash $c.PolicyPath)
    $defaultResult=($defaultOutput -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $defaultResult.Mode -eq 'Preview' -and $defaultResult.Reason -eq 'PreviewOnly') 'Default mode was not Preview'
    foreach($modeFault in @('missing','null')) {
        $c=New-StagingCase ('mode-'+$modeFault)
        $injection=if($modeFault -eq 'missing') { '$s.PSObject.Properties.Remove("Mode"); & $w $s' } else { '$s.Mode=$null; & $w $s' }
        $fault=New-FaultScript $source ('worker-mode-'+$modeFault) '& $w $s' $injection
        $r=Invoke-Product $fault $c $c.Policy 'Apply'
        Assert-True ($r.Exit -eq 1 -and (Test-Path -LiteralPath $c.File)) 'Missing/null worker mode permitted mutation'
    }
    foreach($fault in @('hash','approval','age','created','marker','running','entries','bytes','pattern','relative','critical','unc','alias','duplicate')) {
        $c=New-StagingCase $fault; $hash=''
        switch($fault) {
            'hash' { $hash='0'*64 }
            'approval' { $c.Policy.Approved=$false }
            'age' { [IO.File]::SetLastWriteTimeUtc($c.File,[datetime]::UtcNow) }
            'created' { [IO.File]::SetCreationTimeUtc($c.File,[datetime]::UtcNow) }
            'marker' { Write-Utf8 (Join-Path $c.Root 'transfer.active') '' }
            'running' { $c.Policy.ProcessNames=@('powershell') }
            'entries' { $c.Policy.MaximumEntries=1 }
            'bytes' { $c.Policy.MaximumDeleteBytes=1 }
            'pattern' { $c.Policy.FileNamePatterns=@('*') }
            'relative' { $c.Policy.Root='SyntheticMaintenanceAgent\DisposableStaging' }
            'critical' { $c.Policy.Root='C:\Windows\SyntheticMaintenanceAgent\DisposableStaging' }
            'unc' { $c.Policy.Root='\\localhost\C$\SyntheticMaintenanceAgent\DisposableStaging' }
            'alias' { $c.Policy.Root=$c.Root+'\..\DisposableStaging' }
            'duplicate' { $c.Policy.FileNamePatterns=@('chunk-*.disposable','CHUNK-*.disposable') }
        }
        $r=Invoke-Product $source $c $c.Policy 'Apply' $hash
        Assert-True (Test-Path -LiteralPath $c.File) ('Unsafe mutation: '+$fault)
        if($fault -in @('age','created')) { Assert-True ($r.Result.Status -eq 'Already correct') ('Age retention failed: '+$r.Raw) }
        else { Assert-True ($r.Exit -eq 1 -and $r.Result.Status -eq 'Failed' -and -not $r.Result.MayHaveChanged) ('Guard failed '+$fault+': '+$r.Raw) }
    }
    $c=New-StagingCase 'locked'
    $hold=[IO.File]::Open($c.File,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try { $r=Invoke-Product $source $c $c.Policy 'Apply'; Assert-True ($r.Exit -eq 1) 'Locked candidate accepted' } finally { $hold.Dispose() }
    Assert-True (Test-Path -LiteralPath $c.File) 'Locked file removed'
    $c=New-StagingCase 'hardlink'
    $link=Join-Path $c.Folder 'outside-original.txt'; $null=New-Item -ItemType HardLink -Path $link -Target $c.File
    $r=Invoke-Product $source $c $c.Policy 'Apply'; Assert-True ($r.Exit -eq 1 -and (Test-Path -LiteralPath $c.File) -and (Get-Hash $link) -eq (Get-Hash $c.File)) 'Hardlink accepted'
    $c=New-StagingCase 'junction'
    $junction=Join-Path $c.Folder 'redirect'; $null=New-Item -ItemType Junction -Path $junction -Target $c.App; $script:FixtureLinks.Add($junction)
    $c.Policy.Root=Join-Path $junction 'DisposableStaging'
    $r=Invoke-Product $source $c $c.Policy 'Apply'; Assert-True ($r.Exit -eq 1 -and (Test-Path -LiteralPath $c.File)) 'Junction ancestor accepted'
    $c=New-StagingCase 'parent-race'
    $race=New-FaultScript $source 'parent-race' '$stage=''ActivityCheck''; Assert-Inactive' 'try { [IO.Directory]::Move($policy.Root,$policy.Root+"-moved") } catch {}; if ([IO.Directory]::Exists($policy.Root+"-moved")) { throw "ParentRenameEscapedLock" }; $stage=''ActivityCheck''; Assert-Inactive'
    $r=Invoke-Product $race $c $c.Policy 'Apply'
    Assert-True ($r.Exit -eq 0 -and $r.Result.RemovedCount -eq 1 -and -not (Test-Path -LiteralPath ($c.Root+'-moved'))) ('Parent lock race protection failed: '+$r.Raw)
    $c=New-StagingCase 'partial'
    $second=Join-Path $c.Root 'chunk-second.disposable'; Write-Utf8 $second 'abcdef'
    [IO.File]::SetCreationTimeUtc($second,[datetime]::UtcNow.AddDays(-90)); [IO.File]::SetLastWriteTimeUtc($second,[datetime]::UtcNow.AddDays(-90))
    $fault=New-FaultScript $source 'delete-fault' '[MaintenanceFiles]::Delete($candidate.Stream)' 'if ($result.RemovedCount -eq 1) { throw "SyntheticSecondDeleteFailure" }; [MaintenanceFiles]::Delete($candidate.Stream)'
    $r=Invoke-Product $fault $c $c.Policy 'Apply'
    Assert-True ($r.Exit -eq 1 -and $r.Result.RemovedCount -eq 1 -and $r.Result.PlannedBytes -eq 16 -and $r.Result.RemovedBytes -gt 0 -and $r.Result.RemovedBytes -lt 16 -and $r.Result.MayHaveChanged -and $r.Result.OutcomeUncertain) ('Partial failure dishonest: '+$r.Raw)
    $c=New-StagingCase 'timeout'
    $fault=New-FaultScript $source 'delete-timeout' '[MaintenanceFiles]::Delete($candidate.Stream)' '[MaintenanceFiles]::Delete($candidate.Stream); Start-Sleep -Seconds 20'
    $watch=[Diagnostics.Stopwatch]::StartNew(); $r=Invoke-Product $fault $c $c.Policy 'Apply' '' 5; $watch.Stop()
    Assert-True ($r.Exit -eq 1 -and $r.Result.Reason -eq 'WorkerTimeout' -and $r.Result.OutcomeUncertain -and $watch.Elapsed.TotalSeconds -lt 12) ('Timeout failed: '+$r.Raw)
    Write-Output ('PASS staging-cleanup: '+$script:Passes+' assertions; real Windows filesystem fixtures')
} finally { Remove-Fixture }
exit 0
