#requires -Version 7.4
<#
.SYNOPSIS
Redacts one text file, or substitutes stable tokens with -Mode Obfuscate.
.DESCRIPTION
Supports text-based logs/configuration regardless of extension, and XML data.
No reversible map is created unless explicitly requested with -MapPath.
Use -SensitiveValues and -SecretKeys for identifiers not inferable from context.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string]$Path,
    [string]$OutputPath,
    [ValidateSet('Redact', 'Obfuscate')][string]$Mode = 'Redact',
    [string]$MapPath,
    [string[]]$KnownHostnames = @(),
    [string[]]$SensitiveValues = @(),
    [string[]]$SecretKeys = @(),
    [ValidateSet('Auto', 'Utf8', 'Utf16LE', 'Utf16BE', 'Utf32LE', 'Utf32BE', 'Ascii', 'Latin1')]
    [string]$Encoding = 'Auto',
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-State {
    [pscustomobject]@{
        Version = 2
        IPMap = @{}; HostMap = @{}
        SecretMap = [hashtable]::new([StringComparer]::Ordinal)
        NextIP = 1; NextHost = 1; NextSecret = 1
    }
}

function Read-State([string]$File) {
    $loaded = Import-Clixml -LiteralPath $File
    if (-not $loaded.PSObject.Properties['Version'] -or $loaded.Version -ne 2) {
        throw 'Unsupported map version. Choose a new map path; legacy maps may contain duplicate tokens.'
    }
    $result = New-State
    $tokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($kind in @('IP', 'Host', 'Secret')) {
        $property = $kind + 'Map'
        if (-not $loaded.PSObject.Properties[$property] -or $loaded.$property -isnot [hashtable]) { throw 'Invalid map.' }
        foreach ($entry in $loaded.$property.GetEnumerator()) {
            if ($entry.Key -isnot [string] -or -not $entry.Key -or $entry.Value -isnot [string] -or
                $entry.Value -notmatch ('^' + $kind + '_([0-9]{4,})$') -or -not $tokens.Add($entry.Value)) {
                throw 'Map contains invalid or duplicate tokens.'
            }
            $number = [int]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            if ($number -ge [int]::MaxValue) { throw 'Mapping counter is exhausted.' }
            $result.$property[$entry.Key] = $entry.Value
            $counter = "Next$kind"
            $result.$counter = [Math]::Max($result.$counter, $number + 1)
        }
    }
    return $result
}

function Get-Token([string]$Kind, [string]$Original) {
    if ($Mode -eq 'Redact') { return "[REDACTED_$($Kind.ToUpperInvariant())]" }
    $map = $script:State.($Kind + 'Map')
    if ($map.ContainsKey($Original)) { return $map[$Original] }
    $counter = "Next$Kind"
    do {
        if ($script:State.$counter -ge [int]::MaxValue) { throw 'Mapping counter is exhausted.' }
        $token = '{0}_{1:0000}' -f $Kind.ToUpperInvariant(), $script:State.$counter
        $script:State.$counter = $script:State.$counter + 1
    } while ($script:ReservedTokens.Contains($token))
    [void]$script:ReservedTokens.Add($token)
    $map[$Original] = $token
    return $token
}

function Find-Matches([string]$Text, [string]$Pattern) {
    # Reject unexpectedly expensive matches rather than hang on untrusted input.
    $regex = [regex]::new($Pattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(5))
    return $regex.Matches($Text)
}

function Test-SecretName([string]$Name) {
    return $Name -match ('(?i)^(?:[a-z0-9]+[_.-])*(?:' + $script:KeyPattern + ')$')
}

