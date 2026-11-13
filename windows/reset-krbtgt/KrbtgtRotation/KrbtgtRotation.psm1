Set-StrictMode -Version Latest

# These values are intentionally fixed. They are safety properties of the
# approved operating profile, not tuning knobs for an operator to weaken.
$script:ToolVersion              = '0.1.1'
$script:ReceiptSchemaVersion     = '1.0'
$script:EventSchemaVersion       = '1.0'
$script:EventSource              = 'KrbtgtRotation'
$script:EventLogName             = 'System'
$script:ReceiptLifetimeMinutes   = 30
$script:ConvergenceTimeoutSeconds = 300
$script:PollIntervalSeconds      = 5
$script:Reset2MinimumHours       = 11
$script:ExpectedTicketHours      = 10

function Initialize-KrbtgtLsaInterop {
    [CmdletBinding()]
    param()

    if ($null -ne ('KrbtgtRotation.Native.LsaPolicy' -as [type])) {
        return
    }

    # LsaQueryDomainInformationPolicy is the read-only Windows API used to
    # obtain the effective Kerberos policy that the KDC itself consumes. The
    # wrapper requests only POLICY_VIEW_LOCAL_INFORMATION and releases every
    # native handle and buffer before returning.
    Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace KrbtgtRotation.Native
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct LsaUnicodeString
    {
        internal ushort Length;
        internal ushort MaximumLength;
        internal IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct LsaObjectAttributes
    {
        internal uint Length;
        internal IntPtr RootDirectory;
        internal IntPtr ObjectName;
        internal uint Attributes;
        internal IntPtr SecurityDescriptor;
        internal IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PolicyDomainKerberosTicketInfo
    {
        internal uint AuthenticationOptions;
        internal long MaxServiceTicketAge;
        internal long MaxTicketAge;
        internal long MaxRenewAge;
        internal long MaxClockSkew;
        internal long Reserved;
    }

    public sealed class KerberosPolicyInfo
    {
        public uint AuthenticationOptions { get; internal set; }
        public long MaxServiceTicketAgeTicks { get; internal set; }
        public long MaxTicketAgeTicks { get; internal set; }
        public long MaxRenewAgeTicks { get; internal set; }
        public long MaxClockSkewTicks { get; internal set; }
    }

    public static class LsaPolicy
    {
        private const uint PolicyViewLocalInformation = 0x00000001;
        private const int PolicyDomainKerberosTicketInformation = 3;

        [DllImport("advapi32.dll")]
        private static extern uint LsaOpenPolicy(
            ref LsaUnicodeString systemName,
            ref LsaObjectAttributes objectAttributes,
            uint desiredAccess,
            out IntPtr policyHandle);

        [DllImport("advapi32.dll")]
        private static extern uint LsaQueryDomainInformationPolicy(
            IntPtr policyHandle,
            int informationClass,
            out IntPtr buffer);

        [DllImport("advapi32.dll")]
        private static extern uint LsaFreeMemory(IntPtr buffer);

        [DllImport("advapi32.dll")]
        private static extern uint LsaClose(IntPtr policyHandle);

        [DllImport("advapi32.dll")]
        private static extern uint LsaNtStatusToWinError(uint status);

        public static KerberosPolicyInfo Query(string computerName)
        {
            if (String.IsNullOrWhiteSpace(computerName))
            {
                throw new ArgumentException("A target computer name is required.", "computerName");
            }

            IntPtr nameBuffer = Marshal.StringToHGlobalUni(computerName);
            try
            {
                LsaUnicodeString systemName = new LsaUnicodeString();
                systemName.Length = checked((ushort)(computerName.Length * 2));
                systemName.MaximumLength = checked((ushort)((computerName.Length + 1) * 2));
                systemName.Buffer = nameBuffer;

                LsaObjectAttributes attributes = new LsaObjectAttributes();

                IntPtr policyHandle;
                uint status = LsaOpenPolicy(
                    ref systemName,
                    ref attributes,
                    PolicyViewLocalInformation,
                    out policyHandle);
                ThrowIfFailed(status, "LsaOpenPolicy", computerName);

                try
                {
                    IntPtr buffer;
                    status = LsaQueryDomainInformationPolicy(
                        policyHandle,
                        PolicyDomainKerberosTicketInformation,
                        out buffer);
                    ThrowIfFailed(status, "LsaQueryDomainInformationPolicy", computerName);

                    try
                    {
                        PolicyDomainKerberosTicketInfo nativeInfo =
                            (PolicyDomainKerberosTicketInfo)Marshal.PtrToStructure(
                                buffer,
                                typeof(PolicyDomainKerberosTicketInfo));
                        KerberosPolicyInfo result = new KerberosPolicyInfo();
                        result.AuthenticationOptions = nativeInfo.AuthenticationOptions;
                        result.MaxServiceTicketAgeTicks = nativeInfo.MaxServiceTicketAge;
                        result.MaxTicketAgeTicks = nativeInfo.MaxTicketAge;
                        result.MaxRenewAgeTicks = nativeInfo.MaxRenewAge;
                        result.MaxClockSkewTicks = nativeInfo.MaxClockSkew;
                        return result;
                    }
                    finally
                    {
                        LsaFreeMemory(buffer);
                    }
                }
                finally
                {
                    LsaClose(policyHandle);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(nameBuffer);
            }
        }

        private static void ThrowIfFailed(uint status, string operation, string computerName)
        {
            if (status == 0)
            {
                return;
            }

            uint win32Error = LsaNtStatusToWinError(status);
            string nativeMessage = new Win32Exception((int)win32Error).Message;
            throw new Win32Exception(
                (int)win32Error,
                operation + " failed for '" + computerName +
                "' (NTSTATUS 0x" + status.ToString("X8") +
                ", Win32 " + win32Error.ToString() + "): " + nativeMessage);
        }
    }
}
'@
}

function Get-KrbtgtEffectiveKerberosPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DomainController
    )

    Initialize-KrbtgtLsaInterop
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $policy = [KrbtgtRotation.Native.LsaPolicy]::Query($DomainController)
    }
    catch {
        $baseException = $_.Exception.GetBaseException()
        throw "The effective Kerberos policy could not be read from '$DomainController' through the Windows LSA policy API: $($baseException.Message)"
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject][ordered]@{
        AuthenticationOptions     = [uint32]$policy.AuthenticationOptions
        MaxServiceTicketAgeTicks = [int64]$policy.MaxServiceTicketAgeTicks
        MaxTicketAgeTicks        = [int64]$policy.MaxTicketAgeTicks
        MaxRenewAgeTicks         = [int64]$policy.MaxRenewAgeTicks
        MaxClockSkewTicks        = [int64]$policy.MaxClockSkewTicks
    }
}

function Get-KrbtgtUtcNow {
    [CmdletBinding()]
    param()

    return [DateTime]::UtcNow
}

function Get-KrbtgtReceiptDirectory {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
        throw 'ProgramData is unavailable. The protected receipt directory cannot be resolved.'
    }

    return (Join-Path -Path $env:ProgramData -ChildPath 'KrbtgtRotation\Receipts')
}

function Get-KrbtgtCurrentIdentity {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $groupSids = @($identity.Groups | ForEach-Object { $_.Value })

    return [pscustomobject]@{
        Name      = $identity.Name
        UserSid   = $identity.User.Value
        GroupSids = $groupSids
        IsSystem  = ($identity.User.Value -eq 'S-1-5-18')
        IsElevated = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    }
}

function Test-KrbtgtEventSourceRegistration {
    [CmdletBinding()]
    param()

    if (-not [Diagnostics.EventLog]::SourceExists($script:EventSource)) {
        return $false
    }

    $registeredLog = [Diagnostics.EventLog]::LogNameFromSourceName($script:EventSource, '.')
    return [string]::Equals($registeredLog, $script:EventLogName, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-KrbtgtEvidenceDirectory {
    [CmdletBinding()]
    param()

    $path = Get-KrbtgtReceiptDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "The protected receipt directory '$path' is absent. Run the one-time setup script locally first."
    }

    $acl = Get-Acl -LiteralPath $path
    if (-not $acl.AreAccessRulesProtected) {
        throw "The receipt directory '$path' inherits permissions. Run the one-time setup script to repair it."
    }

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    try {
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    }
    catch {
        throw "The receipt directory owner '$($acl.Owner)' could not be resolved to a SID."
    }
    if ($ownerSid -notin $allowedSids) {
        throw "The receipt directory owner '$ownerSid' is neither Administrators nor SYSTEM."
    }

    $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin $allowedSids) {
            throw "The receipt directory grants access to unexpected identity '$($rule.IdentityReference.Value)'."
        }
    }

    foreach ($requiredSid in $allowedSids) {
        $fullControl = @($rules | Where-Object {
                $_.IdentityReference.Value -eq $requiredSid -and
                $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                (($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                    [Security.AccessControl.FileSystemRights]::FullControl)
            })
        if ($fullControl.Count -eq 0) {
            throw "The receipt directory does not grant FullControl to required identity '$requiredSid'."
        }
    }

    return $path
}

function Set-KrbtgtEvidenceDirectoryAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $administratorsSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        ))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $systemSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        ))

    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function New-KrbtgtReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Setup', 'Preflight', 'Test', 'Reset1', 'Reset2')]
        [string]$Phase,

        [Parameter(Mandatory)]
        [guid]$OperationId
    )

    $identityName = try { (Get-KrbtgtCurrentIdentity).Name } catch { "$env:USERDOMAIN\$env:USERNAME" }
    return [pscustomobject][ordered]@{
        SchemaVersion              = $script:ReceiptSchemaVersion
        ToolVersion                = $script:ToolVersion
        InvocationId               = [guid]::NewGuid().Guid
        OperationId                = $OperationId.Guid
        Phase                      = $Phase
        Status                     = 'Running'
        StartedUtc                 = (Get-KrbtgtUtcNow).ToString('o')
        CompletedUtc               = $null
        Operator                   = $identityName
        ExecutionDc                = $null
        DomainDnsRoot              = $null
        DomainDistinguishedName    = $null
        DomainSid                  = $null
        DirectoryMutationAttempted = $false
        ConfirmationAccepted       = $false
        Target                     = $null
        DomainControllers          = @()
        KerberosPolicy             = $null
        PrerequisiteReceipts       = @()
        Stages                     = @()
        Error                      = $null
        ReceiptPath                = $null
    }
}

function Add-KrbtgtReceiptStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Receipt,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Succeeded', 'Failed', 'Skipped', 'WhatIf')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Summary,

        [AllowNull()]
        [object]$Evidence
    )

    $stage = [pscustomobject][ordered]@{
        Name         = $Name
        Status       = $Status
        TimestampUtc = (Get-KrbtgtUtcNow).ToString('o')
        Summary      = $Summary
        Evidence     = $Evidence
    }
    $Receipt.Stages = @($Receipt.Stages) + @($stage)
}

function Set-KrbtgtReceiptContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Receipt,

        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    $Receipt.Operator = $Snapshot.Operator
    $Receipt.ExecutionDc = $Snapshot.ExecutionDc
    $Receipt.DomainDnsRoot = $Snapshot.DomainDnsRoot
    $Receipt.DomainDistinguishedName = $Snapshot.DomainDistinguishedName
    $Receipt.DomainSid = $Snapshot.DomainSid
    $Receipt.Target = $Snapshot.Target
    $Receipt.DomainControllers = $Snapshot.DomainControllers
    $Receipt.KerberosPolicy = $Snapshot.KerberosPolicy
}

function Save-KrbtgtReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Receipt
    )

    $directory = Assert-KrbtgtEvidenceDirectory
    if ([string]::IsNullOrWhiteSpace([string]$Receipt.ReceiptPath)) {
        $timestamp = ([DateTime]::Parse(
                $Receipt.StartedUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            )).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
        $fileName = '{0}_{1}_{2}.json' -f $timestamp, $Receipt.Phase, $Receipt.InvocationId
        $Receipt.ReceiptPath = Join-Path -Path $directory -ChildPath $fileName
    }

    $json = $Receipt | ConvertTo-Json -Depth 12
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Receipt.ReceiptPath, $json, $encoding)
    return $Receipt.ReceiptPath
}

function Complete-KrbtgtReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Receipt,

        [Parameter(Mandatory)]
        [ValidateSet('Succeeded', 'Failed', 'WhatIf')]
        [string]$Status,

        [AllowNull()]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )

    $Receipt.Status = $Status
    $Receipt.CompletedUtc = (Get-KrbtgtUtcNow).ToString('o')
    if ($null -ne $ErrorRecord) {
        $Receipt.Error = [pscustomobject][ordered]@{
            Message              = $ErrorRecord.Exception.Message
            ExceptionType        = $ErrorRecord.Exception.GetType().FullName
            FullyQualifiedErrorId = $ErrorRecord.FullyQualifiedErrorId
        }
    }

    Save-KrbtgtReceipt -Receipt $Receipt | Out-Null
    return $Receipt
}

function Write-KrbtgtEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$EventId,

        [Parameter(Mandatory)]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType,

        [Parameter(Mandatory)]
        [psobject]$Receipt,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not (Test-KrbtgtEventSourceRegistration)) {
        throw "The '$($script:EventSource)' event source is not registered in the System log."
    }

    $payload = [pscustomobject][ordered]@{
        SchemaVersion = $script:EventSchemaVersion
        EventId       = $EventId
        TimestampUtc  = (Get-KrbtgtUtcNow).ToString('o')
        InvocationId  = $Receipt.InvocationId
        OperationId   = $Receipt.OperationId
        Phase         = $Receipt.Phase
        Status        = $Receipt.Status
        DomainDnsRoot = $Receipt.DomainDnsRoot
        ExecutionDc   = $Receipt.ExecutionDc
        Message       = $Message
    }

    Write-EventLog -LogName $script:EventLogName -Source $script:EventSource -EventId $EventId `
        -EntryType $EntryType -Message ($payload | ConvertTo-Json -Compress) -ErrorAction Stop
}

function Write-KrbtgtFailureEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Receipt,

        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [int]$EventId
    )

    Add-KrbtgtReceiptStage -Receipt $Receipt -Name 'Failure' -Status 'Failed' `
        -Summary $ErrorRecord.Exception.Message -Evidence $null

    $saveError = $null
    try {
        Complete-KrbtgtReceipt -Receipt $Receipt -Status Failed -ErrorRecord $ErrorRecord | Out-Null
    }
    catch {
        $saveError = $_
    }

    try {
        if (Test-KrbtgtEventSourceRegistration) {
            Write-KrbtgtEvent -EventId $EventId -EntryType Error -Receipt $Receipt `
                -Message $ErrorRecord.Exception.Message
        }
    }
    catch {
        if ($null -eq $saveError) {
            $saveError = $_
        }
    }

    if ($null -ne $saveError) {
        throw "The operation failed and durable evidence could not be completed: $($saveError.Exception.Message)"
    }
}

function Assert-KrbtgtLocalSetupPrerequisites {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSEdition -ne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5 -or
        $PSVersionTable.PSVersion.Minor -ne 1) {
        throw 'Run this command in elevated Windows PowerShell 5.1 (Desktop edition).'
    }

    $identity = Get-KrbtgtCurrentIdentity
    if (-not $identity.IsElevated) {
        throw 'The current Windows PowerShell 5.1 session is not elevated. Start it with Run as administrator.'
    }
    if ($identity.IsSystem) {
        throw 'Local System execution is prohibited. Sign in interactively with the approved administrator account.'
    }

    # Check local machine role without installing RSAT or reaching another host.
    # DomainRole 4/5 is a backup/primary domain controller; the later AD
    # discovery gate separately proves writable status and the exact topology.
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ([string]$operatingSystem.Caption -notmatch 'Windows Server 2022') {
        throw 'The local computer is not reported as Windows Server 2022.'
    }
    if ([int]$computerSystem.DomainRole -notin @(4, 5)) {
        throw 'The command must be run locally on a domain controller, not a workstation or member server.'
    }
}

function New-KrbtgtProtectedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    Set-KrbtgtEvidenceDirectoryAcl -Path $Path
}

function Install-KrbtgtRotationLocalSetup {
    <#
    .SYNOPSIS
    Installs the required local event source and protected receipt directory.
    .DESCRIPTION
    Run this explicit one-time command locally on each approved DC. It registers
    KrbtgtRotation in the existing classic System log and creates the local
    ProgramData evidence directory with protected Administrators/SYSTEM ACLs.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()

    Assert-KrbtgtLocalSetupPrerequisites
    $receiptDirectory = Get-KrbtgtReceiptDirectory
    $target = "$env:COMPUTERNAME (System event source and protected receipt directory)"

    if (-not $PSCmdlet.ShouldProcess($target, 'Install one-time KrbtgtRotation local setup')) {
        return
    }

    if ([Diagnostics.EventLog]::SourceExists($script:EventSource)) {
        $registeredLog = [Diagnostics.EventLog]::LogNameFromSourceName($script:EventSource, '.')
        if (-not [string]::Equals($registeredLog, $script:EventLogName, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Event source '$($script:EventSource)' already exists under '$registeredLog', not System."
        }
    }
    else {
        New-EventLog -LogName $script:EventLogName -Source $script:EventSource -ErrorAction Stop
    }

    New-KrbtgtProtectedDirectory -Path $receiptDirectory
    $setupReceipt = New-KrbtgtReceipt -Phase Setup -OperationId ([guid]::NewGuid())
    $setupReceipt.ExecutionDc = $env:COMPUTERNAME
    Add-KrbtgtReceiptStage -Receipt $setupReceipt -Name 'LocalSetup' -Status Succeeded `
        -Summary 'Registered the local System event source and protected the receipt directory.' `
        -Evidence ([pscustomobject]@{ EventSource = $script:EventSource; ReceiptDirectory = $receiptDirectory })
    Complete-KrbtgtReceipt -Receipt $setupReceipt -Status Succeeded -ErrorRecord $null | Out-Null
    Write-KrbtgtEvent -EventId 900 -EntryType Information -Receipt $setupReceipt `
        -Message 'One-time local setup completed.'

    [pscustomobject]@{
        EventSource      = $script:EventSource
        EventLog         = $script:EventLogName
        ReceiptDirectory = $receiptDirectory
        ComputerName     = $env:COMPUTERNAME
        Status           = 'Installed'
    }
}

function Invoke-KrbtgtExternalProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ($ArgumentList | ForEach-Object {
            if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
        }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start required diagnostic '$FilePath'."
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill()
        }
        catch {
            Write-Verbose "The timed-out diagnostic process could not be terminated cleanly: $($_.Exception.Message)"
        }
        throw "Diagnostic '$FilePath' exceeded its $TimeoutSeconds-second deadline."
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    return [pscustomobject]@{
        FilePath = $FilePath
        Arguments = @($ArgumentList)
        ExitCode = $process.ExitCode
        StandardOutput = $stdout
        StandardError = $stderr
    }
}

