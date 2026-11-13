$modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\KrbtgtRotation\KrbtgtRotation.psd1'
Import-Module $modulePath -Force

InModuleScope KrbtgtRotation {
    # The development workstation intentionally has no AD RSAT module. Pester
    # 3 requires a command to exist before it can be mocked, so inert test-only
    # stubs provide names without ever contacting a directory.
    if (-not (Get-Command -Name Get-ADUser -ErrorAction SilentlyContinue)) {
        function Get-ADUser { throw 'Test-only AD stub must be mocked.' }
    }
    if (-not (Get-Command -Name Get-ADObject -ErrorAction SilentlyContinue)) {
        function Get-ADObject {
            param($Identity, $Server, $Properties, $Filter, $SearchBase, [switch]$IncludeDeletedObjects)
            throw 'Test-only AD stub must be mocked.'
        }
    }
    if (-not (Get-Command -Name Get-ADDefaultDomainPasswordPolicy -ErrorAction SilentlyContinue)) {
        function Get-ADDefaultDomainPasswordPolicy {
            param($Server)
            throw 'Test-only AD stub must be mocked.'
        }
    }

    function New-MockedMetadata {
        param(
            [int64]$Version = 10,
            [string]$Server = 'dc1.contoso.example',
            [string]$InvocationId = '11111111-1111-1111-1111-111111111111',
            [int64]$Usn = 100
        )

        [pscustomobject]@{
            Server                  = $Server
            AttributeName           = 'pwdLastSet'
            Version                 = $Version
            OriginatingInvocationId = $InvocationId
            OriginatingUsn          = $Usn
            OriginatingChangeUtc    = '2026-08-01T12:00:00.0000000Z'
        }
    }

    function New-MockedSnapshot {
        param([int64]$Version = 10)

        $sourceMetadata = New-MockedMetadata -Version $Version -Server 'dc1.contoso.example' `
            -Usn (90 + $Version)
        $destinationMetadata = New-MockedMetadata -Version $Version -Server 'dc2.contoso.example' `
            -Usn (90 + $Version)
        [pscustomobject]@{
            Status                  = 'Succeeded'
            CapturedUtc             = '2026-08-01T12:00:00.0000000Z'
            Operator                = 'CONTOSO\Administrator'
            ExecutionDc             = 'dc1.contoso.example'
            DestinationDc           = 'dc2.contoso.example'
            DomainDnsRoot           = 'contoso.example'
            DomainDistinguishedName = 'DC=contoso,DC=example'
            DomainSid               = 'S-1-5-21-100-200-300'
            UsersContainer          = 'CN=Users,DC=contoso,DC=example'
            DomainControllers       = @(
                [pscustomobject]@{ HostName = 'dc1.contoso.example'; Site = 'Default'; IsReadOnly = $false; OperatingSystem = 'Windows Server 2022 Datacenter' },
                [pscustomobject]@{ HostName = 'dc2.contoso.example'; Site = 'Default'; IsReadOnly = $false; OperatingSystem = 'Windows Server 2022 Datacenter' }
            )
            KerberosPolicy          = [pscustomobject]@{
                MaxTicketAgeMinutes  = 600
                MaxServiceAgeMinutes = 600
                MaxRenewAgeMinutes   = 10080
                MaxClockSkewMinutes  = 5
            }
            Target                  = [pscustomobject]@{
                SamAccountName    = 'krbtgt'
                Sid               = 'S-1-5-21-100-200-300-502'
                Rid               = 502
                ObjectGuid        = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                DistinguishedName = 'CN=krbtgt,CN=Users,DC=contoso,DC=example'
                Enabled           = $false
                PerDcEvidence     = @(
                    [pscustomobject]@{ Server = 'dc1.contoso.example'; PwdLastSetMetadata = $sourceMetadata },
                    [pscustomobject]@{ Server = 'dc2.contoso.example'; PwdLastSetMetadata = $destinationMetadata }
                )
            }
            Diagnostics             = @([pscustomobject]@{ DomainController = 'dc1.contoso.example' })
        }
    }

    function Enable-MockedEvidenceWriters {
        Mock Save-KrbtgtReceipt { return 'C:\ProgramData\KrbtgtRotation\Receipts\mock.json' }
        Mock Write-KrbtgtEvent { }
        Mock Test-KrbtgtEventSourceRegistration { return $true }
        Mock Complete-KrbtgtReceipt {
            $Receipt.Status = $Status
            $Receipt.CompletedUtc = '2026-08-01T12:01:00.0000000Z'
            $Receipt.ReceiptPath = 'C:\ProgramData\KrbtgtRotation\Receipts\mock.json'
            return $Receipt
        }
        Mock Write-KrbtgtFailureEvidence { }
        Mock Get-KrbtgtCurrentIdentity {
            [pscustomobject]@{
                Name = 'CONTOSO\Administrator'; UserSid = 'S-1-5-21-100-200-300-1100'
                GroupSids = @('S-1-5-21-100-200-300-512'); IsSystem = $false; IsElevated = $true
            }
        }
    }

    Describe 'Preflight directory-write boundary' {
        BeforeEach {
            Enable-MockedEvidenceWriters
            Mock Get-KrbtgtEnvironmentSnapshot { New-MockedSnapshot }
            Mock New-KrbtgtTemporaryUser { throw 'must not be called' }
            Mock Set-KrbtgtAccountPassword { throw 'must not be called' }
            Mock Sync-KrbtgtObject { throw 'must not be called' }
            Mock Remove-KrbtgtTemporaryUser { throw 'must not be called' }
        }

        It 'returns a success receipt without an AD-changing adapter call' {
            $result = Invoke-KrbtgtPreflight -OperationId '00000000-0000-0000-0000-000000000001'

            $result.Status | Should Be 'Succeeded'
            Assert-MockCalled New-KrbtgtTemporaryUser -Times 0 -Exactly -Scope It
            Assert-MockCalled Set-KrbtgtAccountPassword -Times 0 -Exactly -Scope It
            Assert-MockCalled Sync-KrbtgtObject -Times 0 -Exactly -Scope It
            Assert-MockCalled Remove-KrbtgtTemporaryUser -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Native WhatIf directory-write boundary' {
        BeforeEach {
            Enable-MockedEvidenceWriters
            Mock Get-KrbtgtEnvironmentSnapshot { New-MockedSnapshot }
            Mock Assert-KrbtgtResetPrerequisiteGates {
                @(
                    [pscustomobject]@{ InvocationId = 'preflight-id' },
                    [pscustomobject]@{ InvocationId = 'test-id' }
                )
            }
            Mock Read-Host { throw 'WhatIf must not request typed confirmation' }
            Mock Set-KrbtgtAccountPassword { throw 'must not be called' }
            Mock Sync-KrbtgtObject { throw 'must not be called' }
            Mock New-KrbtgtTemporaryUser { throw 'must not be called' }
            Mock Remove-KrbtgtTemporaryUser { throw 'must not be called' }
        }

        It 'previews Reset 1 with no prompt or directory mutation' {
            $result = Invoke-KrbtgtReset -Phase Reset1 `
                -OperationId '00000000-0000-0000-0000-000000000002' -WhatIf

            $result.Status | Should Be 'WhatIf'
            Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
            Assert-MockCalled Set-KrbtgtAccountPassword -Times 0 -Exactly -Scope It
            Assert-MockCalled Sync-KrbtgtObject -Times 0 -Exactly -Scope It
            Assert-MockCalled New-KrbtgtTemporaryUser -Times 0 -Exactly -Scope It
            Assert-MockCalled Remove-KrbtgtTemporaryUser -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Production reset fail-closed orchestration' {
        BeforeEach {
            Enable-MockedEvidenceWriters
            $script:environmentSnapshotCallCount = 0
            Mock Get-KrbtgtEnvironmentSnapshot {
                $script:environmentSnapshotCallCount++
                if ($script:environmentSnapshotCallCount -eq 1) {
                    New-MockedSnapshot -Version 10
                }
                else {
                    New-MockedSnapshot -Version 11
                }
            }
            Mock Assert-KrbtgtResetPrerequisiteGates {
                @(
                    [pscustomobject]@{ InvocationId = 'preflight-id' },
                    [pscustomobject]@{ InvocationId = 'test-id' }
                )
            }
            Mock Read-Host { 'contoso.example RESET 1' }
            Mock New-KrbtgtSecurePassword {
                $value = [Security.SecureString]::new()
                $value.AppendChar('A')
                return $value
            }
            Mock Get-KrbtgtMetadata {
                New-MockedMetadata -Version 11 -Server 'dc1.contoso.example' -Usn 101
            }
            Mock Set-KrbtgtAccountPassword { }
            Mock Sync-KrbtgtObject { }
            Mock Wait-KrbtgtMetadataConvergence {
                @(
                    (New-MockedMetadata -Version 11 -Server 'dc1.contoso.example' -Usn 101),
                    (New-MockedMetadata -Version 11 -Server 'dc2.contoso.example' -Usn 101)
                )
            }
        }

        It 'calls the production password adapter exactly once' {
            $result = Invoke-KrbtgtReset -Phase Reset1 `
                -OperationId '00000000-0000-0000-0000-000000000003' -Confirm:$false

            $result.Status | Should Be 'Succeeded'
            Assert-MockCalled Set-KrbtgtAccountPassword -Times 1 -Exactly -Scope It
            Assert-MockCalled Sync-KrbtgtObject -Times 1 -Exactly -Scope It
            Assert-MockCalled Get-KrbtgtEnvironmentSnapshot -Times 2 -Exactly -Scope It
        }

        It 'does not replicate or run post-checks after a password-write exception' {
            Mock Set-KrbtgtAccountPassword { throw 'password write failed' }

            { Invoke-KrbtgtReset -Phase Reset1 `
                    -OperationId '00000000-0000-0000-0000-000000000004' -Confirm:$false } | Should Throw

            Assert-MockCalled Set-KrbtgtAccountPassword -Times 1 -Exactly -Scope It
            Assert-MockCalled Sync-KrbtgtObject -Times 0 -Exactly -Scope It
            Assert-MockCalled Get-KrbtgtEnvironmentSnapshot -Times 1 -Exactly -Scope It
        }

        It 'does not run post-checks after convergence failure' {
            Mock Wait-KrbtgtMetadataConvergence { throw 'five-minute timeout' }

            { Invoke-KrbtgtReset -Phase Reset1 `
                    -OperationId '00000000-0000-0000-0000-000000000005' -Confirm:$false } | Should Throw

            Assert-MockCalled Set-KrbtgtAccountPassword -Times 1 -Exactly -Scope It
            Assert-MockCalled Sync-KrbtgtObject -Times 1 -Exactly -Scope It
            Assert-MockCalled Get-KrbtgtEnvironmentSnapshot -Times 1 -Exactly -Scope It
        }

        It 'does not mutate when typed confirmation is not an exact ordinal match' {
            Mock Read-Host { 'CONTOSO.EXAMPLE RESET 1' }

            { Invoke-KrbtgtReset -Phase Reset1 `
                    -OperationId '00000000-0000-0000-0000-000000000006' -Confirm:$false } | Should Throw

            Assert-MockCalled Set-KrbtgtAccountPassword -Times 0 -Exactly -Scope It
            Assert-MockCalled Sync-KrbtgtObject -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Temporary-user Test path' {
        BeforeEach {
            Enable-MockedEvidenceWriters
            Mock Get-KrbtgtEnvironmentSnapshot { New-MockedSnapshot }
            Mock Assert-KrbtgtPreflightGate { [pscustomobject]@{ InvocationId = 'preflight-id' } }
            Mock New-KrbtgtTemporaryUser {
                [pscustomobject]@{
                    ObjectGuid = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                    DistinguishedName = 'CN=KRT-test,CN=Users,DC=contoso,DC=example'
                }
            }
            Mock New-KrbtgtSecurePassword {
                $value = [Security.SecureString]::new(); $value.AppendChar('A'); return $value
            }
            $script:testMetadataCallCount = 0
            Mock Get-KrbtgtMetadata {
                $script:testMetadataCallCount++
                if ($script:testMetadataCallCount -eq 1) {
                    New-MockedMetadata -Version 1 -Usn 1
                }
                else {
                    New-MockedMetadata -Version 2 -Usn 2
                }
            }
            Mock Set-KrbtgtAccountPassword { }
            Mock Sync-KrbtgtObject { }
            Mock Wait-KrbtgtMetadataConvergence {
                @(
                    (New-MockedMetadata -Version 2 -Server 'dc1.contoso.example' -Usn 2),
                    (New-MockedMetadata -Version 2 -Server 'dc2.contoso.example' -Usn 2)
                )
            }
            Mock Remove-KrbtgtTemporaryUser { }
            Mock Get-KrbtgtDeletedObject { [pscustomobject]@{ ObjectGuid = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; IsDeleted = $true } }
            Mock Wait-KrbtgtObjectCleanup {
                [pscustomobject]@{ ObjectGuid = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; Present = $false }
            }
        }

        It 'creates one disabled user, uses the password adapter once, and verifies deletion' {
            $result = Invoke-KrbtgtTest -OperationId '00000000-0000-0000-0000-000000000007'

            $result.Status | Should Be 'Succeeded'
            Assert-MockCalled New-KrbtgtTemporaryUser -Times 1 -Exactly -Scope It
            Assert-MockCalled Set-KrbtgtAccountPassword -Times 1 -Exactly -Scope It
            Assert-MockCalled Sync-KrbtgtObject -Times 3 -Exactly -Scope It
            Assert-MockCalled Remove-KrbtgtTemporaryUser -Times 1 -Exactly -Scope It
            Assert-MockCalled Wait-KrbtgtObjectCleanup -Times 1 -Exactly -Scope It
        }

        It 'stops immediately and does not delete after password reset failure' {
            Mock Set-KrbtgtAccountPassword { throw 'test password reset failed' }

            { Invoke-KrbtgtTest -OperationId '00000000-0000-0000-0000-000000000008' } | Should Throw

            Assert-MockCalled Set-KrbtgtAccountPassword -Times 1 -Exactly -Scope It
            Assert-MockCalled Remove-KrbtgtTemporaryUser -Times 0 -Exactly -Scope It
            Assert-MockCalled Wait-KrbtgtObjectCleanup -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Receipt and timing gates' {
        BeforeEach {
            Mock Get-KrbtgtUtcNow {
                [DateTime]::new(2026, 8, 1, 12, 31, 1, [DateTimeKind]::Utc)
            }
        }

        It 'rejects a matching Preflight receipt older than 30 minutes' {
            $snapshot = New-MockedSnapshot
            $receipt = [pscustomobject]@{
                Phase = 'Preflight'; Status = 'Succeeded'
                OperationId = '00000000-0000-0000-0000-000000000009'
                DomainDnsRoot = $snapshot.DomainDnsRoot; ExecutionDc = $snapshot.ExecutionDc
                Operator = $snapshot.Operator; InvocationId = 'old-preflight'
                CompletedUtc = '2026-08-01T12:01:00Z'
                Target = [pscustomobject]@{ Sid = $snapshot.Target.Sid; ObjectGuid = $snapshot.Target.ObjectGuid }
            }

            { Get-KrbtgtCurrentPhaseReceipt -Receipts @($receipt) -Phase Preflight `
                    -OperationId $receipt.OperationId -Snapshot $snapshot } | Should Throw
        }

        It 'accepts a fully matching Preflight receipt at exactly 30 minutes' {
            $snapshot = New-MockedSnapshot
            $receipt = [pscustomobject]@{
                Phase = 'Preflight'; Status = 'Succeeded'
                OperationId = '00000000-0000-0000-0000-000000000011'
                DomainDnsRoot = $snapshot.DomainDnsRoot; ExecutionDc = $snapshot.ExecutionDc
                Operator = $snapshot.Operator; InvocationId = 'current-preflight'
                CompletedUtc = '2026-08-01T12:01:01Z'
                Target = [pscustomobject]@{ Sid = $snapshot.Target.Sid; ObjectGuid = $snapshot.Target.ObjectGuid }
            }

            $result = Get-KrbtgtCurrentPhaseReceipt -Receipts @($receipt) -Phase Preflight `
                -OperationId $receipt.OperationId -Snapshot $snapshot

            $result.InvocationId | Should Be 'current-preflight'
        }

        It 'requires the metadata version to advance exactly once' {
            $before = New-MockedMetadata -Version 10 -Usn 100
            $after = New-MockedMetadata -Version 12 -Usn 102

            { Assert-KrbtgtMetadataAdvancedOnce -Before $before -After $after } | Should Throw
        }
    }

    Describe 'Exact RID-502 target validation' {
        BeforeEach {
            Mock Get-ADUser {
                [pscustomobject]@{
                    SamAccountName    = 'krbtgt'
                    SID               = 'S-1-5-21-100-200-300-502'
                    ObjectGuid        = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    DistinguishedName = 'CN=krbtgt,CN=Users,DC=contoso,DC=example'
                    Enabled           = $false
                }
            }
            Mock Get-ADObject {
                [pscustomobject]@{
                    ObjectSid  = 'S-1-5-21-100-200-300-502'
                    ObjectGuid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                }
            }
            Mock Get-KrbtgtMetadata {
                param($ObjectDistinguishedName, $Server)
                New-MockedMetadata -Version 10 -Server $Server -Usn 100
            }
        }

        It 'accepts only the same built-in SID and GUID on both DCs' {
            $target = Get-KrbtgtTargetEvidence -DomainDistinguishedName 'DC=contoso,DC=example' `
                -DomainSid 'S-1-5-21-100-200-300' `
                -DomainControllers @('dc1.contoso.example', 'dc2.contoso.example')

            $target.Rid | Should Be 502
            $target.ObjectGuid | Should Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            Assert-MockCalled Get-ADUser -Times 2 -Exactly -Scope It
            Assert-MockCalled Get-ADObject -Times 2 -Exactly -Scope It
        }

        It 'rejects a name match whose SID is not current-domain RID 502' {
            Mock Get-ADUser {
                [pscustomobject]@{
                    SamAccountName = 'krbtgt'; SID = 'S-1-5-21-100-200-300-501'
                    ObjectGuid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    DistinguishedName = 'CN=krbtgt,CN=Users,DC=contoso,DC=example'; Enabled = $false
                }
            }

            { Get-KrbtgtTargetEvidence -DomainDistinguishedName 'DC=contoso,DC=example' `
                    -DomainSid 'S-1-5-21-100-200-300' `
                    -DomainControllers @('dc1.contoso.example', 'dc2.contoso.example') } | Should Throw

            Assert-MockCalled Get-ADObject -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Effective Kerberos policy collection' {
        BeforeEach {
            if (-not (Get-Command -Name Get-ADObject -ErrorAction SilentlyContinue)) {
                function Get-ADObject {
                    param($Identity, $Server, $Properties)
                    throw 'Test-only AD stub must be mocked.'
                }
            }
            if (-not (Get-Command -Name Get-ADDefaultDomainPasswordPolicy -ErrorAction SilentlyContinue)) {
                function Get-ADDefaultDomainPasswordPolicy {
                    param($Server)
                    throw 'Test-only AD stub must be mocked.'
                }
            }
            Mock Get-ADObject {
                param($Identity, $Server, $Properties)
                if (@($Properties) -contains 'maxServiceAge' -or
                    @($Properties) -contains 'maxClockSkew') {
                    throw 'Kerberos policy keys are not valid domain-object LDAP attributes.'
                }
                [pscustomobject]@{
                    gPLink    = '[LDAP://CN={GUID},CN=Policies,CN=System,DC=contoso,DC=example;0]'
                    gPOptions = 0
                }
            }
            Mock Get-ADDefaultDomainPasswordPolicy {
                [pscustomobject]@{
                    MinPasswordLength    = 14
                    ComplexityEnabled    = $true
                    PasswordHistoryCount = 24
                    MinPasswordAge       = [TimeSpan]::FromDays(1)
                    MaxPasswordAge       = [TimeSpan]::FromDays(60)
                    LockoutThreshold     = 3
                }
            }
            Mock Get-KrbtgtEffectiveKerberosPolicy {
                [pscustomobject]@{
                    AuthenticationOptions     = 128
                    MaxServiceTicketAgeTicks = -([TimeSpan]::FromHours(10).Ticks)
                    MaxTicketAgeTicks        = -([TimeSpan]::FromHours(10).Ticks)
                    MaxRenewAgeTicks         = -([TimeSpan]::FromDays(7).Ticks)
                    MaxClockSkewTicks        = -([TimeSpan]::FromMinutes(5).Ticks)
                }
            }
        }

        It 'queries effective LSA policy on both DCs without invalid LDAP attributes' {
            $result = Get-KrbtgtPolicySnapshot -DomainDistinguishedName 'DC=contoso,DC=example' `
                -DomainControllers @('dc1.contoso.example', 'dc2.contoso.example')

            $result.MaxTicketAgeMinutes | Should Be 600
            $result.MaxServiceAgeMinutes | Should Be 600
            $result.MaxRenewAgeMinutes | Should Be 10080
            $result.MaxClockSkewMinutes | Should Be 5
            $result.PerDcEvidence[0].AuthenticationOptions | Should Be 128
            Assert-MockCalled Get-KrbtgtEffectiveKerberosPolicy -Times 2 -Exactly -Scope It
            Assert-MockCalled Get-ADObject -Times 2 -Exactly -Scope It
        }

        It 'rejects effective Kerberos policy disagreement between DCs' {
            Mock Get-KrbtgtEffectiveKerberosPolicy {
                param($DomainController)
                $serviceHours = if ($DomainController -eq 'dc1.contoso.example') { 10 } else { 9 }
                [pscustomobject]@{
                    AuthenticationOptions     = 128
                    MaxServiceTicketAgeTicks = -([TimeSpan]::FromHours($serviceHours).Ticks)
                    MaxTicketAgeTicks        = -([TimeSpan]::FromHours(10).Ticks)
                    MaxRenewAgeTicks         = -([TimeSpan]::FromDays(7).Ticks)
                    MaxClockSkewTicks        = -([TimeSpan]::FromMinutes(5).Ticks)
                }
            }

            { Get-KrbtgtPolicySnapshot -DomainDistinguishedName 'DC=contoso,DC=example' `
                    -DomainControllers @('dc1.contoso.example', 'dc2.contoso.example') } | Should Throw
        }
    }

    Describe 'Reset 2 receipt and 11-hour gate' {
        BeforeEach {
            $script:reset1Path = 'C:\ProgramData\KrbtgtRotation\Receipts\reset1.json'
            $script:reset2Snapshot = New-MockedSnapshot -Version 10
            $script:reset1Receipt = [pscustomobject]@{
                SourcePath                 = $script:reset1Path
                InvocationId               = 'reset1-success'
                OperationId                = '00000000-0000-0000-0000-000000000010'
                Phase                      = 'Reset1'
                Status                     = 'Succeeded'
                StartedUtc                 = '2026-08-01T00:50:00Z'
                CompletedUtc               = '2026-08-01T01:00:00Z'
                DomainDnsRoot              = 'contoso.example'
                ExecutionDc                = 'dc1.contoso.example'
                DirectoryMutationAttempted = $true
                Target                     = [pscustomobject]@{
                    Sid = 'S-1-5-21-100-200-300-502'
                    ObjectGuid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                }
                KerberosPolicy             = [pscustomobject]@{ MaxTicketAgeMinutes = 600 }
            }
            $script:mockReceiptCollection = @($script:reset1Receipt)
            Mock Assert-KrbtgtEvidenceDirectory { 'C:\ProgramData\KrbtgtRotation\Receipts' }
            Mock Get-KrbtgtReceiptObjects { $script:mockReceiptCollection }
            Mock Get-KrbtgtUtcNow {
                [DateTime]::new(2026, 8, 1, 12, 0, 0, [DateTimeKind]::Utc)
            }
        }

        It 'accepts the exact protected-local Reset 1 receipt at 11 elapsed hours' {
            $result = Resolve-KrbtgtReset1Receipt -Path $script:reset1Path -Snapshot $script:reset2Snapshot

            $result.InvocationId | Should Be 'reset1-success'
        }

        It 'rejects Reset 2 even one second before 11 elapsed hours' {
            Mock Get-KrbtgtUtcNow {
                [DateTime]::new(2026, 8, 1, 11, 59, 59, [DateTimeKind]::Utc)
            }

            { Resolve-KrbtgtReset1Receipt -Path $script:reset1Path `
                    -Snapshot $script:reset2Snapshot } | Should Throw
        }

        It 'rejects an unresolved Reset 1 mutation anomaly in the cycle' {
            $failed = [pscustomobject]@{
                SourcePath = 'C:\ProgramData\KrbtgtRotation\Receipts\failed.json'
                InvocationId = 'failed-reset1'; OperationId = 'failed-op'; Phase = 'Reset1'; Status = 'Failed'
                StartedUtc = '2026-07-31T23:00:00Z'; CompletedUtc = '2026-07-31T23:01:00Z'
                DomainDnsRoot = 'contoso.example'; ExecutionDc = 'dc1.contoso.example'
                DirectoryMutationAttempted = $true
            }
            $script:mockReceiptCollection = @($failed, $script:reset1Receipt)

            { Resolve-KrbtgtReset1Receipt -Path $script:reset1Path `
                    -Snapshot $script:reset2Snapshot } | Should Throw
        }

        It 'rejects an unfinished Reset 1 mutation checkpoint in the cycle' {
            $running = [pscustomobject]@{
                SourcePath = 'C:\ProgramData\KrbtgtRotation\Receipts\running.json'
                InvocationId = 'running-reset1'; OperationId = 'running-op'; Phase = 'Reset1'; Status = 'Running'
                StartedUtc = '2026-07-31T23:30:00Z'; CompletedUtc = $null
                DomainDnsRoot = 'contoso.example'; ExecutionDc = 'dc1.contoso.example'
                DirectoryMutationAttempted = $true
            }
            $script:mockReceiptCollection = @($running, $script:reset1Receipt)

            { Resolve-KrbtgtReset1Receipt -Path $script:reset1Path `
                    -Snapshot $script:reset2Snapshot } | Should Throw
        }

        It 'rejects an intervening production mutation after the selected Reset 1' {
            $intervening = [pscustomobject]@{
                SourcePath = 'C:\ProgramData\KrbtgtRotation\Receipts\intervening.json'
                InvocationId = 'intervening-reset2'; OperationId = 'intervening-op'; Phase = 'Reset2'; Status = 'Running'
                StartedUtc = '2026-08-01T02:00:00Z'; CompletedUtc = $null
                DomainDnsRoot = 'contoso.example'; ExecutionDc = 'dc1.contoso.example'
                DirectoryMutationAttempted = $true
            }
            $script:mockReceiptCollection = @($script:reset1Receipt, $intervening)

            { Resolve-KrbtgtReset1Receipt -Path $script:reset1Path `
                    -Snapshot $script:reset2Snapshot } | Should Throw
        }
    }
}
