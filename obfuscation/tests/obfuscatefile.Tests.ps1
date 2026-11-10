# Run from the repository directory: pwsh -NoProfile -File ./obfuscation/tests/obfuscatefile.Tests.ps1
# Dependency-free integration checks. All inputs and outputs are synthetic.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Target = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../obfuscatefile.ps1'))
$script:PowerShell = (Get-Process -Id $PID).Path
$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('obfuscatefile-tests-' + [guid]::NewGuid().ToString('N'))
$script:CaseNumber = 0
$script:Passed = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Utf8 = [System.Text.UTF8Encoding]::new($false, $true)
[void][System.IO.Directory]::CreateDirectory($script:TestRoot)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected)
    Assert-True ($Text.Contains($Expected)) "Expected text to contain '$Expected'. Actual: $Text"
}

function Assert-Removed {
    param([string]$Text, [string[]]$Originals)
    foreach ($original in $Originals) {
        Assert-True (-not $Text.Contains($original)) "Original value remains: '$original'. Actual: $Text"
    }
}

function New-Fixture {
    param([AllowEmptyString()][string]$Content = '', [string]$Extension = 'log')
    $script:CaseNumber++
    $dir = Join-Path $script:TestRoot ('case-' + $script:CaseNumber)
    [void][System.IO.Directory]::CreateDirectory($dir)
    $suffix = if ($Extension) { '.' + $Extension } else { '' }
    $inputPath = Join-Path $dir ('input' + $suffix)
    $outputPath = Join-Path $dir ('output' + $suffix)
    [System.IO.File]::WriteAllText($inputPath, $Content, $script:Utf8)
    [pscustomobject]@{ Directory = $dir; Input = $inputPath; Output = $outputPath }
}

function Invoke-Obfuscator {
    param([hashtable]$Parameters, [string]$WorkingDirectory = $script:TestRoot, [string]$PowerShellLocation)
    $paramsFile = Join-Path $script:TestRoot ([guid]::NewGuid().ToString('N') + '.clixml')
    $Parameters | Export-Clixml -LiteralPath $paramsFile
    $quotedParams = $paramsFile.Replace("'", "''")
    $quotedTarget = $script:Target.Replace("'", "''")
    $locationCommand = if ($PowerShellLocation) { "Set-Location -LiteralPath '$($PowerShellLocation.Replace("'", "''"))'; " } else { '' }
    $command = "try { $locationCommand`$parameters = Import-Clixml -LiteralPath '$quotedParams'; & '$quotedTarget' @parameters; exit 0 } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $script:PowerShell
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command)) {
        [void]$info.ArgumentList.Add($arg)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw 'Script exceeded the 30-second test timeout.'
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
        Remove-Item -LiteralPath $paramsFile -Force -ErrorAction SilentlyContinue
    }
}

function Assert-Success {
    param($Result)
    Assert-True ($Result.ExitCode -eq 0) "Expected success. Exit $($Result.ExitCode). $($Result.Stderr)"
}

function Assert-Failure {
    param($Result)
    Assert-True ($Result.ExitCode -ne 0) "Expected a nonzero exit code. Output: $($Result.Stdout)"
    Assert-True ($Result.Stdout -notmatch '(?i)(obfuscation|redaction) complete') 'A failed operation reported completion.'
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "FAIL ${Name}: $($_.Exception.Message)"
    }
}

if (-not [System.IO.File]::Exists($script:Target)) {
    throw "Missing script: $script:Target"
}

foreach ($extension in @('txt', 'log', 'xml', 'conf', 'cfg', 'data', '')) {
    Test-Case "text content with extension '$extension'" {
        $content = if ($extension -eq 'xml') {
            '<log host="SERVER01"><ip>192.0.2.1</ip><domain>example.test</domain><password>synthetic-password</password></log>'
        } else {
            "host=SERVER01 address=192.0.2.1 domain=example.test password=synthetic-password`n"
        }
        $f = New-Fixture -Content $content -Extension $extension
        $before = [System.IO.File]::ReadAllBytes($f.Input)
        $result = Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output }
        Assert-Success $result
        $text = [System.IO.File]::ReadAllText($f.Output)
        Assert-Removed $text @('SERVER01', '192.0.2.1', 'example.test', 'synthetic-password')
        Assert-True ([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.Input))) 'Input file changed.'
        Assert-True (@(Get-ChildItem -LiteralPath $f.Directory -File).Count -eq 2) 'Default redaction unexpectedly wrote a mapping file.'
    }
}