function Invoke-KrbtgtDcDiag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DomainController,

        [Parameter(Mandatory)]
        [ValidateSet('DNS', 'Replications', 'Services')]
        [string]$Test
    )

    $arguments = @("/s:$DomainController", "/test:$Test")
    if ($Test -eq 'DNS') {
        $arguments += '/DnsBasic'
    }
    $result = Invoke-KrbtgtExternalProcess -FilePath 'dcdiag.exe' -ArgumentList $arguments -TimeoutSeconds 300
    $combinedOutput = @($result.StandardOutput, $result.StandardError) -join [Environment]::NewLine

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($combinedOutput)) {
        throw "dcdiag $Test failed or returned no parseable output for '$DomainController'."
    }
    if ($combinedOutput -match '(?im)^\s*.*failed test\s+') {
        throw "dcdiag $Test reported a failed test for '$DomainController'."
    }
    if ($combinedOutput -notmatch ("(?im)passed test\s+{0}\b" -f [regex]::Escape($Test))) {
        throw "dcdiag $Test did not contain its required success marker for '$DomainController'."
    }

    return [pscustomobject]@{
        DomainController = $DomainController
        Test             = $Test
        ExitCode         = $result.ExitCode
        Passed           = $true
    }
}

function ConvertFrom-KrbtgtAdInterval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Value -is [TimeSpan]) {
        return ([TimeSpan]$Value).Duration()
    }

    $ticks = 0L
    if (-not [Int64]::TryParse([string]$Value, [ref]$ticks)) {
        throw "Kerberos policy '$Name' is not a parseable AD interval."
    }
    if ($ticks -eq [Int64]::MinValue) {
        throw "Kerberos policy '$Name' is outside the supported interval range."
    }
    return [TimeSpan]::FromTicks([Math]::Abs($ticks))
}

function Get-KrbtgtPolicySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DomainDistinguishedName,

        [Parameter(Mandatory)]
        [string[]]$DomainControllers
    )

    $perDc = foreach ($dc in $DomainControllers) {
        # Query each DC's effective LSA Kerberos policy, which is the same
        # policy data source consumed by the KDC. The domain GPO-link fields
        # and password policy remain independent replication evidence.
        $domainObject = Get-ADObject -Identity $DomainDistinguishedName -Server $dc `
            -Properties gPLink, gPOptions `
            -ErrorAction Stop
        $passwordPolicy = Get-ADDefaultDomainPasswordPolicy -Server $dc -ErrorAction Stop
        $kerberosPolicy = Get-KrbtgtEffectiveKerberosPolicy -DomainController $dc

        $ticket = ConvertFrom-KrbtgtAdInterval -Value $kerberosPolicy.MaxTicketAgeTicks -Name MaxTicketAge
        $service = ConvertFrom-KrbtgtAdInterval `
            -Value $kerberosPolicy.MaxServiceTicketAgeTicks -Name MaxServiceAge
        $renew = ConvertFrom-KrbtgtAdInterval -Value $kerberosPolicy.MaxRenewAgeTicks -Name MaxRenewAge
        $skew = ConvertFrom-KrbtgtAdInterval -Value $kerberosPolicy.MaxClockSkewTicks -Name MaxClockSkew

        if ($ticket.TotalHours -ne $script:ExpectedTicketHours) {
            throw "DC '$dc' reports MaxTicketAge=$($ticket.TotalHours) hours; the approved profile requires exactly $($script:ExpectedTicketHours) hours."
        }
        if ($service -le [TimeSpan]::Zero -or $service -gt $ticket) {
            throw "DC '$dc' reports an invalid MaxServiceAge value."
        }
        if ($skew -le [TimeSpan]::Zero) {
            throw "DC '$dc' reports an invalid MaxClockSkew value."
        }

        [pscustomobject][ordered]@{
            DomainController       = $dc
            MaxTicketAgeMinutes    = [int]$ticket.TotalMinutes
            MaxServiceAgeMinutes   = [int]$service.TotalMinutes
            MaxRenewAgeMinutes     = [int]$renew.TotalMinutes
            MaxClockSkewMinutes    = [int]$skew.TotalMinutes
            AuthenticationOptions  = [uint32]$kerberosPolicy.AuthenticationOptions
            MinPasswordLength      = [int]$passwordPolicy.MinPasswordLength
            ComplexityEnabled      = [bool]$passwordPolicy.ComplexityEnabled
            PasswordHistoryCount   = [int]$passwordPolicy.PasswordHistoryCount
            MinPasswordAgeTicks    = $passwordPolicy.MinPasswordAge.Ticks
            MaxPasswordAgeTicks    = $passwordPolicy.MaxPasswordAge.Ticks
            LockoutThreshold       = [int]$passwordPolicy.LockoutThreshold
            DomainGpLink           = [string]$domainObject.gPLink
            DomainGpOptions        = [int]$domainObject.gPOptions
        }
    }

    $baseline = $perDc[0] | Select-Object -Property * -ExcludeProperty DomainController
    $baselineJson = $baseline | ConvertTo-Json -Compress
    foreach ($item in $perDc) {
        $candidateJson = ($item | Select-Object -Property * -ExcludeProperty DomainController) | ConvertTo-Json -Compress
        if ($candidateJson -cne $baselineJson) {
            throw 'The two DCs returned inconsistent Kerberos or default-domain password policy evidence.'
        }
    }

    return [pscustomobject][ordered]@{
        MaxTicketAgeMinutes  = $perDc[0].MaxTicketAgeMinutes
        MaxServiceAgeMinutes = $perDc[0].MaxServiceAgeMinutes
        MaxRenewAgeMinutes   = $perDc[0].MaxRenewAgeMinutes
        MaxClockSkewMinutes  = $perDc[0].MaxClockSkewMinutes
        PasswordPolicy       = $baseline
        PerDcEvidence        = @($perDc)
    }
}

function Get-KrbtgtMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectDistinguishedName,

        [Parameter(Mandatory)]
        [string]$Server
    )

    $metadata = @(Get-ADReplicationAttributeMetadata -Object $ObjectDistinguishedName -Server $Server `
            -Properties 'pwdLastSet' -ErrorAction Stop)
    $passwordMetadata = @($metadata | Where-Object { $_.AttributeName -eq 'pwdLastSet' })
    if ($passwordMetadata.Count -ne 1) {
        throw "Server '$Server' returned $($passwordMetadata.Count) pwdLastSet metadata records; exactly one is required."
    }

    $item = $passwordMetadata[0]
    if ($null -eq $item.Version -or [int64]$item.Version -lt 1 -or
        $null -eq $item.LastOriginatingChangeDirectoryServerInvocationId -or
        $null -eq $item.LastOriginatingChangeUsn -or
        $null -eq $item.LastOriginatingChangeTime) {
        throw "Server '$Server' returned incomplete pwdLastSet replication metadata."
    }

    return [pscustomobject][ordered]@{
        Server              = $Server
        AttributeName       = 'pwdLastSet'
        Version             = [int64]$item.Version
        OriginatingInvocationId = [string]$item.LastOriginatingChangeDirectoryServerInvocationId
        OriginatingUsn      = [int64]$item.LastOriginatingChangeUsn
        OriginatingChangeUtc = ([DateTime]$item.LastOriginatingChangeTime).ToUniversalTime().ToString('o')
    }
}

