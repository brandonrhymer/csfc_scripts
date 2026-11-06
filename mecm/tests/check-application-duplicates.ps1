# Test the production duplicate guard without reading an MSI or contacting MECM.
# Extract only its actual if statement so the test cannot execute COM or create an app.
# Run this in a fresh PowerShell process; the fake query exists only in this test.
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$path = Join-Path $PSScriptRoot '..\scripts\add-msi-application.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application script has syntax errors.' }
$guards = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.StartsWith('if (@(Get-CMApplication ')
}, $true))
if ($guards.Count -ne 1) { throw 'Expected exactly one duplicate guard.' }
$guard = [scriptblock]::Create($guards[0].Extent.Text)
function Get-CMApplication {
    param([string]$Name, [switch]$ShowHidden, [switch]$DisableWildcardHandling)
    $global:MecmTestLookup = @{
        Name = $Name
        ShowHidden = $ShowHidden.IsPresent
        Literal = $DisableWildcardHandling.IsPresent
    }
    # Return broad name matches deliberately; the guard must still compare exactly.
    $global:MecmTestApps | Where-Object { -not $_.IsHidden -or $ShowHidden }
}
$cases = @(
    @{ Label='visible duplicate'; Name='Example App 1.0'; Apps=@(@{LocalizedDisplayName='Example App 1.0'; IsHidden=$false}); Reject=$true },
    @{ Label='hidden duplicate'; Name='Example App 1.0'; Apps=@(@{LocalizedDisplayName='Example App 1.0'; IsHidden=$true}); Reject=$true },
    @{ Label='literal wildcard name'; Name='Example [App]*? 1.0'; Apps=@(@{LocalizedDisplayName='Example [App]*? 1.0'; IsHidden=$true}); Reject=$true },
    @{ Label='similar name allowed'; Name='Example [App]*? 1.0'; Apps=@(@{LocalizedDisplayName='Example App 1.0'; IsHidden=$false}); Reject=$false },
    @{ Label='new name allowed'; Name='Example App 1.0'; Apps=@(); Reject=$false }
)
foreach ($case in $cases) {
    $name = $case.Name
    $global:MecmTestApps = @($case.Apps | ForEach-Object { [pscustomobject]$_ })
    $global:MecmTestLookup = $null
    $rejected = $false
    try { & $guard } catch {
        if ($_.Exception.Message -ne "Application already exists: $name. Review it in the console.") { throw }
        $rejected = $true
    }
    if ($rejected -ne $case.Reject) { throw "Unexpected decision: $($case.Label)" }
    if ($global:MecmTestLookup.Name -cne $name -or
        -not $global:MecmTestLookup.ShowHidden -or -not $global:MecmTestLookup.Literal) {
        throw 'Lookup must pass the unchanged name and both visibility/literal switches.'
    }
    Write-Output "PASS: $($case.Label)"
}