Test-Case 'empty input is a valid empty text file' {
    $f = New-Fixture
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    Assert-True ((Get-Item -LiteralPath $f.Output).Length -eq 0) 'Empty input produced nonempty output.'
}

Test-Case 'obfuscation uses unique stable tokens and full matches' {
    $f = New-Fixture '192.0.2.1 192.0.2.10 198.51.100.2 192.0.2.1 alpha.test beta.test confidential.alpha.test'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; Mode = 'Obfuscate' })
    $tokens = ([System.IO.File]::ReadAllText($f.Output).Trim() -split '\s+')
    Assert-True ($tokens.Count -eq 7) 'Unexpected token count.'
    Assert-True (($tokens[0..2] | Select-Object -Unique).Count -eq 3) 'Distinct IPs reused a token.'
    Assert-True ($tokens[0] -eq $tokens[3]) 'Repeated IPs did not reuse their token.'
    Assert-True (($tokens[4..6] | Select-Object -Unique).Count -eq 3) 'Distinct complete hostnames reused a token.'
    Assert-True (($tokens[0..3] | Where-Object { $_ -notmatch '^IP_\d+$' }).Count -eq 0) 'IP replacement retained a suffix or used an unexpected token.'
    Assert-True (($tokens[4..6] | Where-Object { $_ -notmatch '^HOST_\d+$' }).Count -eq 0) 'Hostname replacement retained labels.'
}

Test-Case 'IPv4 boundaries do not replace invalid address fragments' {
    $f = New-Fixture 'invalid=256.1.2.3 invalid=1192.0.2.1 valid=192.0.2.1:443 network=198.51.100.0/24'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Contains $text '256.1.2.3'
    Assert-Contains $text '1192.0.2.1'
    Assert-Removed $text @('valid=192.0.2.1', '198.51.100.0')
    Assert-Contains $text ':443'
    Assert-Contains $text '/24'
}

Test-Case 'IPv6 addresses including bracketed endpoint are removed' {
    $f = New-Fixture 'address=2001:db8::1234 loopback=::1 endpoint=[2001:db8::abcd]:443'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('2001:db8::1234', '::1', '2001:db8::abcd')
    Assert-Contains $text ':443'
}

Test-Case 'contextual hostnames and explicitly known hosts' {
    $f = New-Fixture 'host=SERVER01 server: BACKUP02 computer="DESKTOP03" normal=ordinary OtherHost appears here'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; KnownHostnames = @('OtherHost') })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('SERVER01', 'BACKUP02', 'DESKTOP03', 'OtherHost')
    Assert-Contains $text 'ordinary'
}

Test-Case 'line-start configuration directives support whitespace separators' {
    $f = New-Fixture -Extension 'conf' -Content @'
password synthetic-directive-secret
server SERVER01
    token "synthetic directive token"
The server SERVER02 responded normally.
'@
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('synthetic-directive-secret', 'SERVER01', 'synthetic directive token')
    Assert-Contains $text 'The server SERVER02 responded normally.'
}

Test-Case 'secret fields authorization and private key blocks are removed' {
    $f = New-Fixture @'
password=synthetic-password
api_key: synthetic-api-key
Authorization: Bearer synthetic-bearer-token
-----BEGIN PRIVATE KEY-----
U3ludGhldGljS2V5RGF0YQ==
-----END PRIVATE KEY-----
visible=ordinary
'@
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('synthetic-password', 'synthetic-api-key', 'synthetic-bearer-token', 'U3ludGhldGljS2V5RGF0YQ==')
    Assert-Contains $text 'ordinary'
}