function Assert-KrbtgtMetadataMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject[]]$Metadata
    )

    if ($Metadata.Count -ne 2) {
        throw 'Exactly two metadata records are required.'
    }
    $first = $Metadata[0]
    $second = $Metadata[1]
    if ($first.Version -ne $second.Version -or
        $first.OriginatingInvocationId -cne $second.OriginatingInvocationId -or
        $first.OriginatingUsn -ne $second.OriginatingUsn -or
        $first.OriginatingChangeUtc -cne $second.OriginatingChangeUtc) {
        throw 'pwdLastSet replication metadata is not identical on both DCs.'
    }
}

function Assert-KrbtgtMetadataAdvancedOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Before,

        [Parameter(Mandatory)]
        [psobject]$After
    )

    if ($After.Version -ne ($Before.Version + 1)) {
        throw "pwdLastSet metadata advanced from version $($Before.Version) to $($After.Version); exactly one increment was required."
    }
    if ($After.OriginatingInvocationId -eq $Before.OriginatingInvocationId -and
        $After.OriginatingUsn -eq $Before.OriginatingUsn) {
        throw 'pwdLastSet metadata did not record a new originating change.'
    }
}

function Get-KrbtgtTargetEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DomainDistinguishedName,

        [Parameter(Mandatory)]
        [string]$DomainSid,

        [Parameter(Mandatory)]
        [string[]]$DomainControllers
    )

    $expectedSid = "$DomainSid-502"
    # A name match alone is never sufficient for the sensitive target. Resolve
    # by the allowlisted name, require current-domain RID 502, then perform an
    # independent GUID lookup and metadata read on each DC.
    $perDc = foreach ($dc in $DomainControllers) {
        $matchedUsers = @(Get-ADUser -LDAPFilter '(sAMAccountName=krbtgt)' -SearchBase $DomainDistinguishedName `
                -SearchScope Subtree -Server $dc -Properties objectSid, objectGUID, sAMAccountName, Enabled `
                -ErrorAction Stop)
        if ($matchedUsers.Count -ne 1) {
            throw "DC '$dc' returned $($matchedUsers.Count) users with sAMAccountName=krbtgt; exactly one is required."
        }

        $target = $matchedUsers[0]
        $sid = if ($target.SID -is [Security.Principal.SecurityIdentifier]) { $target.SID.Value } else { [string]$target.SID }
        if ($target.SamAccountName -cne 'krbtgt' -or $sid -cne $expectedSid) {
            throw "DC '$dc' did not return the current domain's built-in krbtgt SID/RID 502 identity."
        }
        if (-not $target.DistinguishedName.EndsWith(",$DomainDistinguishedName", [StringComparison]::OrdinalIgnoreCase)) {
            throw "DC '$dc' returned a krbtgt object outside the current domain naming context."
        }
        if ([bool]$target.Enabled) {
            throw "DC '$dc' reports that the built-in krbtgt account is enabled; this unexpected state blocks rotation."
        }

        $objectByGuid = Get-ADObject -Identity $target.ObjectGuid -Server $dc -Properties objectSid, objectGUID `
            -ErrorAction Stop
        $guid = ([guid]$target.ObjectGuid).Guid
        $guidSid = if ($objectByGuid.ObjectSid -is [Security.Principal.SecurityIdentifier]) {
            $objectByGuid.ObjectSid.Value
        }
        else {
            [string]$objectByGuid.ObjectSid
        }
        if (([guid]$objectByGuid.ObjectGuid).Guid -cne $guid -or $guidSid -cne $expectedSid) {
            throw "DC '$dc' failed the krbtgt directory object GUID/SID identity cross-check."
        }

        $metadata = Get-KrbtgtMetadata -ObjectDistinguishedName $target.DistinguishedName -Server $dc
        [pscustomobject][ordered]@{
            Server            = $dc
            SamAccountName    = $target.SamAccountName
            Sid               = $sid
            Rid               = 502
            ObjectGuid        = $guid
            DistinguishedName = $target.DistinguishedName
            Enabled           = [bool]$target.Enabled
            PwdLastSetMetadata = $metadata
        }
    }

    if ($perDc[0].ObjectGuid -cne $perDc[1].ObjectGuid -or
        $perDc[0].DistinguishedName -cne $perDc[1].DistinguishedName -or
        $perDc[0].Sid -cne $perDc[1].Sid) {
        throw 'The two DCs returned inconsistent krbtgt directory identity evidence.'
    }
    Assert-KrbtgtMetadataMatch -Metadata @($perDc.PwdLastSetMetadata)

    return [pscustomobject][ordered]@{
        SamAccountName    = 'krbtgt'
        Sid               = $expectedSid
        Rid               = 502
        ObjectGuid        = $perDc[0].ObjectGuid
        DistinguishedName = $perDc[0].DistinguishedName
        Enabled           = $false
        PerDcEvidence     = @($perDc)
    }
}

function Invoke-KrbtgtTimeCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DomainController,

        [Parameter(Mandatory)]
        [int]$MaximumClockSkewMinutes
    )

    $result = Invoke-KrbtgtExternalProcess -FilePath 'w32tm.exe' `
        -ArgumentList @('/stripchart', "/computer:$DomainController", '/samples:1', '/dataonly') `
        -TimeoutSeconds 30
    $output = @($result.StandardOutput, $result.StandardError) -join [Environment]::NewLine
    if ($result.ExitCode -ne 0 -or $output -notmatch '(?im)(?<offset>[+-]?\d+(?:[\.,]\d+)?)s\s*$') {
        throw "w32tm did not return a parseable clock offset for '$DomainController'."
    }

    $offsetText = $Matches.offset -replace ',', '.'
    $offsetSeconds = [double]::Parse($offsetText, [Globalization.CultureInfo]::InvariantCulture)
    if ([Math]::Abs($offsetSeconds) -ge ($MaximumClockSkewMinutes * 60)) {
        throw "Clock offset for '$DomainController' meets or exceeds the effective Kerberos clock-skew limit."
    }

    return [pscustomobject]@{
        DomainController = $DomainController
        OffsetSeconds    = $offsetSeconds
        Passed           = $true
    }
}

function Assert-KrbtgtRuntime {
    [CmdletBinding()]
    param()

    Assert-KrbtgtLocalSetupPrerequisites
    if (-not (Test-KrbtgtEventSourceRegistration)) {
        throw "The '$($script:EventSource)' source is absent from the System event log. Run the one-time setup script on this DC."
    }
    Assert-KrbtgtEvidenceDirectory | Out-Null

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw 'The Microsoft ActiveDirectory module is not installed. Install it through the enclave prerequisite process; this tool will not install it.'
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    foreach ($commandName in @('dcdiag.exe', 'w32tm.exe', 'Resolve-DnsName')) {
        if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw "Required read-only diagnostic '$commandName' is unavailable."
        }
    }
}

function Get-KrbtgtEnvironmentSnapshot {
    [CmdletBinding()]
    param()

    Assert-KrbtgtRuntime
    $identity = Get-KrbtgtCurrentIdentity
    $domain = Get-ADDomain -Current LocalComputer -ErrorAction Stop
    $domainSid = if ($domain.DomainSID -is [Security.Principal.SecurityIdentifier]) {
        $domain.DomainSID.Value
    }
    else {
        [string]$domain.DomainSID
    }
    if ($identity.GroupSids -notcontains "$domainSid-512") {
        throw "The current signed-in identity '$($identity.Name)' does not have the current domain's Domain Admins SID in its access token."
    }

    $localDc = Get-ADDomainController -Identity $env:COMPUTERNAME -ErrorAction Stop
    $allDcs = @(Get-ADDomainController -Filter * -Server $localDc.HostName -ErrorAction Stop | Sort-Object HostName)
    if ($allDcs.Count -ne 2) {
        throw "The approved profile requires exactly two domain controllers; discovery returned $($allDcs.Count)."
    }
    if (@($allDcs | Where-Object { $_.IsReadOnly }).Count -ne 0) {
        throw 'The approved profile prohibits read-only domain controllers.'
    }
    foreach ($dc in $allDcs) {
        if ([string]$dc.OperatingSystem -notmatch '^Windows Server 2022(?:\s|$)') {
            throw "DC '$($dc.HostName)' is not reported as Windows Server 2022."
        }
    }

    $dcNames = @($allDcs.HostName)
    if ($dcNames -notcontains $localDc.HostName) {
        throw 'This computer is not one of the two discovered writable domain controllers.'
    }
    $otherDc = @($dcNames | Where-Object { $_ -ne $localDc.HostName })
    if ($otherDc.Count -ne 1) {
        throw 'The second writable domain controller could not be identified uniquely.'
    }

    $policy = Get-KrbtgtPolicySnapshot -DomainDistinguishedName $domain.DistinguishedName `
        -DomainControllers $dcNames

    $dnsSrv = @(Resolve-DnsName -Name "_kerberos._tcp.dc._msdcs.$($domain.DNSRoot)" -Type SRV `
            -DnsOnly -ErrorAction Stop)
    $srvTargets = @($dnsSrv | Where-Object { $_.Type -eq 'SRV' } | ForEach-Object {
            ([string]$_.NameTarget).TrimEnd('.').ToLowerInvariant()
        } | Sort-Object -Unique)
    foreach ($dcName in $dcNames) {
        $addresses = @(Resolve-DnsName -Name $dcName -Type A_AAAA -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        if ($addresses.Count -eq 0) {
            throw "DNS returned no IPv4 or IPv6 address for '$dcName'."
        }
        if ($srvTargets -notcontains $dcName.ToLowerInvariant()) {
            throw "The Kerberos DC-locator SRV query did not include '$dcName'."
        }
    }

    $diagnostics = foreach ($dcName in $dcNames) {
        $failures = @(Get-ADReplicationFailure -Target $dcName -Scope Server -ErrorAction Stop)
        if ($failures.Count -ne 0) {
            throw "Active Directory reports $($failures.Count) replication failures for '$dcName'."
        }

        $partners = @(Get-ADReplicationPartnerMetadata -Target $dcName -Scope Server -PartnerType Inbound `
                -ErrorAction Stop | Where-Object { $_.Partition -eq $domain.DistinguishedName })
        if ($partners.Count -lt 1 -or @($partners | Where-Object { $_.LastReplicationResult -ne 0 }).Count -ne 0) {
            throw "Inbound domain-partition replication metadata for '$dcName' is missing or unhealthy."
        }

        $dcDiagResults = @(
            Invoke-KrbtgtDcDiag -DomainController $dcName -Test DNS
            Invoke-KrbtgtDcDiag -DomainController $dcName -Test Replications
            Invoke-KrbtgtDcDiag -DomainController $dcName -Test Services
        )
        $timeResult = Invoke-KrbtgtTimeCheck -DomainController $dcName `
            -MaximumClockSkewMinutes $policy.MaxClockSkewMinutes

        [pscustomobject][ordered]@{
            DomainController      = $dcName
            ReplicationFailures   = 0
            InboundPartners       = $partners.Count
            DcDiag                = $dcDiagResults
            ClockOffsetSeconds    = $timeResult.OffsetSeconds
        }
    }

    $target = Get-KrbtgtTargetEvidence -DomainDistinguishedName $domain.DistinguishedName `
        -DomainSid $domainSid -DomainControllers $dcNames

    return [pscustomobject][ordered]@{
        Status                  = 'Succeeded'
        CapturedUtc             = (Get-KrbtgtUtcNow).ToString('o')
        Operator                = $identity.Name
        ExecutionDc             = $localDc.HostName
        DestinationDc           = $otherDc[0]
        DomainDnsRoot           = $domain.DNSRoot
        DomainDistinguishedName = $domain.DistinguishedName
        DomainSid               = $domainSid
        UsersContainer          = $domain.UsersContainer
        DomainControllers       = @($allDcs | ForEach-Object {
                [pscustomobject]@{
                    HostName        = $_.HostName
                    Site            = $_.Site
                    IsReadOnly      = [bool]$_.IsReadOnly
                    OperatingSystem = $_.OperatingSystem
                }
            })
        KerberosPolicy          = $policy
        Target                  = $target
        Diagnostics             = @($diagnostics)
    }
}