function Protect-Text {
    param([AllowEmptyString()][string]$Text, [switch]$SecretValue, [switch]$HostValue)
    if ($Text.Length -eq 0) { return '' }
    if ($SecretValue) {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
        return Get-Token 'Secret' $Text
    }
    $ranges = [Collections.Generic.List[object]]::new()
    function Add-Range([int]$Start, [int]$Length, [string]$Kind, [int]$Priority) {
        if ($Length -gt 0) { $ranges.Add([pscustomobject]@{ Start = $Start; Length = $Length; Kind = $Kind; Priority = $Priority }) }
    }
    foreach ($value in $SensitiveValues) {
        if ($value) {
            foreach ($m in (Find-Matches $Text ([regex]::Escape($value)))) { Add-Range $m.Index $m.Length 'Secret' 0 }
        }
    }
    foreach ($m in (Find-Matches $Text '(?s)-----BEGIN (?<type>(?:[A-Z0-9]+ )*PRIVATE KEY)-----.*?-----END \k<type>-----')) {
        Add-Range $m.Index $m.Length 'Secret' 0
    }
    $valuePattern = '(?:"(?<double>(?:\\.|[^"\\])*)"|''(?<single>(?:\\.|[^''\\])*)''|(?<bare>[^\r\n]*?)(?=(?:[ \t]+|[,;][ \t]*)["'']?[a-zA-Z_][\w.-]*["'']?[ \t]*[:=]|[\r\n]|$))'
    $keyPrefix = '(?i)(?<![\w-])["'']?(?:[a-z0-9]+[_.-])*(?:' + $script:KeyPattern + ')["'']?'
    $assignment = $keyPrefix + '[ \t]*[:=][ \t]*' + $valuePattern
    $directive = '(?im)^[ \t]*(?:' + $script:KeyPattern + ')(?![ \t]*[:=])[ \t]+' + $valuePattern
    foreach ($pattern in @($assignment, $directive)) {
        foreach ($m in (Find-Matches $Text $pattern)) {
            foreach ($groupName in @('double', 'single', 'bare')) {
                $group = $m.Groups[$groupName]
                if ($group.Success) {
                    Add-Range $group.Index $group.Value.TrimEnd().Length 'Secret' 0
                    break
                }
            }
        }
    }
    foreach ($m in (Find-Matches $Text '(?i)\b(?:Bearer|Basic)[ \t]+(?<value>[a-z0-9+/_=.\-~]+)')) {
        Add-Range $m.Groups['value'].Index $m.Groups['value'].Length 'Secret' 0
    }
    # Credentials in service URLs are secrets even without a password field name.
    foreach ($m in (Find-Matches $Text '(?i)\b[a-z][a-z0-9+.-]*://(?<value>[^/\s@]+)@')) {
        Add-Range $m.Groups['value'].Index $m.Groups['value'].Length 'Secret' 0
    }
    # Unquoted connection strings can contain semicolon-separated credentials.
    foreach ($m in (Find-Matches $Text '(?im)(?<![\w-])connection[_-]?string[ \t]*[:=](?![ \t]*["''])[ \t]*(?<value>[^\r\n]+)')) {
        Add-Range $m.Groups['value'].Index $m.Groups['value'].Length 'Secret' 0
    }
    $octet = '(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    foreach ($m in (Find-Matches $Text ("(?<![a-zA-Z0-9_.])(?:$octet\.){3}$octet(?![a-zA-Z0-9_.])"))) {
        Add-Range $m.Index $m.Length 'IP' 1
    }
    foreach ($m in (Find-Matches $Text '(?<![a-zA-Z0-9_:.%])(?:[a-fA-F0-9]{0,4}:){2,}[a-fA-F0-9:.]*(?:%[a-zA-Z0-9_.-]+)?(?![a-zA-Z0-9_:.%])')) {
        $address = $null
        if ([Net.IPAddress]::TryParse($m.Value, [ref]$address) -and $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
            Add-Range $m.Index $m.Length 'IP' 1
        }
    }
    $label = '[a-zA-Z0-9_](?:[a-zA-Z0-9_-]{0,61}[a-zA-Z0-9_])?'
    foreach ($m in (Find-Matches $Text ("(?<![a-zA-Z0-9_.-])(?:$label\.)+[a-zA-Z]{2,63}\.?(?![a-zA-Z0-9_.-])"))) {
        if ($m.Length -le 254) { Add-Range $m.Index $m.Length 'Host' 2 }
    }
    foreach ($value in $KnownHostnames) {
        if ($value) {
            $pattern = '(?i)(?<![a-z0-9_.-])' + [regex]::Escape($value) + '(?![a-z0-9_.-])'
            foreach ($m in (Find-Matches $Text $pattern)) { Add-Range $m.Index $m.Length 'Host' 2 }
        }
    }
    $hostAssignment = '(?i)(?<![\w-])["'']?(?:' + $script:HostKeys + ')["'']?[ \t]*[:=][ \t]*["'']?(?<host>[a-z0-9_][a-z0-9_.-]*)(?![a-z0-9_.-])'
    $hostDirective = '(?im)^[ \t]*(?:' + $script:HostKeys + ')(?![ \t]*[:=])[ \t]+["'']?(?<host>[a-z0-9_][a-z0-9_.-]*)(?![a-z0-9_.-])'
    foreach ($pattern in @($hostAssignment, $hostDirective)) {
        foreach ($m in (Find-Matches $Text $pattern)) {
            $group = $m.Groups['host']
            $tail = $Text.Substring($group.Index + $group.Length)
            if ($tail -match '^:(?![0-9])') { continue } # Do not replace a URL scheme.
            if ($group.Value -match '[a-zA-Z_]' -and $group.Length -le 254) { Add-Range $group.Index $group.Length 'Host' 2 }
        }
    }
    if ($HostValue -and $Text.Trim() -match '^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,253}$' -and $Text.Trim() -match '[a-zA-Z_]') {
        Add-Range ($Text.Length - $Text.TrimStart().Length) $Text.Trim().Length 'Host' 2
    }
    # Original ranges prevent partial replacement and matching inserted tokens.
    $ordered = $ranges | Sort-Object Start, Priority, @{ Expression = 'Length'; Descending = $true }
    # Union overlapping matches so a secret's suffix can never be discarded.
    $merged = [Collections.Generic.List[object]]::new()
    foreach ($range in $ordered) {
        if ($merged.Count -gt 0) {
            $previous = $merged[$merged.Count - 1]
            if ($range.Start -lt $previous.Start + $previous.Length) {
                $previous.Length = [Math]::Max($previous.Start + $previous.Length, $range.Start + $range.Length) - $previous.Start
                if ($range.Priority -lt $previous.Priority) {
                    $previous.Priority = $range.Priority
                    $previous.Kind = $range.Kind
                }
                continue
            }
        }
        $merged.Add($range)
    }
    $builder = [Text.StringBuilder]::new()
    $position = 0
    foreach ($range in $merged) {
        [void]$builder.Append($Text, $position, $range.Start - $position)
        [void]$builder.Append((Get-Token $range.Kind $Text.Substring($range.Start, $range.Length)))
        $position = $range.Start + $range.Length
    }
    [void]$builder.Append($Text, $position, $Text.Length - $position)
    return $builder.ToString()
}