Test-Case 'custom secret keys and explicit sensitive values' {
    $f = New-Fixture 'custom_credential=synthetic-custom password_hint=ordinary free-standing-synthetic-sensitive'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; SecretKeys = @('custom_credential'); SensitiveValues = @('free-standing-synthetic-sensitive') })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('synthetic-custom', 'free-standing-synthetic-sensitive')
}

Test-Case 'quoted secret values and configured literals are handled literally' {
    $f = New-Fixture 'password="synthetic secret with spaces" note=$1.*(synthetic) ordinary=keep'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; SensitiveValues = @('$1.*(synthetic)') })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('synthetic secret with spaces', '$1.*(synthetic)')
    Assert-Contains $text 'ordinary=keep'
}

Test-Case 'overlapping hostname and explicit sensitive ranges remove their union' {
    $f = New-Fixture 'destination=foo.alpha.test/secretTail visible=ordinary'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; SensitiveValues = @('alpha.test/secretTail') })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('foo.alpha.test', 'alpha.test/secretTail', 'secretTail', 'foo.')
    Assert-Contains $text 'visible=ordinary'
}

Test-Case 'empty assignments do not consume the following line' {
    $f = New-Fixture -Extension 'cfg' -Content "password=`nvisible=ordinary`nhost=`nstatus=healthy`n"
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Contains $text "password=`nvisible=ordinary"
    Assert-Contains $text "host=`nstatus=healthy"
}

Test-Case 'quoted multiline secret values are fully removed' {
    $f = New-Fixture -Extension 'cfg' -Content "password=`"synthetic-first-line`nsynthetic-second-line`"`nvisible=ordinary`n"
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('synthetic-first-line', 'synthetic-second-line')
    Assert-Contains $text 'visible=ordinary'
}

Test-Case 'unquoted secret punctuation cannot leave trailing fragments' {
    $f = New-Fixture -Extension 'cfg' -Content @'
password=synthetic;tail-secret
api_key=synthetic,comma-secret
token=synthetic<angle-secret>
password=synthetic;tail-with-next-field visible=ordinary
'@
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('synthetic', 'tail-secret', 'comma-secret', 'angle-secret', 'tail-with-next-field')
    Assert-Contains $text 'visible=ordinary'
}

Test-Case 'URL userinfo credentials are secret even without labeled fields' {
    $f = New-Fixture 'endpoint=https://synthetic-user:synthetic-url-password@service.example.test/resource visible=ordinary'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('synthetic-user', 'synthetic-url-password', 'service.example.test')
    Assert-Contains $text '/resource'
    Assert-Contains $text 'visible=ordinary'
}

Test-Case 'unquoted connection strings are masked through end of line' {
    $f = New-Fixture -Extension 'conf' -Content "ConnectionString=Server=SERVER01;Database=synthetic-db;User Id=synthetic-db-user;Password=synthetic-db-password`nvisible=ordinary`n"
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('SERVER01', 'synthetic-db', 'synthetic-db-user', 'synthetic-db-password')
    Assert-Contains $text 'visible=ordinary'
}

Test-Case 'quoted multiline connection strings retain their delimiters' {
    $f = New-Fixture -Extension 'cfg' -Content "ConnectionString = `"Server=SERVER01;`nPassword=synthetic-quoted-dsn`"`nvisible=ordinary`n"
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('SERVER01', 'synthetic-quoted-dsn')
    Assert-True ($text -match '(?m)^ConnectionString = "[^"\r\n]+"$') 'Quoted connection string delimiters were changed or left open.'
    Assert-Contains $text 'visible=ordinary'
}

