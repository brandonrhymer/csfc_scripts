#Requires -Version 5.1
# Isolated evidence-policy regressions. No operational module or entrypoint runs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Run this suite in a fresh Windows PowerShell 5.1 process.'
}

$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'windows/reset-krbtgt/KrbtgtRotation/KrbtgtRotation.psm1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The KRBTGT module has parser errors.' }
$guards = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Assert-KrbtgtEvidenceDirectory'
}, $true))
if ($guards.Count -ne 1) { throw 'Expected one production receipt-directory guard.' }
$guard = $guards[0]

# Fail before execution if the extracted guard gains an unreviewed command or
# method boundary. All filesystem commands below are replaced with local fakes.
foreach ($command in @($guard.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
    if ($command.GetCommandName() -notin @('Get-KrbtgtReceiptDirectory', 'Test-Path', 'Get-Acl', 'Where-Object')) {
        throw 'The receipt guard has an unreviewed command boundary; extend isolation before running it.'
    }
}
foreach ($method in @($guard.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
    if ($method.Member.Value -notin @('Translate', 'GetAccessRules')) {
        throw 'The receipt guard has an unreviewed method boundary; extend isolation before running it.'
    }
}

& {
    param($guardSource)
    . ([scriptblock]::Create($guardSource))
    $script:receiptGuardPath = 'C:\Synthetic\KrbtgtReceiptGuard'
    $script:receiptGuardCases = 0
    $script:receiptGuardAcl = $null
    $script:receiptGuardExists = $true
    $script:receiptGuardReadFails = $false
    $script:receiptGuardPathCalls = 0
    $script:receiptGuardAclCalls = 0

    function Get-KrbtgtReceiptDirectory { $script:receiptGuardPath }
    function Test-Path {
        param([string]$LiteralPath, [string]$PathType)
        if ($LiteralPath -cne $script:receiptGuardPath -or $PathType -cne 'Container') {
            throw 'Unexpected synthetic path lookup.'
        }
        $script:receiptGuardPathCalls++
        return $script:receiptGuardExists
    }
    function Get-Acl {
        param([string]$LiteralPath)
        if ($LiteralPath -cne $script:receiptGuardPath) { throw 'Unexpected synthetic ACL lookup.' }
        $script:receiptGuardAclCalls++
        if ($script:receiptGuardReadFails) { throw 'Synthetic ACL read denied.' }
        return $script:receiptGuardAcl
    }

    function New-TestAcl {
        param(
            [string]$OwnerSid = 'S-1-5-32-544',
            [bool]$Protected = $true,
            [Security.AccessControl.FileSystemRights]$AdministratorRights = 'FullControl',
            [Security.AccessControl.FileSystemRights]$SystemRights = 'FullControl',
            [switch]$OmitAdministrators,
            [switch]$OmitSystem,
            [string]$AdditionalSid,
            [Security.AccessControl.FileSystemRights]$AdditionalRights = 'Read'
        )
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($Protected, $false)
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($OwnerSid))
        $entries = @()
        if (-not $OmitAdministrators) { $entries += @{ Sid = 'S-1-5-32-544'; Rights = $AdministratorRights } }
        if (-not $OmitSystem) { $entries += @{ Sid = 'S-1-5-18'; Rights = $SystemRights } }
        if ($AdditionalSid) { $entries += @{ Sid = $AdditionalSid; Rights = $AdditionalRights } }
        foreach ($entry in $entries) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($entry.Sid),
                [Security.AccessControl.FileSystemRights]$entry.Rights,
                [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            ))
        }
        return $acl
    }

    function Test-GuardCase {
        param(
            [string]$Name,
            [Security.AccessControl.DirectorySecurity]$Acl,
            [string]$ExpectedError,
            [bool]$DirectoryExists = $true,
            [switch]$ReadFails
        )
        $script:receiptGuardAcl = $Acl
        $script:receiptGuardExists = $DirectoryExists
        $script:receiptGuardReadFails = [bool]$ReadFails
        $script:receiptGuardPathCalls = 0
        $script:receiptGuardAclCalls = 0
        $before = $Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        $result = $null
        $errorMessage = $null
        try { $result = Assert-KrbtgtEvidenceDirectory }
        catch { $errorMessage = $_.Exception.Message }

        if ($ExpectedError) {
            if (-not $errorMessage -or $errorMessage -notlike $ExpectedError) {
                throw "Case '$Name' did not reject for its expected reason: $errorMessage"
            }
        }
        elseif ($errorMessage -or $result -cne $script:receiptGuardPath) {
            throw "Case '$Name' did not accept the documented policy: $errorMessage"
        }
        $expectedAclCalls = 0
        if ($DirectoryExists) { $expectedAclCalls = 1 }
        if ($script:receiptGuardPathCalls -ne 1 -or $script:receiptGuardAclCalls -ne $expectedAclCalls) {
            throw "Case '$Name' crossed an unexpected fake boundary."
        }
        if ($before -cne $Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)) {
            throw "Case '$Name' changed its in-memory input ACL."
        }
        $script:receiptGuardCases++
        Write-Output "PASS: receipt ACL / $Name"
    }

    Test-GuardCase -Name 'Administrators owner accepted' -Acl (New-TestAcl)
    Test-GuardCase -Name 'SYSTEM owner accepted' -Acl (New-TestAcl -OwnerSid 'S-1-5-18')
    Test-GuardCase -Name 'extra read-only Allow rejected' -Acl (New-TestAcl -AdditionalSid 'S-1-5-21-100-200-300-1234') -ExpectedError '*grants access to unexpected identity*'
    Test-GuardCase -Name 'extra FullControl Allow rejected' -Acl (New-TestAcl -AdditionalSid 'S-1-5-21-100-200-300-1234' -AdditionalRights FullControl) -ExpectedError '*grants access to unexpected identity*'
    Test-GuardCase -Name 'inheritance rejected' -Acl (New-TestAcl -Protected $false) -ExpectedError '*inherits permissions*'
    Test-GuardCase -Name 'unexpected owner rejected' -Acl (New-TestAcl -OwnerSid 'S-1-1-0') -ExpectedError '*is neither Administrators nor SYSTEM*'
    Test-GuardCase -Name 'missing SYSTEM rejected' -Acl (New-TestAcl -OmitSystem) -ExpectedError '*does not grant FullControl to required identity*'
    Test-GuardCase -Name 'missing Administrators rejected' -Acl (New-TestAcl -OmitAdministrators) -ExpectedError '*does not grant FullControl to required identity*'
    Test-GuardCase -Name 'insufficient SYSTEM rights rejected' -Acl (New-TestAcl -SystemRights Read) -ExpectedError '*does not grant FullControl to required identity*'
    Test-GuardCase -Name 'insufficient Administrators rights rejected' -Acl (New-TestAcl -AdministratorRights Read) -ExpectedError '*does not grant FullControl to required identity*'
    Test-GuardCase -Name 'absent directory stops before ACL read' -Acl (New-TestAcl) -DirectoryExists $false -ExpectedError '*is absent*'
    Test-GuardCase -Name 'ACL read failure propagates' -Acl (New-TestAcl) -ReadFails -ExpectedError 'Synthetic ACL read denied.'
    if ($script:receiptGuardCases -ne 12) { throw 'Receipt-guard case count mismatch.' }
    Write-Output ('PASS: {0} KRBTGT receipt ACL cases; in-memory ACLs and fake filesystem reads only.' -f $script:receiptGuardCases)
} $guard.Extent.Text
exit 0
