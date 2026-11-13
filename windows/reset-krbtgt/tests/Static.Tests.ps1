$repositoryRoot = Split-Path -Parent $PSScriptRoot

Describe 'PowerShell release gates' {
    It 'parses every distributable PowerShell file with no errors' {
        $files = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File | Where-Object {
                $_.Extension -in @('.ps1', '.psm1', '.psd1') -and
                $_.FullName -notmatch '[\\/]\.research[\\/]'
            })
        foreach ($file in $files) {
            $tokens = $null
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$parseErrors
            ) | Out-Null
            @($parseErrors).Count | Should Be 0
        }
    }

    It 'has no findings under the release analyzer configuration' {
        $settings = Join-Path -Path $repositoryRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
        $releaseFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File | Where-Object {
                $_.Extension -in @('.ps1', '.psm1', '.psd1') -and
                $_.FullName -notmatch '[\\/]\.research[\\/]'
            })
        $findings = @($releaseFiles | ForEach-Object {
                Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings
            })
        $findings.Count | Should Be 0
    }

    It 'does not contain prohibited network, policy, remoting, scheduling, or mail commands' {
        $implementationFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File | Where-Object {
                $_.Extension -in @('.ps1', '.psm1') -and
                $_.FullName -notmatch '[\\/]tests[\\/]' -and
                $_.FullName -notmatch '[\\/]\.research[\\/]'
            })
        $source = ($implementationFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $prohibited = @(
            'Set-ExecutionPolicy', 'Invoke-WebRequest', 'Invoke-RestMethod',
            'Send-MailMessage', 'New-PSSession', 'Enter-PSSession',
            'Register-ScheduledTask', 'Start-Job', 'gpupdate',
            'Set-GPRegistryValue', 'New-GPO', 'Set-GPLink'
        )
        foreach ($command in $prohibited) {
            $source | Should Not Match ([regex]::Escape($command))
        }
    }
}

Describe 'Published schemas and fixtures' {
    It 'parses every JSON schema and fixture' {
        $jsonFiles = @(
            Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'schemas') -Filter '*.json' -File
            Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests\fixtures') -Filter '*.json' -File
        )
        foreach ($file in $jsonFiles) {
            { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
        }
    }
}