Test-Case 'reversible mapping is opt in and reusable without token collisions' {
    $f = New-Fixture '192.0.2.1 alpha.test'
    $map = Join-Path $f.Directory 'mapping.xml'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; Mode = 'Obfuscate'; MapPath = $map })
    $first = [System.IO.File]::ReadAllText($f.Output).Trim() -split '\s+'
    $mapContent = [System.IO.File]::ReadAllText($map)
    Assert-Contains $mapContent '192.0.2.1'
    Assert-Contains $mapContent 'alpha.test'
    [System.IO.File]::WriteAllText($f.Input, '192.0.2.1 198.51.100.2 alpha.test beta.test', $script:Utf8)
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; Mode = 'Obfuscate'; MapPath = $map; Force = $true })
    $second = [System.IO.File]::ReadAllText($f.Output).Trim() -split '\s+'
    Assert-True ($first[0] -eq $second[0]) 'Reloaded IP mapping changed.'
    Assert-True ($first[1] -eq $second[2]) 'Reloaded hostname mapping changed.'
    Assert-True ($second[0] -ne $second[1]) 'New IP reused an existing token.'
    Assert-True ($second[2] -ne $second[3]) 'New hostname reused an existing token.'
}

Test-Case 'redaction refuses a reversible mapping path' {
    $f = New-Fixture '192.0.2.1'
    $map = Join-Path $f.Directory 'mapping.xml'
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; MapPath = $map })
    Assert-True (-not [System.IO.File]::Exists($map)) 'Redaction wrote a reversible mapping.'
}

Test-Case 'secret mapping remains case sensitive across map reloads' {
    $f = New-Fixture "password=CaseSensitiveSynthetic`npassword=casesensitivesynthetic`n"
    $map = Join-Path $f.Directory 'mapping.xml'
    $parameters = @{ Path = $f.Input; OutputPath = $f.Output; Mode = 'Obfuscate'; MapPath = $map }
    Assert-Success (Invoke-Obfuscator $parameters)
    $first = @([regex]::Matches([System.IO.File]::ReadAllText($f.Output), 'SECRET_[0-9]+') | ForEach-Object { $_.Value })
    Assert-True ($first.Count -eq 2 -and $first[0] -ne $first[1]) 'Case-distinct secrets shared a token.'
    $parameters.Force = $true
    Assert-Success (Invoke-Obfuscator $parameters)
    $second = @([regex]::Matches([System.IO.File]::ReadAllText($f.Output), 'SECRET_[0-9]+') | ForEach-Object { $_.Value })
    Assert-True (($first -join ',') -eq ($second -join ',')) 'Map reload changed or collapsed case-distinct secret tokens.'
}