function Get-TextEncoding([string]$Name) {
    switch ($Name.ToLowerInvariant().Replace('-', '')) {
        'utf8' { return [Text.UTF8Encoding]::new($false, $true) }
        { $_ -in 'utf16', 'utf16le', 'unicode' } { return [Text.UnicodeEncoding]::new($false, $false, $true) }
        'utf16be' { return [Text.UnicodeEncoding]::new($true, $false, $true) }
        { $_ -in 'utf32', 'utf32le' } { return [Text.UTF32Encoding]::new($false, $false, $true) }
        'utf32be' { return [Text.UTF32Encoding]::new($true, $false, $true) }
        { $_ -in 'ascii', 'usascii' } { return [Text.Encoding]::GetEncoding(20127, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback) }
        { $_ -in 'latin1', 'iso88591' } { return [Text.Encoding]::GetEncoding(28591, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback) }
        default { throw "Unsupported text encoding: $Name" }
    }
}

function Read-Text([string]$File) {
    $bytes = [IO.File]::ReadAllBytes($File)
    $offset = 0
    $detected = $null
    $signature = [Convert]::ToHexString($bytes, 0, [Math]::Min(4, $bytes.Length))
    if ($signature.StartsWith('FFFE0000')) { $detected = 'Utf32LE'; $offset = 4 }
    elseif ($signature.StartsWith('0000FEFF')) { $detected = 'Utf32BE'; $offset = 4 }
    elseif ($signature.StartsWith('EFBBBF')) { $detected = 'Utf8'; $offset = 3 }
    elseif ($signature.StartsWith('FFFE')) { $detected = 'Utf16LE'; $offset = 2 }
    elseif ($signature.StartsWith('FEFF')) { $detected = 'Utf16BE'; $offset = 2 }
    $selected = $Encoding
    if ($selected -eq 'Auto') {
        if ($detected) { $selected = $detected }
        else {
            $selected = 'Utf8'
            $prefix = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(512, $bytes.Length))
            if ($prefix -match '^<\?xml\s+[^>]*encoding\s*=\s*["''](?<encoding>[^"'']+)["'']') { $selected = $Matches['encoding'] }
        }
    }
    $codec = Get-TextEncoding $selected
    if ($detected -and $codec.CodePage -ne (Get-TextEncoding $detected).CodePage) { throw 'Requested encoding conflicts with the input BOM.' }
    $text = $codec.GetString($bytes, $offset, $bytes.Length - $offset)
    if ($text -match '[\x00-\x08\x0e-\x1a\x1c-\x1f\x7f]' -or $text.StartsWith('%PDF-')) {
        throw 'Input is binary or contains unsupported control characters; only text files are supported.'
    }
    $preamble = [byte[]]::new($offset)
    if ($offset) { [Array]::Copy($bytes, $preamble, $offset) }
    return [pscustomobject]@{ Text = $text; Codec = $codec; Preamble = $preamble }
}

