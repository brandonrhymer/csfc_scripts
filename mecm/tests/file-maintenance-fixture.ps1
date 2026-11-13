# Shared synthetic filesystem fixture support, used only by the two test files.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$script:Passes=0
$script:FixtureParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$script:Fixture=Join-Path $script:FixtureParent ('csfc-file-maintenance-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $script:Fixture
$script:FixtureLinks=New-Object 'Collections.Generic.List[string]'
function Assert-True([bool]$Condition,[string]$Message) { if(-not $Condition) { throw $Message }; $script:Passes++ }
function Write-Utf8([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false))) }
function New-FixtureDirectory([string]$Path) { $null=New-Item -ItemType Directory -Path $Path -Force; return $Path }
function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function New-Case([string]$Name) {
    $folder=New-FixtureDirectory (Join-Path $script:Fixture $Name)
    $app=New-FixtureDirectory (Join-Path $folder 'SyntheticMaintenanceAgent')
    return [pscustomobject]@{ Folder=$folder; App=$app; PolicyPath=(Join-Path $folder 'approved-policy.json') }
}
function Invoke-Product([string]$Script,[object]$Case,[object]$Policy,[string]$Mode='Preview',[string]$HashOverride='', [int]$Timeout=15) {
    Write-Utf8 $Case.PolicyPath ($Policy | ConvertTo-Json -Depth 6)
    $hash=if($HashOverride) { $HashOverride } else { Get-Hash $Case.PolicyPath }
    $output=& powershell.exe -NoLogo -NoProfile -NonInteractive -File $Script -Mode $Mode -PolicyPath $Case.PolicyPath -PolicySha256 $hash -TimeoutSeconds $Timeout
    $exit=$LASTEXITCODE
    $raw=$output -join "`n"
    Assert-True ([Text.Encoding]::UTF8.GetByteCount($raw) -lt 4096) 'Output exceeded 4KB'
    $result=$raw | ConvertFrom-Json
    return [pscustomobject]@{ Exit=$exit; Result=$result; Raw=$raw }
}
function New-FaultScript([string]$Source,[string]$Name,[string]$Search,[string]$Replacement) {
    $text=[IO.File]::ReadAllText($Source)
    Assert-True ($text.Contains($Search)) 'Fault injection anchor missing'
    $path=Join-Path $script:Fixture ($Name+'.ps1')
    Write-Utf8 $path $text.Replace($Search,$Replacement)
    return $path
}
function Remove-Fixture {
    $full=[IO.Path]::GetFullPath($script:Fixture)
    if ([IO.Path]::GetDirectoryName($full) -ine $script:FixtureParent -or
        [IO.Path]::GetFileName($full) -notmatch '^csfc-file-maintenance-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path' }
    foreach($link in $script:FixtureLinks) {
        $resolved=[IO.Path]::GetFullPath($link)
        if(-not $resolved.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture link cleanup' }
        if(Test-Path -LiteralPath $resolved) {
            $item=Get-Item -LiteralPath $resolved -Force
            if(-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Fixture link changed' }
            # PS 5.1 Remove-Item can throw NullReferenceException for junctions.
            # DirectoryInfo.Delete() unlinks this exact junction, never recurses.
            $item.Delete()
        }
    }
    # All known junctions have been unlinked before recursive fixture cleanup.
    if ((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture root changed' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