Test-Case 'XML text attributes comments CDATA and encoded addresses' {
    $f = New-Fixture -Extension 'xml' -Content @'
<log xmlns="urn:synthetic:log" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" host="SERVER01" password="synthetic-attribute-secret">
  <ip>192&#46;0&#46;2&#46;1</ip>
  <domain>alpha&#46;test</domain>
  <password>synthetic-node-secret</password>
  <!-- source 198.51.100.2 -->
  <![CDATA[address=203.0.113.3 password=synthetic-cdata-secret]]>
</log>
'@
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $text = [System.IO.File]::ReadAllText($f.Output)
    $xml = [System.Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load($f.Output)
    Assert-True ($xml.DocumentElement.NamespaceURI -eq 'urn:synthetic:log') 'Default namespace changed.'
    Assert-True ($xml.DocumentElement.GetNamespaceOfPrefix('xsi') -eq 'http://www.w3.org/2001/XMLSchema-instance') 'Namespace URI changed.'
    Assert-Removed $xml.DocumentElement.InnerText @('192.0.2.1', 'alpha.test', 'synthetic-node-secret', '203.0.113.3', 'synthetic-cdata-secret')
    Assert-Removed $text @('SERVER01', 'synthetic-attribute-secret', '198.51.100.2')
}

Test-Case 'UTF16 XML keeps encoding declaration consistent with saved bytes' {
    $f = New-Fixture -Extension 'xml'
    [System.IO.File]::WriteAllText($f.Input, '<?xml version="1.0" encoding="utf-16"?><log><ip>192.0.2.1</ip><password>synthetic-password</password></log>', [System.Text.UnicodeEncoding]::new($false, $true, $true))
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $bytes = [System.IO.File]::ReadAllBytes($f.Output)
    Assert-True ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) 'UTF16 little-endian BOM was not preserved.'
    $xml = [System.Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load($f.Output)
    Assert-Removed $xml.DocumentElement.InnerText @('192.0.2.1', 'synthetic-password')
}

Test-Case 'XML configuration key-value attributes use field context' {
    $f = New-Fixture -Extension 'xml' -Content '<configuration><add key="password" value="synthetic-keyed-secret"/><entry name="server" value="SERVER01"/><add key="ordinary" value="retain-this"/></configuration>'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $xml = [System.Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load($f.Output)
    $text = [System.IO.File]::ReadAllText($f.Output)
    Assert-Removed $text @('synthetic-keyed-secret', 'SERVER01')
    Assert-Contains $text 'retain-this'
    Assert-Contains $text 'key="password"'
    Assert-Contains $text 'name="server"'
}

Test-Case 'XML configuration keys also apply to text values with whitespace' {
    $f = New-Fixture -Extension 'xml' -Content '<configuration><entry key="password">synthetic-keyed-text-secret</entry><entry key="host"> SERVER01 </entry><host> BACKUP02 </host><entry key="ordinary"> retain-this </entry></configuration>'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $xml = [System.Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load($f.Output)
    Assert-Removed $xml.DocumentElement.InnerText @('synthetic-keyed-text-secret', 'SERVER01', 'BACKUP02')
    Assert-Contains $xml.DocumentElement.InnerText ' retain-this '
    Assert-Contains ($xml.SelectSingleNode('/configuration/entry[@key="host"]').InnerText) ' '
}

Test-Case 'XML character-data boundaries cannot split sensitive values' {
    $f = New-Fixture -Extension 'xml' -Content '<log><domain>alpha<![CDATA[.test]]></domain><ip>192.0<![CDATA[.2.1]]></ip><value>synthetic-<![CDATA[split-sensitive]]></value><domain>beta<!-- harmless comment -->.test</domain></log>'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; SensitiveValues = @('synthetic-split-sensitive') })
    $xml = [System.Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load($f.Output)
    Assert-Removed $xml.DocumentElement.InnerText @('alpha.test', '192.0.2.1', 'synthetic-split-sensitive', 'beta.test')
    Assert-True ($xml.SelectNodes('//comment()').Count -eq 1) 'A harmless XML comment was dropped.'
}

Test-Case 'XML names cannot shadow DOM metadata and bypass redaction' {
    $f = New-Fixture -Extension 'xml' -Content '<OuterXml><ChildNodes>ordinary-child</ChildNodes><password LocalName="ordinary">synthetic-shadow-secret</password><password><Value>synthetic-nested-shadow-secret</Value></password></OuterXml>'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $xml = [System.Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load($f.Output)
    Assert-True ($xml.PSBase.DocumentElement.PSBase.LocalName -eq 'OuterXml') 'Root element name changed.'
    Assert-Removed $xml.PSBase.DocumentElement.PSBase.InnerText @('synthetic-shadow-secret', 'synthetic-nested-shadow-secret')
    Assert-Contains $xml.PSBase.DocumentElement.PSBase.InnerText 'ordinary-child'
    Assert-True ($null -ne $xml.PSBase.SelectSingleNode('/OuterXml/password[1]').PSBase.Attributes.GetNamedItem('LocalName')) 'An attribute name was dropped while reading DOM metadata.'
}

Test-Case 'XML in arbitrary extensions is recognized after a leading comment' {
    $f = New-Fixture -Extension 'config' -Content '<!-- harmless header --><log><ip>192&#46;0&#46;2&#46;1</ip><password>synthetic-comment-prefixed-secret</password></log>'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    $xml = [System.Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load($f.Output)
    Assert-Removed $xml.PSBase.DocumentElement.PSBase.InnerText @('192.0.2.1', 'synthetic-comment-prefixed-secret')
    Assert-True ($xml.PSBase.SelectNodes('//comment()').Count -eq 1) 'Leading harmless XML comment was dropped.'
}

Test-Case 'Latin1 requires explicit encoding and preserves non-ASCII text' {
    $f = New-Fixture
    [System.IO.File]::WriteAllBytes($f.Input, [System.Text.Encoding]::Latin1.GetBytes("message=caf$([char]0xe9) address=192.0.2.1"))
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; Encoding = 'Latin1' })
    $text = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($f.Output))
    Assert-Contains $text "caf$([char]0xe9)"
    Assert-Removed $text @('192.0.2.1')
}

foreach ($encodingCase in @(
    @{ Name = 'UTF8 BOM'; Encoding = [System.Text.UTF8Encoding]::new($true, $true) },
    @{ Name = 'UTF16 LE BOM'; Encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true) },
    @{ Name = 'UTF16 BE BOM'; Encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true) },
    @{ Name = 'UTF32 LE BOM'; Encoding = [System.Text.UTF32Encoding]::new($false, $true, $true) },
    @{ Name = 'UTF32 BE BOM'; Encoding = [System.Text.UTF32Encoding]::new($true, $true, $true) }
)) {
    Test-Case "Auto detects and preserves $($encodingCase.Name)" {
        $f = New-Fixture
        [System.IO.File]::WriteAllText($f.Input, "message=caf$([char]0xe9) address=192.0.2.1", $encodingCase.Encoding)
        Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
        $bytes = [System.IO.File]::ReadAllBytes($f.Output)
        $preamble = $encodingCase.Encoding.GetPreamble()
        for ($i = 0; $i -lt $preamble.Length; $i++) {
            Assert-True ($bytes.Length -gt $i -and $bytes[$i] -eq $preamble[$i]) 'Encoding BOM changed.'
        }
        $text = $encodingCase.Encoding.GetString($bytes, $preamble.Length, $bytes.Length - $preamble.Length)
        Assert-Contains $text "caf$([char]0xe9)"
        Assert-Removed $text @('192.0.2.1')
    }
}