function Get-KrbtgtReceiptObjects {
    [CmdletBinding()]
    param()

    $directory = Assert-KrbtgtEvidenceDirectory
    # A corrupt or foreign JSON file in the protected evidence directory is an
    # audit anomaly. Do not silently skip it while searching for a convenient
    # success receipt; the administrator must preserve and escalate it.
    $receipts = foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction Stop)) {
        try {
            $receipt = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Receipt '$($file.FullName)' is unparseable. Preserve it and escalate before continuing."
        }
        if ($receipt.SchemaVersion -cne $script:ReceiptSchemaVersion -or
            [string]::IsNullOrWhiteSpace([string]$receipt.InvocationId) -or
            [string]::IsNullOrWhiteSpace([string]$receipt.OperationId) -or
            [string]::IsNullOrWhiteSpace([string]$receipt.Phase) -or
            [string]::IsNullOrWhiteSpace([string]$receipt.Status)) {
            throw "Receipt '$($file.FullName)' does not satisfy the required base schema."
        }
        Add-Member -InputObject $receipt -NotePropertyName SourcePath -NotePropertyValue $file.FullName -Force
        $receipt
    }
    return @($receipts)
}

function ConvertTo-KrbtgtUtcDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$FieldName
    )

    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed
        )) {
        throw "Receipt field '$FieldName' is not a parseable round-trip timestamp."
    }
    if ($parsed.Kind -eq [DateTimeKind]::Unspecified) {
        throw "Receipt field '$FieldName' has no UTC/offset designation."
    }
    return $parsed.ToUniversalTime()
}

function Test-KrbtgtStringEqual {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Left,

        [AllowNull()]
        [string]$Right
    )

    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-KrbtgtCurrentPhaseReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject[]]$Receipts,

        [Parameter(Mandatory)]
        [ValidateSet('Preflight', 'Test')]
        [string]$Phase,

        [Parameter(Mandatory)]
        [guid]$OperationId,

        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    $now = Get-KrbtgtUtcNow
    $matchingReceipts = @($Receipts | Where-Object {
            $_.Phase -eq $Phase -and $_.Status -eq 'Succeeded' -and
            $_.OperationId -eq $OperationId.Guid -and
            (Test-KrbtgtStringEqual $_.DomainDnsRoot $Snapshot.DomainDnsRoot) -and
            (Test-KrbtgtStringEqual $_.ExecutionDc $Snapshot.ExecutionDc) -and
            (Test-KrbtgtStringEqual $_.Operator $Snapshot.Operator) -and
            $_.Target.Sid -ceq $Snapshot.Target.Sid -and
            $_.Target.ObjectGuid -ceq $Snapshot.Target.ObjectGuid
        } | Sort-Object { ConvertTo-KrbtgtUtcDate -Value $_.CompletedUtc -FieldName CompletedUtc } -Descending)
    if ($matchingReceipts.Count -eq 0) {
        throw "No successful $Phase receipt matches this operation, domain, execution DC, and operator."
    }

    $receipt = $matchingReceipts[0]
    $completion = ConvertTo-KrbtgtUtcDate -Value $receipt.CompletedUtc -FieldName CompletedUtc
    if ($completion -gt $now) {
        throw "$Phase receipt '$($receipt.InvocationId)' has a completion time in the future."
    }
    if (($now - $completion).TotalMinutes -gt $script:ReceiptLifetimeMinutes) {
        throw "$Phase receipt '$($receipt.InvocationId)' is older than $($script:ReceiptLifetimeMinutes) minutes."
    }

    return $receipt
}

