# Parse scripts without executing them. Works on Windows PowerShell 5.1 or PowerShell 7.
# Run: powershell.exe -NoProfile -File .\mecm\tests\check-syntax.ps1
$failed = $false
$scriptRoots = @((Join-Path $PSScriptRoot '..\scripts'), (Join-Path $PSScriptRoot '..\client-maintenance'))
Get-ChildItem $scriptRoots -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        $failed = $true
        $errors | ForEach-Object { Write-Output $_ }
    } else {
        Write-Output "PASS syntax: $($_.Name)"
    }
}
if ($failed) { exit 1 }
