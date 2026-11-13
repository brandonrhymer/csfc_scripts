#requires -Version 5.1
# Local synthetic filesystem fixtures; WSUS and Robocopy are never executed.
# Run in a fresh Windows PowerShell process so command mocks cannot leak.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\scripts\wsus-export.ps1'
# Hosted TEMP can itself use an 8.3 alias (for example RUNNER~1). Canonicalize
# fixture setup only; deliberate alias probes below still exercise production rejection.
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class CsfcWsusFixtureNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetLongPathName(string path, StringBuilder target, int length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetShortPathName(string path, StringBuilder target, int length);
}
'@
$longTemp = New-Object Text.StringBuilder 32768
$longTempSize = [CsfcWsusFixtureNative]::GetLongPathName([IO.Path]::GetTempPath(), $longTemp, $longTemp.Capacity)
if ($longTempSize -eq 0 -or $longTempSize -ge $longTemp.Capacity) { throw 'Cannot obtain the fixture parent long path.' }
$fixtureParent = $longTemp.ToString().TrimEnd('\')
$fixtureName = 'csfc-wsus-test-' + [guid]::NewGuid().ToString('N')
$fixture = Join-Path $fixtureParent $fixtureName
$source = Join-Path $fixture 'Long Content Folder'
$exports = Join-Path $fixture 'Transfer Parent'
$fakeProgramFiles = Join-Path $fixture 'Program Files'
$fakeUtil = Join-Path $fakeProgramFiles 'Update Services\Tools\WsusUtil.exe'
$savedProgramFiles = $env:ProgramFiles
$junctions = @()
$aliasDrive = $null
$global:WsusFixture = @{ Writes=@(); ExportExit=0; CopyExit=1; OmitMetadata=$false; Source=$source; Target=$null }

function New-Item {
    [CmdletBinding()]
    param([string]$Path, [string]$ItemType)
    $global:WsusFixture.Writes += 'mkdir'
    Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -ErrorAction Stop
}
function robocopy.exe {
    $global:WsusFixture.Writes += 'copy'
    if ($args.Count -ne 8 -or $args[0] -cne $global:WsusFixture.Source -or
        $args[1] -cne (Join-Path $global:WsusFixture.Target 'WsusContent') -or
        ($args[2..7] -join '|') -cne '/E|/COPY:DAT|/R:2|/W:2|/XJ|/LOG:' + $global:WsusFixture.Target + '\copy.log') {
        throw 'Unexpected additive copy arguments.'
    }
    $global:LASTEXITCODE = $global:WsusFixture.CopyExit
}
function Reset-FixtureCalls {
    $global:WsusFixture.Writes = @()
    $global:WsusFixture.ExportExit = 0
    $global:WsusFixture.CopyExit = 1
    $global:WsusFixture.OmitMetadata = $false
}
function Assert-Rejected {
    param([string]$Label, [string]$InputSource, [string]$InputTarget, [string]$Expected)
    Reset-FixtureCalls
    $rejected = $false
    try { & $scriptPath -ContentPath $InputSource -Destination $InputTarget } catch {
        if ($_.Exception.Message -notmatch $Expected) { throw "Unexpected rejection for ${Label}: $($_.Exception.Message)" }
        $rejected = $true
    }
    if (-not $rejected) { throw "Accepted unsafe path: $Label" }
    if ($global:WsusFixture.Writes.Count) { throw "Unsafe path wrote output: $Label" }
    Write-Output "PASS: $Label rejected before export writes"
}

try {
    $null = Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $source, $exports, ([IO.Path]::GetDirectoryName($fakeUtil))
    [IO.File]::WriteAllText((Join-Path $source 'content.txt'), 'synthetic WSUS content')
    [IO.File]::WriteAllText($fakeUtil, 'inert marker; command is mocked')
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $source 'content.txt') -Algorithm SHA256).Hash
    $env:ProgramFiles = $fakeProgramFiles
    Set-Item -LiteralPath ('Function:\' + $fakeUtil) -Value {
        param([string]$Operation, [string]$Metadata, [string]$Log)
        $global:WsusFixture.Writes += 'export'
        if ($Operation -cne 'export' -or $Metadata -cne (Join-Path $global:WsusFixture.Target 'metadata.xml.gz') -or
            $Log -cne (Join-Path $global:WsusFixture.Target 'export.log')) { throw 'Unexpected export arguments.' }
        if ($global:WsusFixture.ExportExit -eq 0 -and -not $global:WsusFixture.OmitMetadata) {
            [IO.File]::WriteAllText($Metadata, 'synthetic metadata')
        }
        $global:LASTEXITCODE = $global:WsusFixture.ExportExit
    }

    $target = Join-Path $exports 'new transfer'
    Assert-Rejected 'relative source' '.\Long Content Folder' $target 'absolute local drive-letter'
    Assert-Rejected 'relative destination' $source '.\new transfer' 'absolute local drive-letter'
    Assert-Rejected 'drive-relative destination' $source ($target.Substring(0, 2) + 'relative') 'absolute local drive-letter'
    Assert-Rejected 'root-relative destination' $source '\relative' 'absolute local drive-letter'
    Assert-Rejected 'UNC source' '\\server.example.invalid\share\content' $target 'absolute local drive-letter'
    Assert-Rejected 'device destination' $source ('\\?\' + $target) 'absolute local drive-letter'
    Assert-Rejected 'provider destination' $source ('FileSystem::' + $target) 'absolute local drive-letter'
    Assert-Rejected 'dot segment' $source (Join-Path $exports '..\new transfer') 'Path components'
    Assert-Rejected 'trailing dot' $source ($target + '.') 'Path components'
    Assert-Rejected 'trailing space' $source ($target + ' ') 'Path components'
    Assert-Rejected 'reserved device name' $source (Join-Path $exports 'NUL.txt') 'Path components'
    Assert-Rejected 'wildcard syntax' $source (Join-Path $exports 'transfer[1]') 'absolute local drive-letter'
    Assert-Rejected 'equal paths' $source $source 'separate directory trees'
    Assert-Rejected 'case-insensitive equal paths' $source ($source.ToUpperInvariant() + '\') 'separate directory trees'
    Assert-Rejected 'destination below source' $source (Join-Path $source 'transfer') 'separate directory trees'
    Assert-Rejected 'destination above source' $source $fixture 'separate directory trees'
    Assert-Rejected 'nonexistent destination parent' $source (Join-Path $exports 'missing\transfer') 'Cannot find path'
    Assert-Rejected 'file instead of content directory' (Join-Path $source 'content.txt') $target 'must be a directory'

    $prior = Join-Path $exports 'prior transfer'
    $null = Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $prior
    [IO.File]::WriteAllText((Join-Path $prior 'keep.txt'), 'prior transfer')
    Assert-Rejected 'existing transfer' $source $prior 'Destination already exists'
    if ([IO.File]::ReadAllText((Join-Path $prior 'keep.txt')) -cne 'prior transfer') { throw 'Prior transfer was modified.' }

    $sourceAlias = Join-Path $fixture 'source junction'
    $junctions += $sourceAlias
    $null = Microsoft.PowerShell.Management\New-Item -ItemType Junction -Path $sourceAlias -Target $source
    Assert-Rejected 'junction source' $sourceAlias $target 'Reparse points'
    Assert-Rejected 'destination under junction' $source (Join-Path $sourceAlias 'transfer') 'Reparse points'

    $parentAlias = Join-Path $fixture 'destination parent junction'
    $junctions += $parentAlias
    $null = Microsoft.PowerShell.Management\New-Item -ItemType Junction -Path $parentAlias -Target $exports
    Assert-Rejected 'aliased destination parent' $source (Join-Path $parentAlias 'transfer') 'Reparse points'

    $childAlias = Join-Path $source 'nested junction'
    $junctions += $childAlias
    $null = Microsoft.PowerShell.Management\New-Item -ItemType Junction -Path $childAlias -Target $exports
    Assert-Rejected 'junction inside source' $source $target 'contains a reparse point'
    [IO.Directory]::Delete($childAlias)

    # A one-letter PSDrive passes drive-letter syntax but must fail native-path validation.
    $usedDrives = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
    $aliasDrive = @('Z','Y','X','W','V','U' | Where-Object { $_ -notin $usedDrives } | Select-Object -First 1)[0]
    if (-not $aliasDrive) { throw 'No free drive name for the isolated PSDrive fixture.' }
    $null = New-PSDrive -Name $aliasDrive -PSProvider FileSystem -Root $source -Scope Script
    Assert-Rejected 'PowerShell drive alias' $source ($aliasDrive + ':\transfer') 'drive aliases'
    Remove-PSDrive -Name $aliasDrive -Scope Script
    $aliasDrive = $null

    $shortSource = New-Object Text.StringBuilder 32768
    $shortSize = [CsfcWsusFixtureNative]::GetShortPathName($source, $shortSource, $shortSource.Capacity)
    if ($shortSize -eq 0 -or $shortSize -ge $shortSource.Capacity) { throw 'Cannot query the short-path fixture.' }
    if (-not $shortSource.ToString().Equals($source, [StringComparison]::OrdinalIgnoreCase)) {
        Assert-Rejected '8.3 source alias' $shortSource.ToString() $target 'Short-name aliases'
        Assert-Rejected '8.3 destination ancestor alias' $source ($shortSource.ToString() + '\transfer') 'Short-name aliases'
    } else {
        Write-Output 'SKIP: this fixture volume does not provide an 8.3 alias; production rejection remains required'
    }

    Reset-FixtureCalls
    $global:WsusFixture.Target = $target
    & $scriptPath -ContentPath $source -Destination $target -WhatIf
    if ($global:WsusFixture.Writes.Count -or (Test-Path -LiteralPath $target)) { throw 'Preview created output.' }
    Write-Output 'PASS: disjoint preview performs validation without export writes'

    Reset-FixtureCalls
    & $scriptPath -ContentPath $source -Destination $target
    if (($global:WsusFixture.Writes -join ',') -cne 'mkdir,export,copy' -or
        -not (Test-Path -LiteralPath (Join-Path $target 'metadata.xml.gz') -PathType Leaf)) { throw 'Normal export did not complete its mocked stages.' }
    Write-Output 'PASS: disjoint paths with spaces export and retain additive copy arguments'

    Reset-FixtureCalls
    $global:WsusFixture.Target = $source + '-transfer'
    & $scriptPath -ContentPath $source -Destination $global:WsusFixture.Target
    if (($global:WsusFixture.Writes -join ',') -cne 'mkdir,export,copy') { throw 'A disjoint sibling sharing a name prefix was rejected.' }
    Write-Output 'PASS: a sibling sharing the source name prefix remains a separate tree'

    foreach ($case in @(
        @{Name='export failure'; Exit=1; Omit=$false; Copy=1; Pattern='WSUS export failed'; Calls='mkdir,export'},
        @{Name='missing metadata'; Exit=0; Omit=$true; Copy=1; Pattern='did not create the metadata'; Calls='mkdir,export'},
        @{Name='copy failure'; Exit=0; Omit=$false; Copy=8; Pattern='Content copy failed'; Calls='mkdir,export,copy'}
    )) {
        Reset-FixtureCalls
        $global:WsusFixture.Target = Join-Path $exports $case.Name
        $global:WsusFixture.ExportExit = $case.Exit
        $global:WsusFixture.OmitMetadata = $case.Omit
        $global:WsusFixture.CopyExit = $case.Copy
        $rejected = $false
        try { & $scriptPath -ContentPath $source -Destination $global:WsusFixture.Target } catch {
            if ($_.Exception.Message -notmatch $case.Pattern) { throw }
            $rejected = $true
        }
        if (-not $rejected -or ($global:WsusFixture.Writes -join ',') -cne $case.Calls -or
            -not (Test-Path -LiteralPath $global:WsusFixture.Target -PathType Container)) { throw "Failure handling changed: $($case.Name)" }
        Write-Output "PASS: $($case.Name) stops and retains the incomplete transfer"
    }
    if ((Get-FileHash -LiteralPath (Join-Path $source 'content.txt') -Algorithm SHA256).Hash -cne $sourceHash) { throw 'Source content was modified.' }
    Write-Output 'PASS: source fixture remains unchanged'
} finally {
    $env:ProgramFiles = $savedProgramFiles
    if ($aliasDrive) { Remove-PSDrive -Name $aliasDrive -Scope Script -ErrorAction SilentlyContinue }
    # Remove junction entries nonrecursively before deleting our uniquely named fixture.
    foreach ($junction in $junctions) {
        if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
    }
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if ($resolvedFixture -ne (Join-Path $fixtureParent $fixtureName) -or
        -not $fixtureName.StartsWith('csfc-wsus-test-') -or
        -not $resolvedFixture.StartsWith($fixtureParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the dedicated fixture directory.'
    }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
    Remove-Variable -Name WsusFixture -Scope Global -ErrorAction SilentlyContinue
}