function Assert-KrbtgtPreflightGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid]$OperationId,

        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    $receipts = Get-KrbtgtReceiptObjects
    return Get-KrbtgtCurrentPhaseReceipt -Receipts $receipts -Phase Preflight `
        -OperationId $OperationId -Snapshot $Snapshot
}

function Assert-KrbtgtResetPrerequisiteGates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid]$OperationId,

        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    $receipts = Get-KrbtgtReceiptObjects
    $preflight = Get-KrbtgtCurrentPhaseReceipt -Receipts $receipts -Phase Preflight `
        -OperationId $OperationId -Snapshot $Snapshot
    $test = Get-KrbtgtCurrentPhaseReceipt -Receipts $receipts -Phase Test `
        -OperationId $OperationId -Snapshot $Snapshot

    $preflightCompletion = ConvertTo-KrbtgtUtcDate -Value $preflight.CompletedUtc -FieldName CompletedUtc
    $testCompletion = ConvertTo-KrbtgtUtcDate -Value $test.CompletedUtc -FieldName CompletedUtc
    if ($testCompletion -lt $preflightCompletion) {
        throw 'The successful Test receipt predates its required Preflight receipt.'
    }

    return @($preflight, $test)
}

function Resolve-KrbtgtReset1Receipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    $directory = [IO.Path]::GetFullPath((Assert-KrbtgtEvidenceDirectory)).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Reset 1 receipt must be a local JSON file inside the protected receipt directory.'
    }

    $allReceipts = Get-KrbtgtReceiptObjects
    $reset1 = @($allReceipts | Where-Object {
            [string]::Equals($_.SourcePath, $resolved, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($reset1.Count -ne 1) {
        throw 'The specified Reset 1 receipt was not found exactly once in the protected receipt directory.'
    }
    $selected = $reset1[0]
    if ($selected.Phase -ne 'Reset1' -or $selected.Status -ne 'Succeeded' -or
        -not [bool]$selected.DirectoryMutationAttempted) {
        throw 'The selected receipt is not a successful, verified Reset 1 mutation receipt.'
    }
    if (-not (Test-KrbtgtStringEqual $selected.DomainDnsRoot $Snapshot.DomainDnsRoot) -or
        -not (Test-KrbtgtStringEqual $selected.ExecutionDc $Snapshot.ExecutionDc) -or
        $selected.Target.Sid -cne $Snapshot.Target.Sid -or
        $selected.Target.ObjectGuid -cne $Snapshot.Target.ObjectGuid) {
        throw 'The Reset 1 receipt does not match this domain, execution DC, and exact krbtgt identity.'
    }

    $completion = ConvertTo-KrbtgtUtcDate -Value $selected.CompletedUtc -FieldName CompletedUtc
    $now = Get-KrbtgtUtcNow
    if ($completion -gt $now) {
        throw 'The Reset 1 completion timestamp is in the future; clock evidence is inconsistent.'
    }
    if (($now - $completion).TotalHours -lt $script:Reset2MinimumHours) {
        throw "Reset 2 is blocked until at least $($script:Reset2MinimumHours) hours have elapsed after verified Reset 1 completion."
    }
    if ([int]$selected.KerberosPolicy.MaxTicketAgeMinutes -ne ($script:ExpectedTicketHours * 60)) {
        throw 'The Reset 1 receipt does not contain the approved 10-hour Kerberos policy evidence.'
    }

    $selectedStart = ConvertTo-KrbtgtUtcDate -Value $selected.StartedUtc -FieldName StartedUtc
    $priorCompletedReset2 = @($allReceipts | Where-Object {
            $_.Phase -eq 'Reset2' -and $_.Status -eq 'Succeeded' -and
            (Test-KrbtgtStringEqual $_.DomainDnsRoot $Snapshot.DomainDnsRoot) -and
            (Test-KrbtgtStringEqual $_.ExecutionDc $Snapshot.ExecutionDc) -and
            (ConvertTo-KrbtgtUtcDate -Value $_.CompletedUtc -FieldName CompletedUtc) -lt $selectedStart
        } | Sort-Object { ConvertTo-KrbtgtUtcDate -Value $_.CompletedUtc -FieldName CompletedUtc } -Descending)
    $cycleBoundary = if ($priorCompletedReset2.Count -gt 0) {
        ConvertTo-KrbtgtUtcDate -Value $priorCompletedReset2[0].CompletedUtc -FieldName CompletedUtc
    }
    else {
        [DateTime]::MinValue
    }

    $unresolvedAnomalies = @($allReceipts | Where-Object {
            $_.Phase -eq 'Reset1' -and $_.Status -in @('Failed', 'Running') -and
            [bool]$_.DirectoryMutationAttempted -and
            (Test-KrbtgtStringEqual $_.DomainDnsRoot $Snapshot.DomainDnsRoot) -and
            (Test-KrbtgtStringEqual $_.ExecutionDc $Snapshot.ExecutionDc) -and
            (ConvertTo-KrbtgtUtcDate -Value $_.StartedUtc -FieldName StartedUtc) -gt $cycleBoundary
        })
    if ($unresolvedAnomalies.Count -ne 0) {
        throw 'Reset 2 is prohibited because this rotation cycle contains an unresolved Reset 1 mutation anomaly.'
    }

    $interveningMutations = @($allReceipts | Where-Object {
            $_.InvocationId -ne $selected.InvocationId -and
            $_.Phase -in @('Reset1', 'Reset2') -and [bool]$_.DirectoryMutationAttempted -and
            (Test-KrbtgtStringEqual $_.DomainDnsRoot $Snapshot.DomainDnsRoot) -and
            (Test-KrbtgtStringEqual $_.ExecutionDc $Snapshot.ExecutionDc) -and
            (ConvertTo-KrbtgtUtcDate -Value $_.StartedUtc -FieldName StartedUtc) -gt $completion
        })
    if ($interveningMutations.Count -ne 0) {
        throw 'A production mutation receipt exists after the selected Reset 1 receipt; its state is no longer authoritative.'
    }

    return $selected
}

function Get-KrbtgtRandomIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Security.Cryptography.RandomNumberGenerator]$Generator,

        [Parameter(Mandatory)]
        [ValidateRange(1, 1000)]
        [int]$UpperExclusive
    )

    $buffer = [byte[]]::new(4)
    $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$UpperExclusive)
    do {
        $Generator.GetBytes($buffer)
        $value = [BitConverter]::ToUInt32($buffer, 0)
    } while ($value -ge $limit)
    return [int]($value % [uint32]$UpperExclusive)
}

function New-KrbtgtSecurePassword {
    [CmdletBinding()]
    param()

    # Each class is seeded deliberately, then the whole 64-character sequence is
    # shuffled with a cryptographic RNG. The plaintext character array is cleared
    # immediately after it is copied into SecureString.
    $classes = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!#$%&()*+,-./:;<=>?@[]^_{|}~'
    )
    $all = ($classes -join '')
    $characters = [char[]]::new(64)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($index = 0; $index -lt $classes.Count; $index++) {
            $characters[$index] = $classes[$index][(Get-KrbtgtRandomIndex -Generator $rng -UpperExclusive $classes[$index].Length)]
        }
        for ($index = $classes.Count; $index -lt $characters.Length; $index++) {
            $characters[$index] = $all[(Get-KrbtgtRandomIndex -Generator $rng -UpperExclusive $all.Length)]
        }
        for ($index = $characters.Length - 1; $index -gt 0; $index--) {
            $swapIndex = Get-KrbtgtRandomIndex -Generator $rng -UpperExclusive ($index + 1)
            $temporary = $characters[$index]
            $characters[$index] = $characters[$swapIndex]
            $characters[$swapIndex] = $temporary
        }

        $secure = [Security.SecureString]::new()
        foreach ($character in $characters) {
            $secure.AppendChar($character)
        }
        $secure.MakeReadOnly()
        return $secure
    }
    finally {
        [Array]::Clear($characters, 0, $characters.Length)
        $rng.Dispose()
    }
}

function Set-KrbtgtAccountPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistinguishedName,

        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [Security.SecureString]$NewPassword
    )

    Set-ADAccountPassword -Identity $DistinguishedName -Server $Server -Reset `
        -NewPassword $NewPassword -Confirm:$false -ErrorAction Stop
}

function Sync-KrbtgtObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    Sync-ADObject -Object $Object -Source $Source -Destination $Destination -ErrorAction Stop
}

function Wait-KrbtgtMetadataConvergence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectDistinguishedName,

        [Parameter(Mandatory)]
        [psobject]$ExpectedMetadata,

        [Parameter(Mandatory)]
        [string[]]$DomainControllers,

        [int]$TimeoutSeconds = $script:ConvergenceTimeoutSeconds,

        [int]$PollIntervalSeconds = $script:PollIntervalSeconds
    )

    $deadline = (Get-KrbtgtUtcNow).AddSeconds($TimeoutSeconds)
    do {
        $records = @()
        $readFailure = $false
        foreach ($dc in $DomainControllers) {
            try {
                $records += Get-KrbtgtMetadata -ObjectDistinguishedName $ObjectDistinguishedName -Server $dc
            }
            catch {
                $readFailure = $true
                break
            }
        }

        if (-not $readFailure -and $records.Count -eq 2) {
            $matchingRecords = @($records | Where-Object {
                    $_.Version -eq $ExpectedMetadata.Version -and
                    $_.OriginatingInvocationId -ceq $ExpectedMetadata.OriginatingInvocationId -and
                    $_.OriginatingUsn -eq $ExpectedMetadata.OriginatingUsn -and
                    $_.OriginatingChangeUtc -ceq $ExpectedMetadata.OriginatingChangeUtc
                })
            if ($matchingRecords.Count -eq 2) {
                return $records
            }
        }

        if ((Get-KrbtgtUtcNow) -ge $deadline) {
            break
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)

    throw "pwdLastSet metadata did not converge on both DCs within $TimeoutSeconds seconds."
}

