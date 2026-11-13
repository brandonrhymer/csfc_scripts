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
function Get-DescriptorBytes([string]$Sddl) {
    $descriptor=New-Object Security.AccessControl.RawSecurityDescriptor($Sddl)
    $bytes=New-Object byte[] $descriptor.BinaryLength; $descriptor.GetBinaryForm($bytes,0)
    return ,$bytes
}
function Write-FixtureAclDiagnostic($Case,$Result) {
    # Diagnostics only for this suite's synthetic paths; never part of the
    # operator product. Print no paths, account SIDs, source content or raw SDDL.
    $diagnostic=[ordered]@{ Result=$Result.Raw }
    foreach($role in @('Destination','Backup')) {
        $path=[IO.Path]::GetFullPath([string]$Case.Policy.($role+'Path'))
        if(-not $path.StartsWith($script:Fixture+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe diagnostic path' }
        $exists=Test-Path -LiteralPath $path
        $state=[ordered]@{ Exists=$exists }
        if($exists) {
            $acl=Get-Acl -LiteralPath $path
            $raw=New-Object Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(),0)
            $state.Length=(Get-Item -LiteralPath $path).Length
            $state.HashMatchesOriginal=((Get-Hash $path) -eq $Case.Policy.DestinationBeforeSha256)
            $state.Flags=[string]$raw.ControlFlags; $state.Canonical=$acl.AreAccessRulesCanonical
            $state.AceCount=if($null -eq $raw.DiscretionaryAcl) { -1 } else { $raw.DiscretionaryAcl.Count }
            if($null -ne $raw.DiscretionaryAcl) {
                $state.AcesTruncated=($raw.DiscretionaryAcl.Count -gt 32)
                $state.Aces=@($raw.DiscretionaryAcl | Select-Object -First 32 | ForEach-Object {
                    $mask=if($_ -is [Security.AccessControl.KnownAce]) { $_.AccessMask } else { $null }
                    @{ Type=[string]$_.AceType; Flags=[string]$_.AceFlags; Mask=$mask }
                })
            }
        }
        $diagnostic[$role]=$state
    }
    Write-Host ('Synthetic ACL diagnostic: '+($diagnostic | ConvertTo-Json -Depth 6 -Compress))
}
try {
    # Exercise the exact production comparer, including semantics that arbitrary
    # sorting would erase. Loading the C# helper itself performs no file I/O.
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Production source does not parse'
    $native=$ast.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class MaintenanceFiles') },$true)
    Add-Type -TypeDefinition $native.Value
    $ordered='D:P(A;;FR;;;WD)(A;;FW;;;BU)'
    $reordered='D:P(A;;FW;;;BU)(A;;FR;;;WD)'
    Assert-True ([MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes $ordered),(Get-DescriptorBytes $reordered))) 'Ordinary adjacent Allow reorder rejected'
    Assert-True ([MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes 'D:P(D;;FR;;;WD)(D;;FW;;;BU)(A;;FA;;;SY)'),(Get-DescriptorBytes 'D:P(D;;FW;;;BU)(D;;FR;;;WD)(A;;FA;;;SY)'))) 'Ordinary adjacent Deny reorder rejected'
    # Hosted regression: SetAccessControl adds AUTO_INHERITED to a materialized
    # DACL with the same three inherited Allow ACEs, each mask 2032127. That
    # resource-manager bookkeeping marker must not masquerade as permission drift.
    $hostDacl='D:(A;ID;0x1f01ff;;;SY)(A;ID;0x1f01ff;;;BA)(A;ID;0x1f01ff;;;WD)'
    $hostAutoInherited=$hostDacl.Replace('D:','D:AI')
    Assert-True ([MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes $hostDacl),(Get-DescriptorBytes $hostAutoInherited))) 'Hosted AUTO_INHERITED-only difference rejected'
    Assert-True ([MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes $hostAutoInherited),(Get-DescriptorBytes $hostDacl))) 'AUTO_INHERITED equivalence was asymmetric'
    Assert-True (-not [MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes $hostDacl),(Get-DescriptorBytes ($hostDacl.Replace('D:','D:PAI'))))) 'AUTO_INHERITED masked a protection change'
    Assert-True (-not [MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes $hostDacl),(Get-DescriptorBytes ($hostAutoInherited.Replace('0x1f01ff;;;WD','0x120089;;;WD'))))) 'AUTO_INHERITED masked a permission change'
    Assert-True (-not [MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes $hostDacl),(Get-DescriptorBytes ($hostAutoInherited.Replace('A;ID;','A;;'))))) 'AUTO_INHERITED masked changed ACE inheritance flags'
    Assert-True (-not [MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes 'D:(A;ID;FR;;;WD)(D;ID;FR;;;BU)'),(Get-DescriptorBytes 'D:AI(D;ID;FR;;;BU)(A;ID;FR;;;WD)'))) 'AUTO_INHERITED masked changed Allow/Deny order'
    $withoutDacl=New-Object Security.AccessControl.RawSecurityDescriptor([Security.AccessControl.ControlFlags]::None,$null,$null,$null,$null)
    $withoutDaclBytes=New-Object byte[] $withoutDacl.BinaryLength; $withoutDacl.GetBinaryForm($withoutDaclBytes,0)
    Assert-True (-not [MaintenanceFiles]::DaclEquivalent($withoutDaclBytes,(Get-DescriptorBytes 'D:AINO_ACCESS_CONTROL'))) 'AUTO_INHERITED masked DACL-present change'
    foreach($pair in @(
        @('D:P(A;;FR;;;WD)(D;;FR;;;BU)','D:P(D;;FR;;;BU)(A;;FR;;;WD)'),
        @('D:P(A;ID;FR;;;WD)(A;;FW;;;BU)','D:P(A;;FW;;;BU)(A;ID;FR;;;WD)'),
        @('D:P(A;;FR;;;WD)','D:(A;;FR;;;WD)'),
        @('D:P(A;;FR;;;WD)','D:P(A;;FW;;;WD)'),
        @('D:P(A;;FR;;;WD)','D:P(A;;FR;;;BU)'),
        @('D:P(A;;FR;;;WD)(A;;FR;;;WD)','D:P(A;;FR;;;WD)'),
        @('D:NO_ACCESS_CONTROL','D:')
    )) { Assert-True (-not [MaintenanceFiles]::DaclEquivalent((Get-DescriptorBytes $pair[0]),(Get-DescriptorBytes $pair[1]))) 'Security-significant DACL difference accepted' }
    # A callback ACE is a positional barrier even beside ordinary Allow ACEs.
    $sid=New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
    $ordinary=New-Object Security.AccessControl.CommonAce([Security.AccessControl.AceFlags]::None,[Security.AccessControl.AceQualifier]::AccessAllowed,1,$sid,$false,$null)
    $callback=New-Object Security.AccessControl.CommonAce([Security.AccessControl.AceFlags]::None,[Security.AccessControl.AceQualifier]::AccessAllowed,1,$sid,$true,$null)
    $callbackDescriptors=@()
    foreach($reverse in @($false,$true)) {
        $rawAcl=New-Object Security.AccessControl.RawAcl(2,2)
        if($reverse) { $rawAcl.InsertAce(0,$callback); $rawAcl.InsertAce(1,$ordinary) }
        else { $rawAcl.InsertAce(0,$ordinary); $rawAcl.InsertAce(1,$callback) }
        $descriptor=New-Object Security.AccessControl.RawSecurityDescriptor([Security.AccessControl.ControlFlags]::DiscretionaryAclPresent,$null,$null,$null,$rawAcl)
        $bytes=New-Object byte[] $descriptor.BinaryLength; $descriptor.GetBinaryForm($bytes,0)
        $callbackDescriptors+=,$bytes
    }
    Assert-True (-not [MaintenanceFiles]::DaclEquivalent($callbackDescriptors[0],$callbackDescriptors[1])) 'Callback ACE ordering ignored'
    $c=New-ConfigCase 'normal'; $p=$c.Policy
    $beforeHash=Get-Hash $p.DestinationPath
    $acl=(Get-Acl -LiteralPath $p.DestinationPath).Sddl
    $created=(Get-Item -LiteralPath $p.DestinationPath).CreationTimeUtc
    $r=Invoke-Product $source $c $p
    Assert-True ($r.Exit -eq 0 -and $r.Result.Reason -eq 'PreviewOnly' -and (Get-Hash $p.DestinationPath) -eq $beforeHash -and -not (Test-Path -LiteralPath $p.BackupPath)) ('Preview failed: '+$r.Raw)
    $r=Invoke-Product $source $c $p 'Apply'
    if($r.Exit -ne 0) { Write-FixtureAclDiagnostic $c $r }
    Assert-True ($r.Exit -eq 0 -and $r.Result.Status -eq 'Changed' -and $r.Result.DestinationState -eq 'ApprovedVerified' -and $r.Result.BackupState -eq 'OriginalVerified') ('Restore failed: '+$r.Raw)
    Assert-True ((Get-Hash $p.DestinationPath) -eq $p.SourceSha256 -and (Get-Hash $p.BackupPath) -eq $beforeHash) 'Restore/backup bytes mismatch'
    Assert-True ((Get-Acl -LiteralPath $p.DestinationPath).Sddl -eq $acl -and (Get-Item -LiteralPath $p.DestinationPath).CreationTimeUtc -eq $created) 'Destination ACL/creation metadata changed'
    $r=Invoke-Product $source $c $p 'Apply'
    Assert-True ($r.Result.Status -eq 'Already correct' -and -not $r.Result.MayHaveChanged -and (Get-Hash $p.BackupPath) -eq $beforeHash) 'Repeat changed original backup'
    $defaultOutput=& powershell.exe -NoProfile -NonInteractive -File $source -PolicyPath $c.PolicyPath -PolicySha256 (Get-Hash $c.PolicyPath)
    $defaultResult=($defaultOutput -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $defaultResult.Mode -eq 'Preview') 'Default mode was not Preview'
    $c=New-ConfigCase 'protected-dacl'; $p=$c.Policy
    $protectedAcl=Get-Acl -LiteralPath $p.DestinationPath
    $protectedAcl.SetAccessRuleProtection($true,$true)
    Set-Acl -LiteralPath $p.DestinationPath -AclObject $protectedAcl
    $expectedDacl=(Get-Acl -LiteralPath $p.DestinationPath).GetSecurityDescriptorBinaryForm()
    $r=Invoke-Product $source $c $p 'Apply'
    if($r.Exit -ne 0) { Write-FixtureAclDiagnostic $c $r }
    Assert-True ($r.Exit -eq 0 -and $r.Result.BackupState -eq 'OriginalVerified' -and (Get-Hash $p.BackupPath) -eq $p.DestinationBeforeSha256 -and (Get-Hash $p.DestinationPath) -eq $p.SourceSha256) ('Protected DACL restore failed: '+$r.Raw)
    Assert-True ((Get-Acl -LiteralPath $p.BackupPath).AreAccessRulesProtected -and [MaintenanceFiles]::DaclEquivalent($expectedDacl,(Get-Acl -LiteralPath $p.BackupPath).GetSecurityDescriptorBinaryForm())) 'Protected DACL semantics were not preserved'
    $c=New-ConfigCase 'inherited-permission-drift'; $p=$c.Policy
    $backupParent=Split-Path -Parent $p.BackupPath
    $parentAcl=Get-Acl -LiteralPath $backupParent
    # A verified-absent synthetic SID makes this a new permission on every host;
    # BUILTIN Users Read could already exist in a hosted runner's inherited ACL.
    $syntheticSid=New-Object Security.Principal.SecurityIdentifier('S-1-5-21-123456789-234567890-345678901-4242')
    $destinationRules=(Get-Acl -LiteralPath $p.DestinationPath).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    Assert-True (@($destinationRules | Where-Object { $_.IdentityReference -eq $syntheticSid }).Count -eq 0) 'Synthetic drift SID unexpectedly present'
    $extra=New-Object Security.AccessControl.FileSystemAccessRule($syntheticSid,[Security.AccessControl.FileSystemRights]::Read,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
    $parentAcl.AddAccessRule($extra); Set-Acl -LiteralPath $backupParent -AclObject $parentAcl
    $r=Invoke-Product $source $c $p 'Apply'
    Assert-True ($r.Exit -eq 1 -and $r.Result.Reason -eq 'BackupAclFailed' -and $r.Result.BackupState -eq 'Unverified' -and $r.Result.DestinationState -eq 'OriginalVerified' -and (Get-Hash $p.DestinationPath) -eq $p.DestinationBeforeSha256 -and (Get-Item -LiteralPath $p.BackupPath).Length -eq 0) ('Inherited permission drift accepted: '+$r.Raw)
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
exit 0
