#requires -Version 5.1
param([ValidateSet('service-start','agent-restart','task-enable')][string]$Product)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$entryNames = @{ 'service-start' = 'Invoke-MecmServiceStart.ps1'; 'agent-restart' = 'Invoke-MecmAgentRestart.ps1'; 'task-enable' = 'Invoke-MecmTaskEnable.ps1' }
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot ('..\client-maintenance\' + $entryNames[$Product])))
$provider = Join-Path $PSScriptRoot 'service-task-policy-fixture.ps1'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $tempRoot ('csfc-' + $Product + '-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$script:Passes = 0
$suiteClock = [Diagnostics.Stopwatch]::StartNew()
$xml = '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task" version="1.2"><RegistrationInfo><Author>Synthetic</Author></RegistrationInfo><Triggers /><Principals><Principal id="Author"><UserId>S-1-5-18</UserId></Principal></Principals><Settings><Enabled>false</Enabled></Settings><Actions Context="Author"><Exec><Command>C:\SyntheticApp\agent.exe</Command></Exec></Actions></Task>'
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function New-Policy {
    if ($Product -eq 'task-enable') {
        $doc = New-Object Xml.XmlDocument; $doc.PreserveWhitespace = $false; $doc.LoadXml($xml)
        $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable); $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
        $node = $doc.SelectSingleNode('/t:Task/t:Settings/t:Enabled',$ns); $null = $node.ParentNode.RemoveChild($node)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($doc.OuterXml)))).Replace('-','') } finally { $sha.Dispose() }
        $target = [ordered]@{ TaskPath = '\SyntheticApp\'; TaskName = 'Synthetic Maintenance'; DefinitionSha256 = $hash }
    } else {
        $target = [ordered]@{ ServiceName = 'SyntheticAppAgent'; ExpectedPathName = '"C:\Program Files\SyntheticApp\agent.exe" --service'; ExpectedStartName = 'LocalSystem'; ExpectedStartMode = 'Auto'; ExpectedServiceType = 'Own Process' }
    }
    return [ordered]@{ SchemaVersion = 1; Product = 'mecm-' + $Product; Example = $false; Target = $target }
}
function Invoke-Case {
    param([string]$Name,[string]$Fault = '',[string]$Mode = 'Apply',$Policy = (New-Policy),[int]$TimeoutSeconds = 15,[switch]$BadHash,[switch]$BadPath)
    $policyPath = Join-Path $fixture ($Name + '-policy.json')
    $configPath = Join-Path $fixture ($Name + '-config.json')
    $evidencePath = Join-Path $fixture ($Name + '-evidence.json')
    $scriptPath = Join-Path $fixture ($Name + '.ps1')
    $Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $policyPath -Encoding UTF8
    $hash = (Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash
    if ($BadHash) { $hash = '0' * 64 }
    if ($BadPath) { $policyPath = '\\synthetic.invalid\share\policy.json' }
    @{ Product = $Product; Fault = $Fault; Evidence = $evidencePath; Xml = $xml } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Production parse error in Windows PowerShell 5.1'
    # Static provider boundary: the listed names are intercepted below. No module
    # qualified operational cmdlets or native service/task executables are allowed.
    $commands = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object { $_.GetCommandName() })
    foreach ($commandName in $commands) {
        Assert-True ($commandName -notmatch '^(?:.*\\)?(?:sc|schtasks|net)(?:\.exe)?$' -and $commandName -notmatch '\\(?:Get-Cim|Invoke-Cim|Get-Scheduled|Export-Scheduled|Enable-Scheduled)' -and $commandName -notin @('Start-Service','Stop-Service','Restart-Service','Set-Service','Start-ScheduledTask','Set-ScheduledTask','Register-ScheduledTask','Unregister-ScheduledTask')) 'Unexpected operational provider bypass'
    }
    foreach ($call in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))) {
        $commandName = $call.GetCommandName()
        if ($commandName -in @('Get-CimInstance','Get-CimAssociatedInstance','Invoke-CimMethod','Get-ScheduledTask','Export-ScheduledTask','Enable-ScheduledTask','Get-ItemProperty')) {
            # Metadata inspection only: no provider is invoked. Catch fake mock signatures.
            $metadata = Get-Command -Name $commandName -ErrorAction Stop
            foreach ($element in $call.CommandElements) {
                if ($element -is [Management.Automation.Language.CommandParameterAst]) {
                    Assert-True ($metadata.Parameters.ContainsKey($element.ParameterName)) ("Unsupported parameter {0} on {1}" -f $element.ParameterName,$commandName)
                }
            }
        }
    }
    $assignment = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$worker'},$true)
    $block = $assignment.Right.Find({param($n) $n -is [Management.Automation.Language.ScriptBlockAst]},$true)
    $injection = "`n. '" + $provider.Replace("'","''") + "' -ConfigurationPath '" + $configPath.Replace("'","''") + "'`n"
    $copy = $source.Insert($block.ParamBlock.Extent.EndOffset,$injection)
    if ($Fault -eq 'BadProtocol') { $copy = $copy.Replace("Send-Record 'Result'", "[Console]::Out.WriteLine('not-json')") }
    if ($Fault -eq 'BadFlag') { $copy = $copy.Replace("Send-Record 'Result'", "`$r.MayHaveChanged = 'false'; Send-Record 'Result'") }
    if ($Fault -eq 'LargeProtocol') { $copy = $copy.Replace("Send-Record 'Result'", "[Console]::Out.WriteLine(('x' * 9000))") }
    if ($Fault -eq 'BomInput') { $copy = $copy.Replace("`$entry = '", "`$childSource = [char]0xfeff + `$childSource;`n    `$entry = '") }
    if ($Fault -eq 'MissingWorkerMode') { $copy = $copy.Replace('-Mode $p.Mode', '-Mode $null') }
    if ($Fault -eq 'InvalidWorkerMode') { $copy = $copy.Replace('-Mode $p.Mode', '-Mode Invalid') }
    if ($Fault -eq 'InputStall') {
        $copy = $copy.Replace("`$entry = '", "`$childSource += ('#' + ('x' * 262144));`n    `$entry = '")
        $copy = $copy.Replace('$source = $reader.ReadToEnd()', 'Start-Sleep -Seconds 30; $source = $reader.ReadToEnd()')
    }
    [IO.File]::WriteAllText($scriptPath,$copy,(New-Object Text.UTF8Encoding $false))
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& "$PSHOME\powershell.exe" -NoProfile -NonInteractive -File $scriptPath -Mode $Mode -PolicyPath $policyPath -PolicySha256 $hash -TimeoutSeconds $TimeoutSeconds 2>&1)
    $code = $LASTEXITCODE; $clock.Stop()
    $json = $output -join "`n"
    Assert-True ([Text.Encoding]::UTF8.GetByteCount($json) -lt 4096) "$Name exceeded output limit"
    try { $result = $json | ConvertFrom-Json } catch { throw "${Name}: invalid output $json" }
    $evidence = if (Test-Path -LiteralPath $evidencePath) { Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json } else { $null }
    if ($null -ne $evidence) { Assert-True ($null -eq (Get-Process -Id $evidence.WorkerPid -ErrorAction SilentlyContinue)) "$Name left its worker alive" }
    return [pscustomobject]@{ Result = $result; Code = $code; Evidence = $evidence; Seconds = $clock.Elapsed.TotalSeconds }
}
function Assert-Case {
    param([string]$Name,$Actual,[string]$Status,[string]$Reason,[int]$Calls = 0,[int]$Code = 0)
    Assert-True ($Actual.Result.Status -ceq $Status) "$Name status $($Actual.Result.Status), expected $Status; result $($Actual.Result | ConvertTo-Json -Compress)"
    Assert-True ($Actual.Result.Reason -ceq $Reason) "$Name reason $($Actual.Result.Reason), expected $Reason"
    Assert-True ($Actual.Code -eq $Code) "$Name exit $($Actual.Code), expected $Code"
    $count = if ($null -eq $Actual.Evidence) { 0 } else { @($Actual.Evidence.Calls).Count }
    Assert-True ($count -eq $Calls) "$Name mutation count $count, expected $Calls"
    $script:Passes++; Write-Output "PASS: $Product / $Name"
}
try {
    $p = Invoke-Case preview -Mode Preview
    Assert-Case preview $p Skipped PreviewOnly
    Assert-True (-not $p.Result.MayHaveChanged) 'Preview reports a mutation'
    Assert-Case bomInput (Invoke-Case bomInput -Fault BomInput -Mode Preview) Skipped PreviewOnly
    foreach ($fault in @('MissingWorkerMode','InvalidWorkerMode')) {
        $actual = Invoke-Case $fault -Fault $fault -Mode Preview
        Assert-Case $fault $actual Failed WorkerFailed 0 1
        Assert-True ($null -eq $actual.Evidence) 'Invalid worker mode reached the worker'
    }
    $apply = Invoke-Case apply
    $count = if ($Product -eq 'agent-restart') { 2 } else { 1 }
    $reason = @{ 'service-start' = 'ServiceStarted'; 'agent-restart' = 'AgentRestarted'; 'task-enable' = 'TaskEnabled' }[$Product]
    Assert-Case apply $apply Changed $reason $count
    Assert-True ($apply.Result.MayHaveChanged -and -not $apply.Result.OutcomeUncertain -and $apply.Evidence.Reads -ge 3) 'Missing verified mutation'
    if ($Product -eq 'agent-restart') {
        Assert-True (($apply.Evidence.Calls -join ',') -eq 'StopService,StartService') 'Restart method order'
    } else {
        $noop = Invoke-Case already -Fault Already
        $reason = if ($Product -eq 'task-enable') { 'TaskEnabled' } else { 'ServiceRunning' }
        Assert-Case already $noop 'Already correct' $reason
    }
    foreach ($pair in @(@('Missing','TargetMissing'),@('Duplicate','TargetAmbiguous'),@('WrongBinary','IdentityMismatch'),@('RecheckIdentity','IdentityMismatch'),@('RecheckState','RevalidationChanged'),@('ThrowRead','InspectFailed'))) {
        Assert-Case $pair[0] (Invoke-Case $pair[0] -Fault $pair[0]) Failed $pair[1] 0 1
    }
    Assert-Case hash (Invoke-Case hash -BadHash) Failed PolicyHashMismatch 0 1
    Assert-Case path (Invoke-Case path -BadPath) Failed InvalidParameter 0 2
    Assert-Case mode (Invoke-Case mode -Mode Invalid) Failed InvalidParameter 0 2
    Assert-Case timeoutRange (Invoke-Case timeoutRange -TimeoutSeconds 0) Failed InvalidParameter 0 2
    $policy = New-Policy; $policy.Example = $true
    Assert-Case example (Invoke-Case example -Policy $policy) Failed ExamplePolicyRejected 0 1
    $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot ('..\client-maintenance\' + $Product + '.policy.example.json')) -Raw | ConvertFrom-Json
    Assert-True ($example.Example -is [bool] -and $example.Example) 'Shipping example must remain inactive'
    Assert-Case shippedExample (Invoke-Case shippedExample -Policy $example) Failed ExamplePolicyRejected 0 1
    $policy = New-Policy; $policy.SchemaVersion = '1'
    Assert-Case versionType (Invoke-Case versionType -Policy $policy) Failed PolicyInvalid 0 1
    $policy = New-Policy; $policy['Unexpected'] = 'value'
    Assert-Case schema (Invoke-Case schema -Policy $policy) Failed PolicyInvalid 0 1
    foreach ($fault in @('BadProtocol','BadFlag','LargeProtocol')) {
        Assert-Case $fault (Invoke-Case $fault -Fault $fault -Mode Preview) Failed WorkerFailed 0 1
    }
    $hung = Invoke-Case hungRead -Fault HangRead -TimeoutSeconds 5
    Assert-Case hungRead $hung Failed WorkerTimeout 0 2
    Assert-True ($hung.Seconds -lt 12 -and $hung.Result.TimedOut -and $hung.Result.OutcomeUncertain) 'Unbounded provider timeout or false certainty'
    $inputHang = Invoke-Case inputStall -Fault InputStall -TimeoutSeconds 5
    Assert-Case inputStall $inputHang Failed WorkerTimeout 0 2
    Assert-True ($inputHang.Seconds -lt 12 -and $null -eq $inputHang.Evidence) 'Unbounded input transfer or worker started unexpectedly'
    if ($Product -eq 'task-enable') {
        foreach ($pair in @(@('UnknownState','IdentityMismatch'),@('XmlDtd','InspectFailed'))) {
            Assert-Case $pair[0] (Invoke-Case $pair[0] -Fault $pair[0]) Failed $pair[1] 0 1
        }
        foreach ($pair in @(@('EnableThrow','EnableFailed'),@('EnableStuck','EnableNotConfirmed'),@('AfterEnableIdentity','IdentityMismatch'))) {
            $actual = Invoke-Case $pair[0] -Fault $pair[0]
            Assert-Case $pair[0] $actual Failed $pair[1] 1 1
            Assert-True $actual.Result.OutcomeUncertain 'Enable partial failure falsely certain'
        }
        $actual = Invoke-Case hangEnable -Fault HangEnable -TimeoutSeconds 5
        Assert-Case hangEnable $actual Failed WorkerTimeout 1 2
        $policy = New-Policy; $policy.Target.TaskPath = '\Microsoft\Windows\'
        Assert-Case excluded (Invoke-Case excluded -Policy $policy) Failed TargetExcluded 0 1
        $policy = New-Policy; $policy.Target.TaskName = '*'
        Assert-Case wildcard (Invoke-Case wildcard -Policy $policy) Failed PolicyInvalid 0 1
    } else {
        foreach ($pair in @(@('WrongAccount','IdentityMismatch'),@('WrongStartMode','IdentityMismatch'),@('WrongType','IdentityMismatch'),@('UnknownState','StateNotEligible'),@('Paused','StateNotEligible'),@('Dependency','DependencyRefused'),@('GroupDependency','DependencyRefused'))) {
            Assert-Case $pair[0] (Invoke-Case $pair[0] -Fault $pair[0]) Failed $pair[1] 0 1
        }
        $calls = if ($Product -eq 'agent-restart') { 2 } else { 1 }
        foreach ($pair in @(@('StartReject','StartRejected'),@('StartThrow','StartFailed'),@('StartStuck','StartNotConfirmed'))) {
            $actual = Invoke-Case $pair[0] -Fault $pair[0] -TimeoutSeconds 7
            Assert-Case $pair[0] $actual Failed $pair[1] $calls 1
            Assert-True $actual.Result.OutcomeUncertain 'Start failure falsely certain'
            if ($Product -eq 'agent-restart') { Assert-True ($actual.Result.LastState -eq 'Stopped') 'Partial restart lost confirmed stopped state' }
        }
        $actual = Invoke-Case hangStart -Fault HangStart -TimeoutSeconds 5
        Assert-Case hangStart $actual Failed WorkerTimeout $calls 2
        if ($Product -eq 'agent-restart') { Assert-True ($actual.Result.LastState -eq 'Stopped') 'Hung start lost stopped progress evidence' }
        foreach ($name in @('CcmExec','RpcSs','WinDefend','SyntheticSecurityAgent')) {
            $policy = New-Policy; $policy.Target.ServiceName = $name
            Assert-Case $name (Invoke-Case $name -Policy $policy) Failed TargetExcluded 0 1
        }
        foreach ($binary in @('C:\Windows\Synthetic\agent.exe','C:\Program Files\Synthetic\agent.exe','%SystemRoot%\agent.exe')) {
            $policy = New-Policy; $policy.Target.ExpectedPathName = $binary
            Assert-Case excludedBinary (Invoke-Case excludedBinary -Policy $policy) Failed TargetExcluded 0 1
        }
        $policy = New-Policy; $policy.Target.ServiceName = '*'
        Assert-Case wildcard (Invoke-Case wildcard -Policy $policy) Failed PolicyInvalid 0 1
        if ($Product -eq 'agent-restart') {
            foreach ($pair in @(@('Stopped','StateNotEligible'),@('CannotStop','StateNotEligible'),@('Dependent','DependencyRefused'))) {
                Assert-Case $pair[0] (Invoke-Case $pair[0] -Fault $pair[0]) Failed $pair[1] 0 1
            }
            foreach ($pair in @(@('StopReject','StopRejected'),@('StopThrow','StopFailed'),@('StopStuck','StopNotConfirmed'),@('AfterStopIdentity','IdentityMismatch'))) {
                $actual = Invoke-Case $pair[0] -Fault $pair[0] -TimeoutSeconds 7
                Assert-Case $pair[0] $actual Failed $pair[1] 1 1
                Assert-True $actual.Result.OutcomeUncertain 'Stopped/partial outcome falsely certain'
            }
            $actual = Invoke-Case hangStop -Fault HangStop -TimeoutSeconds 5
            Assert-Case hangStop $actual Failed WorkerTimeout 1 2
            Assert-True ($actual.Seconds -lt 12) 'Stop timeout unbounded'
        }
    }
    Write-Output ("PASS: {0} {1} synthetic cases in {2:N1}s; no operational providers invoked" -f $Product,$script:Passes,$suiteClock.Elapsed.TotalSeconds)
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith($tempRoot + '\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('csfc-' + $Product + '-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