function New-KrbtgtTemporaryUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Server
    )

    return New-ADUser -Name $Name -SamAccountName $Name -Path $Path -Enabled $false `
        -Description 'KrbtgtRotation disposable replication-path test account' -Server $Server `
        -PassThru -ErrorAction Stop
}

function Remove-KrbtgtTemporaryUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Identity,

        [Parameter(Mandatory)]
        [string]$Server
    )

    Remove-ADUser -Identity $Identity -Server $Server -Confirm:$false -ErrorAction Stop
}

function Get-KrbtgtDeletedObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid]$ObjectGuid,

        [Parameter(Mandatory)]
        [string]$Server
    )

    return Get-ADObject -Identity $ObjectGuid -Server $Server -IncludeDeletedObjects `
        -Properties objectGUID, isDeleted -ErrorAction Stop
}

function Wait-KrbtgtObjectCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid]$ObjectGuid,

        [Parameter(Mandatory)]
        [string[]]$DomainControllers,

        [int]$TimeoutSeconds = $script:ConvergenceTimeoutSeconds,

        [int]$PollIntervalSeconds = $script:PollIntervalSeconds
    )

    $deadline = (Get-KrbtgtUtcNow).AddSeconds($TimeoutSeconds)
    do {
        $present = @()
        foreach ($dc in $DomainControllers) {
            try {
                Get-ADObject -Identity $ObjectGuid -Server $dc -ErrorAction Stop | Out-Null
                $present += $dc
            }
            catch {
                if ($_.Exception.GetType().FullName -ne 'Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException') {
                    throw
                }
                Write-Verbose "Live object '$($ObjectGuid.Guid)' is absent from '$dc', as required for cleanup."
            }
        }
        if ($present.Count -eq 0) {
            return [pscustomobject]@{
                ObjectGuid        = $ObjectGuid.Guid
                DomainControllers = @($DomainControllers)
                Present           = $false
            }
        }
        if ((Get-KrbtgtUtcNow) -ge $deadline) {
            break
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)

    throw "Temporary test user cleanup did not converge on both DCs within $TimeoutSeconds seconds."
}

function Invoke-KrbtgtPreflight {
    <#
    .SYNOPSIS
    Runs the mandatory strictly directory-read-only Preflight phase.
    .DESCRIPTION
    Validates the fixed two-DC Windows Server 2022 profile and writes local
    System-log/JSON evidence. It never changes Active Directory or forces
    replication. A successful receipt expires after 30 minutes.
    .PARAMETER OperationId
    Rotation-stage identifier shared by Preflight, Test, and one reset phase.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid]$OperationId
    )

    $receipt = New-KrbtgtReceipt -Phase Preflight -OperationId $OperationId
    try {
        $snapshot = Get-KrbtgtEnvironmentSnapshot
        Set-KrbtgtReceiptContext -Receipt $receipt -Snapshot $snapshot
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'Preflight' -Status Succeeded `
            -Summary 'All approved read-only topology, identity, policy, DNS, service, time, replication, metadata, and dcdiag checks passed.' `
            -Evidence $snapshot.Diagnostics
        Complete-KrbtgtReceipt -Receipt $receipt -Status Succeeded -ErrorRecord $null | Out-Null
        Write-KrbtgtEvent -EventId 1100 -EntryType Information -Receipt $receipt `
            -Message 'Preflight succeeded. This receipt is valid for 30 minutes.'
        return $receipt
    }
    catch {
        Write-KrbtgtFailureEvidence -Receipt $receipt -ErrorRecord $_ -EventId 1101
        throw
    }
}