Test-Case 'binary input is rejected despite a text filename' {
    $f = New-Fixture
    [System.IO.File]::WriteAllBytes($f.Input, [byte[]](0x50, 0x4b, 0x03, 0x04, 0, 0, 0x61, 0x62))
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    Assert-True (-not [System.IO.File]::Exists($f.Output)) 'Binary input produced sanitized output.'
}

Test-Case 'invalid UTF8 is rejected rather than silently losing bytes' {
    $f = New-Fixture
    [System.IO.File]::WriteAllBytes($f.Input, [byte[]](0x61, 0xc3, 0x28))
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    Assert-True (-not [System.IO.File]::Exists($f.Output)) 'Invalid UTF8 produced output.'
}

Test-Case 'malformed XML is rejected' {
    $f = New-Fixture -Content '<log><ip>192.0.2.1</log>' -Extension 'xml'
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    Assert-True (-not [System.IO.File]::Exists($f.Output)) 'Malformed XML produced output.'
}

Test-Case 'XML external entities are rejected without expansion' {
    $f = New-Fixture -Content '<!DOCTYPE log [<!ENTITY sensitive "synthetic-sensitive">]><log>&sensitive;</log>' -Extension 'xml'
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    Assert-True (-not [System.IO.File]::Exists($f.Output)) 'DTD input produced output.'
}

Test-Case 'missing output directory fails without reporting completion' {
    $f = New-Fixture '192.0.2.1'
    $output = Join-Path $f.Directory 'does-not-exist/output.log'
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $output })
    Assert-True (-not [System.IO.File]::Exists($output)) 'Missing-parent test produced output.'
}

Test-Case 'missing map directory fails before publishing sanitized output' {
    $f = New-Fixture '192.0.2.1'
    $map = Join-Path $f.Directory 'does-not-exist/map.xml'
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; MapPath = $map; Mode = 'Obfuscate' })
    Assert-True (-not [System.IO.File]::Exists($f.Output)) 'Failed map preparation left output behind.'
}

Test-Case 'bare relative input gets a valid default output path' {
    $f = New-Fixture '192.0.2.1'
    Assert-Success (Invoke-Obfuscator -WorkingDirectory $f.Directory -Parameters @{ Path = 'input.log' })
    $output = Join-Path $f.Directory 'input.redacted.log'
    Assert-True ([System.IO.File]::Exists($output)) 'Default redacted output was not created next to the input.'
    Assert-Removed ([System.IO.File]::ReadAllText($output)) @('192.0.2.1')
}

