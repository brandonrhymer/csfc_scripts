#requires -Version 5.1
# Run in a fresh Windows PowerShell process. Real temp files; no operational paths.
. (Join-Path $PSScriptRoot 'file-maintenance-fixture.ps1')
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\client-maintenance\Invoke-MecmConfigRestore.ps1'))
function New-ConfigCase([string]$Name) {
    $case=New-Case $Name
    $approved=New-FixtureDirectory (Join-Path $case.App 'ApprovedConfiguration')
    $backups=New-FixtureDirectory (Join-Path $case.App 'ConfigurationBackup')
    Write-Utf8 (Join-Path $case.App 'maintenance.guard') ''
    $sourcePath=Join-Path $approved 'maintenance-display.json'
    $destination=Join-Path $case.App 'maintenance-display.json'
    Write-Utf8 $sourcePath '{"Schema":"MaintenanceDisplay/v1","RefreshSeconds":60,"DisplayLevel":"Normal"}'
    Write-Utf8 $destination '{"Schema":"MaintenanceDisplay/v1","RefreshSeconds":90,"DisplayLevel":"Compact"}'
    $case | Add-Member NoteProperty Policy ([ordered]@{
        SchemaVersion=1; Approved=$true; ApprovalReference='SYNTHETIC-FIXTURE'; ApplicationId='SyntheticMaintenanceAgent'; ApplicationRoot=$case.App;
        ActivityProtocol='ExclusiveMaintenanceGuard/v1'; SourcePath=$sourcePath; SourceSha256=(Get-Hash $sourcePath);
        DestinationPath=$destination; DestinationBeforeSha256=(Get-Hash $destination);
        BackupPath=(Join-Path $backups 'maintenance-display.before.json'); ConfigurationSchema='MaintenanceDisplay/v1'
    })
    return $case
}
try {
    $c=New-ConfigCase 'normal'; $p=$c.Policy
    $beforeHash=Get-Hash $p.DestinationPath
    $acl=(Get-Acl -LiteralPath $p.DestinationPath).Sddl
    $created=(Get-Item -LiteralPath $p.DestinationPath).CreationTimeUtc
    $r=Invoke-Product $source $c $p
    Assert-True ($r.Exit -eq 0 -and $r.Result.Reason -eq 'PreviewOnly' -and (Get-Hash $p.DestinationPath) -eq $beforeHash -and -not (Test-Path -LiteralPath $p.BackupPath)) ('Preview failed: '+$r.Raw)
    $r=Invoke-Product $source $c $p 'Apply'
    Assert-True ($r.Exit -eq 0 -and $r.Result.Status -eq 'Changed' -and $r.Result.DestinationState -eq 'ApprovedVerified' -and $r.Result.BackupState -eq 'OriginalVerified') ('Restore failed: '+$r.Raw)
    Assert-True ((Get-Hash $p.DestinationPath) -eq $p.SourceSha256 -and (Get-Hash $p.BackupPath) -eq $beforeHash) 'Restore/backup bytes mismatch'
    Assert-True ((Get-Acl -LiteralPath $p.DestinationPath).Sddl -eq $acl -and (Get-Item -LiteralPath $p.DestinationPath).CreationTimeUtc -eq $created) 'Destination ACL/creation metadata changed'
    $r=Invoke-Product $source $c $p 'Apply'
    Assert-True ($r.Result.Status -eq 'Already correct' -and -not $r.Result.MayHaveChanged -and (Get-Hash $p.BackupPath) -eq $beforeHash) 'Repeat changed original backup'
    $defaultOutput=& powershell.exe -NoProfile -NonInteractive -File $source -PolicyPath $c.PolicyPath -PolicySha256 (Get-Hash $c.PolicyPath)
    $defaultResult=($defaultOutput -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $defaultResult.Mode -eq 'Preview') 'Default mode was not Preview'
    foreach($modeFault in @('missing','null')) {
        $c=New-ConfigCase ('mode-'+$modeFault); $p=$c.Policy
        $injection=if($modeFault -eq 'missing') { '$s.PSObject.Properties.Remove("Mode"); & $w $s' } else { '$s.Mode=$null; & $w $s' }
        $fault=New-FaultScript $source ('worker-mode-'+$modeFault) '& $w $s' $injection
        $r=Invoke-Product $fault $c $p 'Apply'
        Assert-True ($r.Exit -eq 1 -and (Get-Hash $p.DestinationPath) -eq $p.DestinationBeforeSha256 -and -not (Test-Path -LiteralPath $p.BackupPath)) 'Missing/null worker mode permitted mutation'
    }
    foreach($fault in @('policyhash','sourcehash','destinationhash','approval','backup','schema','secret','duplicatekey','relative','critical','unc','overlap','active')) {
        $c=New-ConfigCase $fault; $p=$c.Policy; $hash=''; $beforeHash=Get-Hash $p.DestinationPath
        switch($fault) {
            'policyhash' { $hash='0'*64 }
            'sourcehash' { $p.SourceSha256='0'*64 }
            'destinationhash' { $p.DestinationBeforeSha256='0'*64 }
            'approval' { $p.Approved=$false }
            'backup' { Write-Utf8 $p.BackupPath 'collision' }
            'schema' { $p.ConfigurationSchema='ArbitraryJson/v1' }
            'secret' { Write-Utf8 $p.SourcePath '{"Schema":"MaintenanceDisplay/v1","RefreshSeconds":60,"DisplayLevel":"Normal","Password":"synthetic"}'; $p.SourceSha256=Get-Hash $p.SourcePath }
            'duplicatekey' { Write-Utf8 $p.SourcePath '{"Schema":"MaintenanceDisplay/v1","RefreshSeconds":30,"RefreshSeconds":60,"DisplayLevel":"Normal"}'; $p.SourceSha256=Get-Hash $p.SourcePath }
            'relative' { $p.SourcePath='ApprovedConfiguration\maintenance-display.json' }
            'critical' { $p.ApplicationRoot='C:\Windows\SyntheticMaintenanceAgent' }
            'unc' { $p.SourcePath='\\localhost\C$\maintenance-display.json' }
            'overlap' { $p.BackupPath=$p.SourcePath }
            'active' { Write-Utf8 (Join-Path $c.App 'application.active') '' }
        }
        $r=Invoke-Product $source $c $p 'Apply' $hash
        Assert-True ($r.Exit -eq 1 -and $r.Result.Status -eq 'Failed' -and -not $r.Result.MayHaveChanged -and (Get-Hash $p.DestinationPath) -eq $beforeHash) ('Guard failed '+$fault+': '+$r.Raw)
    }
    $c=New-ConfigCase 'hardlink'; $p=$c.Policy
    $link=Join-Path $c.Folder 'alias.json'; $null=New-Item -ItemType HardLink -Path $link -Target $p.DestinationPath
    $r=Invoke-Product $source $c $p 'Apply'; Assert-True ($r.Exit -eq 1 -and (Get-Hash $link) -eq $p.DestinationBeforeSha256) 'Destination hardlink accepted'
    $c=New-ConfigCase 'source-junction'; $p=$c.Policy
    $real=New-FixtureDirectory (Join-Path $c.Folder 'real-source')
    Copy-Item -LiteralPath $p.SourcePath -Destination (Join-Path $real 'maintenance-display.json')
    $approvedFolder=Split-Path -Parent $p.SourcePath
    # Verified exact fixture child only, before creating the junction.
    Assert-True ($approvedFolder -eq (Join-Path $c.App 'ApprovedConfiguration') -and $approvedFolder.StartsWith($script:Fixture+'\')) 'Unsafe source fixture path'
    Remove-Item -LiteralPath $p.SourcePath
    Remove-Item -LiteralPath $approvedFolder
    $null=New-Item -ItemType Junction -Path $approvedFolder -Target $real; $script:FixtureLinks.Add($approvedFolder)
    $r=Invoke-Product $source $c $p 'Apply'; Assert-True ($r.Exit -eq 1 -and (Get-Hash $p.DestinationPath) -eq $p.DestinationBeforeSha256) 'Source junction accepted'
    $c=New-ConfigCase 'locked'; $p=$c.Policy
    $hold=[IO.File]::Open($p.DestinationPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try { $r=Invoke-Product $source $c $p 'Apply'; Assert-True ($r.Exit -eq 1 -and -not $r.Result.MayHaveChanged) 'Locked destination accepted' } finally { $hold.Dispose() }
    $c=New-ConfigCase 'backup-failure'; $p=$c.Policy
    $fault=New-FaultScript $source 'backup-failure' '$backup.Write($before,0,$before.Length);' '$backup.WriteByte(0); $backup.Flush($true); throw "SyntheticBackupFailure"; $backup.Write($before,0,$before.Length);'
    $r=Invoke-Product $fault $c $p 'Apply'
    Assert-True ($r.Exit -eq 1 -and $r.Result.DestinationState -eq 'OriginalVerified' -and $r.Result.BackupState -eq 'Unverified' -and $r.Result.OutcomeUncertain -and (Get-Hash $p.DestinationPath) -eq $p.DestinationBeforeSha256) ('Backup failure dishonest: '+$r.Raw)
    $c=New-ConfigCase 'backup-collision-race'; $p=$c.Policy
    $fault=New-FaultScript $source 'backup-collision-race' '$backup=[MaintenanceFiles]::NewBackup($policy.BackupPath)' '[IO.File]::WriteAllText($policy.BackupPath,"synthetic-collision"); $backup=[MaintenanceFiles]::NewBackup($policy.BackupPath)'
    $r=Invoke-Product $fault $c $p 'Apply'
    Assert-True ($r.Exit -eq 1 -and [IO.File]::ReadAllText($p.BackupPath) -eq 'synthetic-collision' -and (Get-Hash $p.DestinationPath) -eq $p.DestinationBeforeSha256) 'Concurrent backup collision was overwritten'
    $c=New-ConfigCase 'partial'; $p=$c.Policy
    $fault=New-FaultScript $source 'replace-fault' '$destination.Position=0; $destination.Write($approved,0,$approved.Length);' '$destination.Position=0; $destination.WriteByte(0); $destination.Flush($true); throw "SyntheticPartialWrite"; $destination.Write($approved,0,$approved.Length);'
    $r=Invoke-Product $fault $c $p 'Apply'
    Assert-True ($r.Exit -eq 1 -and $r.Result.DestinationState -eq 'Unknown' -and $r.Result.BackupState -eq 'OriginalVerified' -and $r.Result.OutcomeUncertain -and (Get-Hash $p.BackupPath) -eq $p.DestinationBeforeSha256) ('Partial replacement dishonest: '+$r.Raw)
    # Prove recovery material is sufficient without invoking an operational rollback.
    $recovered=Join-Path $c.Folder 'synthetic-recovered.json'; Copy-Item -LiteralPath $p.BackupPath -Destination $recovered
    Assert-True ((Get-Hash $recovered) -eq $p.DestinationBeforeSha256) 'Backup not usable for recovery'
    $c=New-ConfigCase 'timeout'; $p=$c.Policy
    $fault=New-FaultScript $source 'replace-timeout' '$stage=''Verification''' 'Start-Sleep -Seconds 20; $stage=''Verification'''
    $watch=[Diagnostics.Stopwatch]::StartNew(); $r=Invoke-Product $fault $c $p 'Apply' '' 5; $watch.Stop()
    Assert-True ($r.Exit -eq 1 -and $r.Result.Reason -eq 'WorkerTimeout' -and $r.Result.OutcomeUncertain -and $watch.Elapsed.TotalSeconds -lt 12) ('Timeout failed: '+$r.Raw)
    Assert-True ((Get-Hash $p.BackupPath) -eq $p.DestinationBeforeSha256) 'Timeout lost backup'
    Write-Output ('PASS config-restore: '+$script:Passes+' assertions; real Windows filesystem fixtures')
} finally { Remove-Fixture }