function Read-Xml([string]$Text) {
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($Text), $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.PSBase.PreserveWhitespace = $true
        $document.PSBase.XmlResolver = $null
        $document.PSBase.Load($reader)
        return ,$document
    } finally { $reader.Dispose() }
}

function Protect-XmlNode($Node, [bool]$InheritedSecret = $false, [bool]$InheritedHost = $false) {
    $secret = $InheritedSecret
    $hostContext = $InheritedHost
    if ($Node -is [Xml.XmlElement]) {
        # PSBase avoids the XML adapter: an attribute/child named LocalName,
        # ChildNodes, Value, etc. must never shadow the underlying DOM members.
        $secret = $secret -or (Test-SecretName $Node.PSBase.LocalName)
        $hostContext = $Node.PSBase.LocalName -match ('(?i)^(?:' + $script:HostKeys + ')$')
        # Common XML configuration: <add key="password" value="..."/>.
        $valueSecret = $false
        $valueHost = $false
        foreach ($attribute in $Node.PSBase.Attributes) {
            if ($attribute.PSBase.LocalName -in @('key', 'name')) {
                $valueSecret = $valueSecret -or (Test-SecretName $attribute.PSBase.Value)
                $valueHost = $valueHost -or ($attribute.PSBase.Value -match ('(?i)^(?:' + $script:HostKeys + ')$'))
            }
        }
        foreach ($attribute in $Node.PSBase.Attributes) {
            if ($attribute.PSBase.NamespaceURI -eq 'http://www.w3.org/2000/xmlns/') { continue }
            $isValue = $attribute.PSBase.LocalName -eq 'value'
            $attribute.PSBase.Value = Protect-Text $attribute.PSBase.Value -SecretValue:($secret -or (Test-SecretName $attribute.PSBase.LocalName) -or ($isValue -and $valueSecret)) -HostValue:(($attribute.PSBase.LocalName -match ('(?i)^(?:' + $script:HostKeys + ')$')) -or ($isValue -and $valueHost))
        }
    }
    if ($Node -is [Xml.XmlElement]) {
        $secret = $secret -or $valueSecret
        $hostContext = $hostContext -or $valueHost
        # XML can split values at CDATA boundaries and comments. Sanitize direct
        # character-data runs together, without changing names or child elements.
        $run = [Collections.Generic.List[Xml.XmlNode]]::new()
        foreach ($child in @($Node.PSBase.ChildNodes) + @($null)) {
            if ($null -ne $child -and $child.PSBase.NodeType -in @(
                [Xml.XmlNodeType]::Text, [Xml.XmlNodeType]::CDATA,
                [Xml.XmlNodeType]::Whitespace, [Xml.XmlNodeType]::SignificantWhitespace
            )) {
                $run.Add($child)
                continue
            }
            if ($null -ne $child -and $child.PSBase.NodeType -eq [Xml.XmlNodeType]::Comment) { continue }
            if ($run.Count -gt 1) {
                $combined = ($run | ForEach-Object { $_.PSBase.Value }) -join ''
                [void]$Node.PSBase.ReplaceChild($Node.PSBase.OwnerDocument.PSBase.CreateTextNode($combined), $run[0])
                for ($i = 1; $i -lt $run.Count; $i++) { [void]$Node.PSBase.RemoveChild($run[$i]) }
            }
            $run.Clear()
        }
    }
    if ($Node.PSBase.NodeType -in @([Xml.XmlNodeType]::Text, [Xml.XmlNodeType]::CDATA, [Xml.XmlNodeType]::Comment, [Xml.XmlNodeType]::ProcessingInstruction)) {
        $Node.PSBase.Value = Protect-Text $Node.PSBase.Value -SecretValue:$secret -HostValue:$hostContext
    }
    foreach ($child in $Node.PSBase.ChildNodes) { Protect-XmlNode $child $secret $hostContext }
}

