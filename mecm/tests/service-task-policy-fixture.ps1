param([string]$ConfigurationPath)
# Only injected into a disposable source copy. Every operational provider name
# used by the products is replaced in the worker scope; unexpected calls throw.
$script:Fx = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
$script:Reads = 0; $script:Calls = @(); $script:XmlReads = 0
$script:State = if ($script:Fx.Product -eq 'agent-restart') { 'Running' } else { 'Stopped' }
$script:Enabled = $false
if ($script:Fx.Fault -eq 'Already') { $script:State = 'Running'; $script:Enabled = $true }
if ($script:Fx.Fault -eq 'Stopped') { $script:State = 'Stopped' }
if ($script:Fx.Fault -eq 'Paused') { $script:State = 'Paused' }
function Save-Evidence {
    @{ Reads = $script:Reads; Calls = @($script:Calls); State = $script:State; Enabled = $script:Enabled; WorkerPid = $PID; XmlReads = $script:XmlReads } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Fx.Evidence -Encoding UTF8
}
Save-Evidence
function Get-CimInstance {
    [CmdletBinding()] param($Namespace,$ClassName,$Filter)
    if ($Namespace -cne 'root\cimv2' -or $ClassName -cne 'Win32_Service' -or $Filter -cne "Name='SyntheticAppAgent'") { throw 'Fixture blocked unexpected CIM query' }
    $script:Reads++; Save-Evidence
    if ($script:Fx.Fault -eq 'HangRead') { Start-Sleep -Seconds 30 }
    if ($script:Fx.Fault -eq 'ThrowRead') { throw 'synthetic read failure' }
    if ($script:Fx.Fault -eq 'Missing') { return }
    $s = [pscustomobject]@{ Name = 'SyntheticAppAgent'; PathName = '"C:\Program Files\SyntheticApp\agent.exe" --service'; StartName = 'LocalSystem'; StartMode = 'Auto'; ServiceType = 'Own Process'; State = $script:State; AcceptStop = $true }
    switch ($script:Fx.Fault) {
        'WrongBinary' { $s.PathName = 'C:\Changed\agent.exe' }
        'WrongAccount' { $s.StartName = 'OtherAccount' }
        'WrongStartMode' { $s.StartMode = 'Disabled' }
        'WrongType' { $s.ServiceType = 'Share Process' }
        'CannotStop' { $s.AcceptStop = $false }
        'UnknownState' { $s.State = 'Mystery' }
        'RecheckIdentity' { if ($script:Reads -ge 2) { $s.PathName = 'C:\Changed\agent.exe' } }
        'AfterStopIdentity' { if ($script:State -eq 'Stopped') { $s.PathName = 'C:\Changed\agent.exe' } }
        'RecheckState' { if ($script:Reads -ge 2) { $s.State = 'Paused' } }
    }
    $s
    if ($script:Fx.Fault -eq 'Duplicate') { $s }
}
function Get-ItemProperty {
    [CmdletBinding()] param($LiteralPath)
    if ($LiteralPath -cne 'HKLM:\SYSTEM\CurrentControlSet\Services\SyntheticAppAgent') { throw 'Fixture blocked unexpected registry read' }
    $p = [pscustomobject]@{}
    if ($script:Fx.Fault -eq 'Dependency') { $p | Add-Member NoteProperty DependOnService @('SyntheticDependency') }
    if ($script:Fx.Fault -eq 'GroupDependency') { $p | Add-Member NoteProperty DependOnGroup @('SyntheticGroup') }
    return $p
}
function Get-CimAssociatedInstance {
    [CmdletBinding()] param($InputObject,$Association)
    if ($InputObject.Name -cne 'SyntheticAppAgent' -or $Association -cne 'Win32_DependentService') { throw 'Fixture blocked unexpected association' }
    if ($script:Fx.Fault -eq 'Dependent') { [pscustomobject]@{ Name = 'SyntheticDependent'; State = 'Stopped' } }
}
function Invoke-CimMethod {
    [CmdletBinding()] param($InputObject,$MethodName)
    if ($InputObject.Name -cne 'SyntheticAppAgent' -or $MethodName -notin @('StartService','StopService')) { throw 'Fixture blocked unexpected mutation' }
    $script:Calls += $MethodName; Save-Evidence
    if ($MethodName -eq 'StartService') {
        if ($script:Fx.Fault -eq 'HangStart') { Start-Sleep -Seconds 30 }
        if ($script:Fx.Fault -eq 'StartThrow') { throw 'synthetic start failure' }
        if ($script:Fx.Fault -eq 'StartReject') { return [pscustomobject]@{ ReturnValue = 2 } }
        if ($script:Fx.Fault -ne 'StartStuck') { $script:State = 'Running' }
    } else {
        if ($script:Fx.Fault -eq 'HangStop') { Start-Sleep -Seconds 30 }
        if ($script:Fx.Fault -eq 'StopThrow') { throw 'synthetic stop failure' }
        if ($script:Fx.Fault -eq 'StopReject') { return [pscustomobject]@{ ReturnValue = 3 } }
        if ($script:Fx.Fault -ne 'StopStuck') { $script:State = 'Stopped' }
    }
    Save-Evidence
    [pscustomobject]@{ ReturnValue = 0 }
}
function Get-ScheduledTask {
    [CmdletBinding()] param()
    $script:Reads++; Save-Evidence
    if ($script:Fx.Fault -eq 'HangRead') { Start-Sleep -Seconds 30 }
    if ($script:Fx.Fault -eq 'ThrowRead') { throw 'synthetic read failure' }
    if ($script:Fx.Fault -eq 'Missing') { return }
    if ($script:Fx.Fault -eq 'RecheckState' -and $script:Reads -ge 2) { $script:Enabled = $true }
    $task = [pscustomobject]@{ TaskPath = '\SyntheticApp\'; TaskName = 'Synthetic Maintenance'; Settings = [pscustomobject]@{ Enabled = $script:Enabled } }
    if ($script:Fx.Fault -eq 'UnknownState') { $task.Settings.Enabled = 'false' }
    $task
    if ($script:Fx.Fault -eq 'Duplicate') { $task }
    [pscustomobject]@{ TaskPath = '\OtherApp\'; TaskName = 'Synthetic Maintenance'; Settings = [pscustomobject]@{ Enabled = $false } }
}
function Export-ScheduledTask {
    [CmdletBinding()] param($TaskPath,$TaskName)
    if ($TaskPath -cne '\SyntheticApp\' -or $TaskName -cne 'Synthetic Maintenance') { throw 'Fixture blocked unexpected task export' }
    $script:XmlReads++; Save-Evidence
    $xml = $script:Fx.Xml.Replace('<Enabled>false</Enabled>', '<Enabled>' + $script:Enabled.ToString().ToLowerInvariant() + '</Enabled>')
    if ($script:Fx.Fault -eq 'WrongBinary' -or ($script:Fx.Fault -eq 'RecheckIdentity' -and $script:Reads -ge 2) -or ($script:Fx.Fault -eq 'AfterEnableIdentity' -and $script:Enabled)) { $xml = $xml.Replace('agent.exe','changed.exe') }
    if ($script:Fx.Fault -eq 'XmlDtd') { $xml = '<!DOCTYPE Task [<!ENTITY x SYSTEM "file:///C:/never-read">]>' + $xml }
    return $xml
}
function Enable-ScheduledTask {
    [CmdletBinding()] param($InputObject)
    if ($InputObject.TaskPath -cne '\SyntheticApp\' -or $InputObject.TaskName -cne 'Synthetic Maintenance' -or $InputObject.Settings.Enabled) { throw 'Fixture blocked unexpected task enable' }
    $script:Calls += 'Enable'; Save-Evidence
    if ($script:Fx.Fault -eq 'HangEnable') { Start-Sleep -Seconds 30 }
    if ($script:Fx.Fault -eq 'EnableThrow') { throw 'synthetic enable failure' }
    if ($script:Fx.Fault -ne 'EnableStuck') { $script:Enabled = $true }
    Save-Evidence
}
# Guard unwanted administration entry points if implementation drifts.
function Start-Service { throw 'Fixture forbids Start-Service' }
function Stop-Service { throw 'Fixture forbids Stop-Service' }
function Restart-Service { throw 'Fixture forbids Restart-Service' }
function Set-Service { throw 'Fixture forbids Set-Service' }
function Start-ScheduledTask { throw 'Fixture forbids task run' }
function Set-ScheduledTask { throw 'Fixture forbids task definition edit' }
function Register-ScheduledTask { throw 'Fixture forbids task registration' }
function Unregister-ScheduledTask { throw 'Fixture forbids task removal' }