Test-Case 'relative paths follow Set-Location rather than process working directory' {
    $f = New-Fixture '192.0.2.1 password=synthetic-password'
    Assert-Success (Invoke-Obfuscator -PowerShellLocation $f.Directory -Parameters @{ Path = 'input.log'; OutputPath = 'published.log'; Mode = 'Obfuscate'; MapPath = 'private.map.xml' })
    $output = Join-Path $f.Directory 'published.log'
    $map = Join-Path $f.Directory 'private.map.xml'
    Assert-True ([System.IO.File]::Exists($output) -and [System.IO.File]::Exists($map)) 'Relative output/map paths were not resolved in the PowerShell current location.'
    Assert-Removed ([System.IO.File]::ReadAllText($output)) @('192.0.2.1', 'synthetic-password')
    Assert-True (-not [System.IO.File]::Exists((Join-Path $script:TestRoot 'published.log'))) 'Output was written into the process working directory.'
}

Test-Case 'output cannot overwrite the input even with Force' {
    $f = New-Fixture '192.0.2.1'
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Input; Force = $true })
    Assert-True ([System.IO.File]::ReadAllText($f.Input) -eq '192.0.2.1') 'Source changed on rejected collision.'
}

Test-Case 'map cannot overwrite sanitized output' {
    $f = New-Fixture '192.0.2.1'
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; MapPath = $f.Output; Mode = 'Obfuscate'; Force = $true })
    Assert-True (-not [System.IO.File]::Exists($f.Output)) 'Collision produced an output artifact.'
}

Test-Case 'map cannot overwrite original input' {
    $f = New-Fixture '192.0.2.1'
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; MapPath = $f.Input; Mode = 'Obfuscate'; Force = $true })
    Assert-True ([System.IO.File]::ReadAllText($f.Input) -eq '192.0.2.1') 'Map collision changed source.'
}

Test-Case 'existing output requires Force and is preserved on rejection' {
    $f = New-Fixture '192.0.2.1'
    [System.IO.File]::WriteAllText($f.Output, 'pre-existing-user-output', $script:Utf8)
    Assert-Failure (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output })
    Assert-True ([System.IO.File]::ReadAllText($f.Output) -eq 'pre-existing-user-output') 'Existing output changed without Force.'
    Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; Force = $true })
    Assert-Removed ([System.IO.File]::ReadAllText($f.Output)) @('192.0.2.1', 'pre-existing-user-output')
}

if (-not $IsWindows) {
    Test-Case 'Unix output and reversible maps have owner-only access' {
        $f = New-Fixture '192.0.2.1 alpha.test password=synthetic-password'
        $map = Join-Path $f.Directory 'mapping.xml'
        Assert-Success (Invoke-Obfuscator @{ Path = $f.Input; OutputPath = $f.Output; Mode = 'Obfuscate'; MapPath = $map })
        $otherAccess = [System.IO.UnixFileMode]::GroupRead -bor [System.IO.UnixFileMode]::GroupWrite -bor [System.IO.UnixFileMode]::GroupExecute -bor [System.IO.UnixFileMode]::OtherRead -bor [System.IO.UnixFileMode]::OtherWrite -bor [System.IO.UnixFileMode]::OtherExecute
        foreach ($path in @($f.Output, $map)) {
            $mode = [System.IO.File]::GetUnixFileMode($path)
            Assert-True (($mode -band $otherAccess) -eq 0) 'A sanitized output or sensitive map grants group/other access.'
            Assert-True (($mode -band [System.IO.UnixFileMode]::UserRead) -ne 0) 'An artifact is unreadable by its owner.'
        }
        Assert-True (@(Get-ChildItem -LiteralPath $f.Directory -Filter '.sanitize-*' -Force).Count -eq 0) 'Staged files were left behind after success.'
    }
}

Write-Host "`n$($script:Passed) passed; $($script:Failures.Count) failed."
if ($script:Failures.Count) {
    Write-Host "Synthetic fixtures retained at: $script:TestRoot"
    exit 1
}
Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
exit 0