function Get-CanonicalPath([string]$File) {
    # PowerShell's current location may differ from the process working directory.
    $provider = $null
    $drive = $null
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($File, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'File paths must use the FileSystem provider.' }
    $current = [IO.Path]::GetPathRoot($full)
    $parts = $full.Substring($current.Length).Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($part in $parts) {
        $current = [IO.Path]::Combine($current, $part)
        $entry = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($entry -and $entry.LinkTarget) {
            $target = $entry.ResolveLinkTarget($true)
            if (-not $target) { throw 'Unable to resolve a symbolic link in a file path.' }
            $current = $target.FullName
        }
    }
    return $current
}

function Test-Destination([string]$File) {
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($File))) { throw 'The destination directory does not exist.' }
    if ([IO.Directory]::Exists($File)) { throw 'A destination path is a directory.' }
    if ([IO.File]::Exists($File) -and -not $Force) { throw 'A destination exists. Choose a new path or use -Force.' }
}

function New-StagedFile([string]$Destination, [byte[]]$Bytes, [byte[]]$Preamble = @()) {
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.sanitize-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    if (-not $IsWindows) {
        # Permissions must be restrictive from creation, before any data is written.
        $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
    }
    try {
        $stream = [IO.FileStream]::new($temporary, $options)
        try {
            $stream.Write($Preamble)
            $stream.Write($Bytes)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        return $temporary
    } catch {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        throw
    }
}

$temporaryOutput = $null
$temporaryMap = $null
try {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo]) { throw 'Input must be a single regular file.' }
    $inputFile = Get-CanonicalPath $item.FullName
    if (-not $OutputPath) {
        $suffix = if ($Mode -eq 'Redact') { 'redacted' } else { 'obfuscated' }
        $OutputPath = Join-Path $item.DirectoryName ($item.BaseName + ".$suffix" + $item.Extension)
    }
    $outputFile = Get-CanonicalPath $OutputPath
    $mapFile = if ($MapPath) { Get-CanonicalPath $MapPath } else { $null }
    if ($mapFile -and $Mode -ne 'Obfuscate') { throw '-MapPath is available only in Obfuscate mode.' }
    $comparison = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    if ($comparison.Equals($inputFile, $outputFile) -or
        ($mapFile -and ($comparison.Equals($mapFile, $inputFile) -or $comparison.Equals($mapFile, $outputFile)))) {
        throw 'Input, output, and mapping paths must be distinct.'
    }
    Test-Destination $outputFile
    if ($mapFile) { Test-Destination $mapFile }
    $script:State = if ($mapFile -and [IO.File]::Exists($mapFile)) { Read-State $mapFile } else { New-State }
    $script:ReservedTokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($kind in @('IP', 'Host', 'Secret')) {
        foreach ($token in $script:State.($kind + 'Map').Values) { [void]$script:ReservedTokens.Add($token) }
    }
    $keys = @('password', 'passwd', 'pwd', 'secret', 'client_secret', 'token', 'access_token', 'refresh_token',
        'api_key', 'apikey', 'authorization', 'connection_string', 'private_key', 'community') + $SecretKeys
    $script:KeyPattern = ($keys | Where-Object { $_ } | ForEach-Object { ([regex]::Escape($_) -replace '[_-]', '[_-]?') }) -join '|'
    $script:HostKeys = 'host(?:name)?|server(?:name)?|computer(?:name)?|machine(?:name)?|node(?:name)?|domain(?:name)?|fqdn'
    $inputText = Read-Text $inputFile
    foreach ($m in (Find-Matches $inputText.Text '\b(?:IP|HOST|SECRET)_[0-9]+\b')) { [void]$script:ReservedTokens.Add($m.Value) }
    $isXml = $item.Extension -ieq '.xml' -or $inputText.Text -match '^\s*<\?xml\b'
    $document = $null
    if ($isXml) { $document = Read-Xml $inputText.Text }
    elseif ($inputText.Text -match '^\s*<(?:[a-zA-Z_:]|!--|!DOCTYPE)') {
        try { $document = Read-Xml $inputText.Text; $isXml = $true }
        catch { throw 'XML-like text is not well-formed XML. Fix it before sanitizing.' }
    }
    if ($isXml) {
        Protect-XmlNode $document
        foreach ($node in $document.PSBase.ChildNodes) {
            if ($node -is [Xml.XmlDeclaration]) { $node.PSBase.Encoding = $inputText.Codec.WebName }
        }
        $outputText = $document.PSBase.OuterXml
        [void](Read-Xml $outputText)
    } else { $outputText = Protect-Text $inputText.Text }
    $bytes = $inputText.Codec.GetBytes($outputText)
    $temporaryOutput = New-StagedFile $outputFile $bytes $inputText.Preamble
    if ($isXml) {
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($temporaryOutput, $settings)
        try { while ($reader.Read()) { } } finally { $reader.Dispose() }
    }
    if ($mapFile) {
        $mapXml = [Management.Automation.PSSerializer]::Serialize($script:State, 6)
        $temporaryMap = New-StagedFile $mapFile ([Text.UTF8Encoding]::new($false, $true).GetBytes($mapXml))
        [IO.File]::Move($temporaryMap, $mapFile, [bool]$Force)
        $temporaryMap = $null
    }
    [IO.File]::Move($temporaryOutput, $outputFile, [bool]$Force)
    $temporaryOutput = $null
    Write-Host "$Mode complete."
    Write-Host "  Output: $outputFile"
    if ($mapFile) { Write-Host "  Sensitive reversible map: $mapFile" }
} finally {
    foreach ($file in @($temporaryOutput, $temporaryMap)) {
        if ($file -and [IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
}