function Invoke-KrbtgtTest {
    <#
    .SYNOPSIS
    Runs the mandatory state-changing temporary-user Test phase.
    .DESCRIPTION
    Creates one disabled user, resets its password through the production
    adapter, verifies bounded one-object replication, deletes it, and verifies
    cleanup. It requires a current matching Preflight receipt.
    .PARAMETER OperationId
    Rotation-stage identifier shared by Preflight, Test, and one reset phase.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid]$OperationId
    )

    $receipt = New-KrbtgtReceipt -Phase Test -OperationId $OperationId
    try {
        $snapshot = Get-KrbtgtEnvironmentSnapshot
        Set-KrbtgtReceiptContext -Receipt $receipt -Snapshot $snapshot
        $preflight = Assert-KrbtgtPreflightGate -OperationId $OperationId -Snapshot $snapshot
        $receipt.PrerequisiteReceipts = @($preflight.InvocationId)
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'PreflightReceiptGate' -Status Succeeded `
            -Summary 'A current matching Preflight receipt was validated.' -Evidence $preflight.InvocationId

        $temporaryName = 'KRT-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 16))
        $receipt.DirectoryMutationAttempted = $true
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'TemporaryUserPlan' -Status Succeeded `
            -Summary 'Recorded the unique disabled temporary-user name before any Test write.' `
            -Evidence ([pscustomobject]@{ Name = $temporaryName; Path = $snapshot.UsersContainer })
        Save-KrbtgtReceipt -Receipt $receipt | Out-Null
        Write-KrbtgtEvent -EventId 1200 -EntryType Information -Receipt $receipt `
            -Message "Temporary-user Test mutation started for '$temporaryName'."

        $temporaryUser = New-KrbtgtTemporaryUser -Name $temporaryName -Path $snapshot.UsersContainer `
            -Server $snapshot.ExecutionDc
        $temporaryGuid = [guid]$temporaryUser.ObjectGuid
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'CreateTemporaryUser' -Status Succeeded `
            -Summary 'Created one uniquely named disabled temporary user.' `
            -Evidence ([pscustomobject]@{ Name = $temporaryName; ObjectGuid = $temporaryGuid.Guid })
        Save-KrbtgtReceipt -Receipt $receipt | Out-Null

        Sync-KrbtgtObject -Object $temporaryUser.DistinguishedName -Source $snapshot.ExecutionDc `
            -Destination $snapshot.DestinationDc
        $before = Get-KrbtgtMetadata -ObjectDistinguishedName $temporaryUser.DistinguishedName `
            -Server $snapshot.ExecutionDc

        $password = New-KrbtgtSecurePassword
        try {
            Set-KrbtgtAccountPassword -DistinguishedName $temporaryUser.DistinguishedName `
                -Server $snapshot.ExecutionDc -NewPassword $password
        }
        finally {
            $password.Dispose()
        }

        $after = Get-KrbtgtMetadata -ObjectDistinguishedName $temporaryUser.DistinguishedName `
            -Server $snapshot.ExecutionDc
        Assert-KrbtgtMetadataAdvancedOnce -Before $before -After $after
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'ResetTemporaryUserPassword' -Status Succeeded `
            -Summary 'The shared password-reset adapter advanced pwdLastSet metadata exactly once.' -Evidence $after
        Save-KrbtgtReceipt -Receipt $receipt | Out-Null

        Sync-KrbtgtObject -Object $temporaryUser.DistinguishedName -Source $snapshot.ExecutionDc `
            -Destination $snapshot.DestinationDc
        $converged = Wait-KrbtgtMetadataConvergence -ObjectDistinguishedName $temporaryUser.DistinguishedName `
            -ExpectedMetadata $after -DomainControllers @($snapshot.ExecutionDc, $snapshot.DestinationDc)
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'ReplicateTemporaryUser' -Status Succeeded `
            -Summary 'Targeted single-object password metadata converged on both DCs.' -Evidence $converged
        Save-KrbtgtReceipt -Receipt $receipt | Out-Null

        Remove-KrbtgtTemporaryUser -Identity $temporaryUser -Server $snapshot.ExecutionDc
        $deletedObject = Get-KrbtgtDeletedObject -ObjectGuid $temporaryGuid -Server $snapshot.ExecutionDc
        Sync-KrbtgtObject -Object $deletedObject -Source $snapshot.ExecutionDc -Destination $snapshot.DestinationDc
        $cleanup = Wait-KrbtgtObjectCleanup -ObjectGuid $temporaryGuid `
            -DomainControllers @($snapshot.ExecutionDc, $snapshot.DestinationDc)
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'DeleteTemporaryUser' -Status Succeeded `
            -Summary 'The temporary user was deleted and its live-object absence was verified on both DCs.' `
            -Evidence $cleanup

        Complete-KrbtgtReceipt -Receipt $receipt -Status Succeeded -ErrorRecord $null | Out-Null
        Write-KrbtgtEvent -EventId 1201 -EntryType Information -Receipt $receipt `
            -Message 'Temporary-user Test succeeded and cleanup was verified. This receipt is valid for 30 minutes.'
        return $receipt
    }
    catch {
        Write-KrbtgtFailureEvidence -Receipt $receipt -ErrorRecord $_ -EventId 1202
        throw
    }
}

function Invoke-KrbtgtReset {
    <#
    .SYNOPSIS
    Performs exactly one verified Reset 1 or Reset 2 password change.
    .DESCRIPTION
    Requires current matching Preflight and Test receipts, shows the exact
    validated RID-502 target, requires typed confirmation, performs one password
    write, forces one-object replication, and reruns all post-checks. Native
    -WhatIf runs the read-only gates and writes local evidence without an AD write.
    .PARAMETER Phase
    Reset1 or Reset2. One invocation performs only the selected phase.
    .PARAMETER OperationId
    Rotation-stage identifier shared by this reset and its Preflight/Test pair.
    .PARAMETER Reset1ReceiptPath
    For Reset2 only, the explicit verified Reset1 receipt in the protected local directory.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Reset1', 'Reset2')]
        [string]$Phase,

        [Parameter(Mandatory)]
        [guid]$OperationId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Reset1ReceiptPath
    )

    $receipt = New-KrbtgtReceipt -Phase $Phase -OperationId $OperationId
    try {
        if ($Phase -eq 'Reset1' -and $PSBoundParameters.ContainsKey('Reset1ReceiptPath')) {
            throw 'Reset1ReceiptPath is valid only for Reset2.'
        }
        if ($Phase -eq 'Reset2' -and -not $PSBoundParameters.ContainsKey('Reset1ReceiptPath')) {
            throw 'Reset2 requires the explicit local path of its verified Reset1 receipt.'
        }

        $snapshot = Get-KrbtgtEnvironmentSnapshot
        Set-KrbtgtReceiptContext -Receipt $receipt -Snapshot $snapshot
        $prerequisites = Assert-KrbtgtResetPrerequisiteGates -OperationId $OperationId -Snapshot $snapshot
        $receipt.PrerequisiteReceipts = @($prerequisites.InvocationId)

        if ($Phase -eq 'Reset2') {
            $reset1 = Resolve-KrbtgtReset1Receipt -Path $Reset1ReceiptPath -Snapshot $snapshot
            $receipt.PrerequisiteReceipts += $reset1.InvocationId
        }

        $resetNumber = if ($Phase -eq 'Reset1') { 1 } else { 2 }
        $targetDescription = '{0} ({1}, SID {2}, GUID {3}) on {4}' -f `
            $snapshot.Target.DistinguishedName,
            $snapshot.Target.SamAccountName,
            $snapshot.Target.Sid,
            $snapshot.Target.ObjectGuid,
            $snapshot.ExecutionDc
        Write-Host "Exact target: $targetDescription"

        if (-not $PSCmdlet.ShouldProcess($targetDescription, "Perform exactly one KRBTGT password reset (Reset $resetNumber)")) {
            Add-KrbtgtReceiptStage -Receipt $receipt -Name 'WhatIfPreview' -Status WhatIf `
                -Summary 'Read-only preview completed; no password, directory-object, cleanup, or replication write was attempted.' `
                -Evidence ([pscustomobject]@{ ResetNumber = $resetNumber; Target = $targetDescription })
            Complete-KrbtgtReceipt -Receipt $receipt -Status WhatIf -ErrorRecord $null | Out-Null
            Write-KrbtgtEvent -EventId 1600 -EntryType Information -Receipt $receipt `
                -Message "WhatIf preview completed for Reset $resetNumber; no directory write was attempted."
            return $receipt
        }

        $requiredPhrase = '{0} RESET {1}' -f $snapshot.DomainDnsRoot, $resetNumber
        Write-Host "Required confirmation: $requiredPhrase"
        $typedPhrase = Read-Host 'Type the exact confirmation shown above'
        if (-not [string]::Equals($typedPhrase, $requiredPhrase, [StringComparison]::Ordinal)) {
            throw 'Typed confirmation did not exactly match the displayed domain-and-phase phrase.'
        }
        $receipt.ConfirmationAccepted = $true
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'TypedConfirmation' -Status Succeeded `
            -Summary 'The operator typed the exact case-sensitive domain-and-phase confirmation.' `
            -Evidence $requiredPhrase
        Write-KrbtgtEvent -EventId 1300 -EntryType Information -Receipt $receipt `
            -Message "Exact typed confirmation accepted for Reset $resetNumber."

        $sourceBefore = @($snapshot.Target.PerDcEvidence | Where-Object {
                $_.Server -eq $snapshot.ExecutionDc
            })[0].PwdLastSetMetadata

        # Checkpoint the receipt before the sensitive call. If the process stops
        # abruptly, later Reset 2 gating sees that a mutation was attempted.
        $receipt.DirectoryMutationAttempted = $true
        Save-KrbtgtReceipt -Receipt $receipt | Out-Null
        Write-KrbtgtEvent -EventId 1301 -EntryType Warning -Receipt $receipt `
            -Message "Exactly one KRBTGT password reset is now being attempted for Reset $resetNumber."

        $password = New-KrbtgtSecurePassword
        try {
            Set-KrbtgtAccountPassword -DistinguishedName $snapshot.Target.DistinguishedName `
                -Server $snapshot.ExecutionDc -NewPassword $password
        }
        finally {
            $password.Dispose()
        }

        $sourceAfter = Get-KrbtgtMetadata -ObjectDistinguishedName $snapshot.Target.DistinguishedName `
            -Server $snapshot.ExecutionDc
        Assert-KrbtgtMetadataAdvancedOnce -Before $sourceBefore -After $sourceAfter
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'PasswordReset' -Status Succeeded `
            -Summary 'The source-DC pwdLastSet metadata advanced exactly once.' -Evidence $sourceAfter
        Save-KrbtgtReceipt -Receipt $receipt | Out-Null

        Sync-KrbtgtObject -Object $snapshot.Target.DistinguishedName -Source $snapshot.ExecutionDc `
            -Destination $snapshot.DestinationDc
        $converged = Wait-KrbtgtMetadataConvergence -ObjectDistinguishedName $snapshot.Target.DistinguishedName `
            -ExpectedMetadata $sourceAfter -DomainControllers @($snapshot.ExecutionDc, $snapshot.DestinationDc)
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'TargetedReplication' -Status Succeeded `
            -Summary 'The one-object KRBTGT change converged on both DCs within the fixed deadline.' -Evidence $converged
        Save-KrbtgtReceipt -Receipt $receipt | Out-Null

        $postSnapshot = Get-KrbtgtEnvironmentSnapshot
        $postSource = @($postSnapshot.Target.PerDcEvidence | Where-Object {
                $_.Server -eq $postSnapshot.ExecutionDc
            })[0].PwdLastSetMetadata
        if ($postSource.Version -ne $sourceAfter.Version -or
            $postSource.OriginatingInvocationId -cne $sourceAfter.OriginatingInvocationId -or
            $postSource.OriginatingUsn -ne $sourceAfter.OriginatingUsn) {
            throw 'Post-check metadata differs from the single verified password change.'
        }
        Add-KrbtgtReceiptStage -Receipt $receipt -Name 'PostChecks' -Status Succeeded `
            -Summary 'Two-DC identity, policy, DNS, time, KDC/service, replication, metadata, and dcdiag post-checks passed.' `
            -Evidence $postSnapshot.Diagnostics

        Complete-KrbtgtReceipt -Receipt $receipt -Status Succeeded -ErrorRecord $null | Out-Null
        $eventId = if ($Phase -eq 'Reset1') { 1400 } else { 1500 }
        Write-KrbtgtEvent -EventId $eventId -EntryType Information -Receipt $receipt `
            -Message "Reset $resetNumber succeeded with exactly one password write and verified two-DC convergence."
        return $receipt
    }
    catch {
        $eventId = if ($Phase -eq 'Reset1') { 1401 } else { 1501 }
        Write-KrbtgtFailureEvidence -Receipt $receipt -ErrorRecord $_ -EventId $eventId
        throw
    }
}

Export-ModuleMember -Function @(
    'Install-KrbtgtRotationLocalSetup',
    'Invoke-KrbtgtPreflight',
    'Invoke-KrbtgtTest',
    'Invoke-KrbtgtReset'
)
