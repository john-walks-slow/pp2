<#
.SYNOPSIS
    Unit tests for configuration loading and dependency resolution.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    Import-Module (Join-Path (Get-Pp2ModuleRoot) 'pp2.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module pp2 -Force -ErrorAction SilentlyContinue
}

Describe 'Configuration loading' {
    BeforeEach { $TestHome = New-Pp2TestHome }
    AfterEach { Remove-Pp2TestHome $TestHome }

    It 'creates a default config when none exists' {
        Remove-Item (Join-Path $TestHome 'services.json') -Force
        pp2 status | Out-Null
        Join-Path $TestHome 'services.json' | Should -Exist
    }

    It 'treats an empty config file as an empty service list' {
        Set-Content (Join-Path $TestHome 'services.json') -Value '' -Encoding UTF8
        { pp2 list } | Should -Not -Throw
        pp2 list | Should -BeNullOrEmpty
    }

    It 'rejects malformed JSON with an actionable message' {
        $Path = Join-Path $TestHome 'services.json'
        Set-Content $Path -Value '{ "services": ' -Encoding UTF8
        { pp2 -Config $Path list } | Should -Throw '*Invalid JSON*'
    }

    It 'reports a missing -Config file rather than failing obscurely' {
        { pp2 -Config (Join-Path $TestHome 'nope.json') list } |
            Should -Throw '*Config file not found*'
    }

    It 'normalises a config with no settings or services section' {
        # Services with no sibling "settings" key used to fail on first access
        # because the section was never materialised.
        $Path = Join-Path $TestHome 'partial.json'
        '{"services":{"solo":{"command":"pwsh","arguments":["-NoProfile","-Command","exit 0"]}}}' |
            Set-Content $Path -Encoding UTF8
        { pp2 -Config $Path list } | Should -Not -Throw
        (pp2 -Config $Path list | Out-String).Trim() | Should -Be 'solo'
    }

    It 'honours a config file supplied via -Config' {
        $Path = Join-Path $TestHome 'custom.json'
        '{"settings":{},"services":{"custom-svc":{"command":"pwsh"}}}' | Set-Content $Path -Encoding UTF8
        (pp2 -Config $Path list | Out-String).Trim() | Should -Be 'custom-svc'
    }

    It 'hides services marked as disabled' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                on  = @{ command = 'pwsh'; enable = $true }
                off = @{ command = 'pwsh'; enable = $false }
            })
        try {
            $Names = pp2 list | ForEach-Object { $_.ToString() }
            $Names | Should -Contain 'on'
            $Names | Should -Not -Contain 'off'
        }
        finally { Remove-Pp2TestHome $Home_ }
    }

    It 'reports an unknown service by name' {
        { pp2 start ghost } | Should -Throw '*Unknown service: ghost*'
    }

    It 'reads settings overrides' {
        $Home_ = New-Pp2TestHome -Settings @{ portCheckTimeout = 1234 }
        try {
            $Actual = & (Get-Module pp2) {
                Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
                Read-Pp2Config
                [pscustomobject]@{
                    Overridden = Get-Setting 'portCheckTimeout' 200
                    Fallback   = Get-Setting 'notSet' 'fallback'
                }
            }
            $Actual.Overridden | Should -Be 1234
            $Actual.Fallback | Should -Be 'fallback'
        }
        finally { Remove-Pp2TestHome $Home_ }
    }
}

Describe 'Dependency ordering' {
    BeforeEach {
        $TestHome = New-Pp2TestHome -Services ([ordered]@{
                db  = @{ command = 'pwsh' }
                api = @{ command = 'pwsh'; dependsOn = @('db') }
                web = @{ command = 'pwsh'; dependsOn = @('api') }
            })
    }
    AfterEach { Remove-Pp2TestHome $TestHome }

    It 'layers dependencies so prerequisites start first' {
        $Layers = & (Get-Module pp2) {
            Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
            Read-Pp2Config
            Get-DependencyLayers @('db', 'api', 'web')
        }
        $Layers.Count | Should -Be 3
        $Layers[0] | Should -Be 'db'
        $Layers[1] | Should -Be 'api'
        $Layers[2] | Should -Be 'web'
    }

    It 'reverses the order for stop so dependents go first' {
        $Layers = & (Get-Module pp2) {
            Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
            Read-Pp2Config
            Get-DependencyLayers @('db', 'api', 'web') -Reverse
        }
        $Layers[0] | Should -Be 'web'
        $Layers[2] | Should -Be 'db'
    }

    It 'groups independent services into a single layer' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                a = @{ command = 'pwsh' }
                b = @{ command = 'pwsh' }
                c = @{ command = 'pwsh' }
            })
        try {
            $Layers = & (Get-Module pp2) {
                Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
                Read-Pp2Config
                Get-DependencyLayers @('a', 'b', 'c')
            }
            $Layers.Count | Should -Be 1
            @($Layers[0]).Count | Should -Be 3
        }
        finally { Remove-Pp2TestHome $Home_ }
    }

    It 'warns instead of hanging on a dependency cycle' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                a = @{ command = 'pwsh'; dependsOn = @('b') }
                b = @{ command = 'pwsh'; dependsOn = @('a') }
            })
        try {
            # Warnings raised inside module scope reach the caller's warning
            # stream, which 3>&1 folds back into the output for inspection.
            $Output = & (Get-Module pp2) {
                Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
                Read-Pp2Config
                Get-DependencyLayers @('a', 'b') | Out-Null
            } 3>&1
            ($Output | Out-String) | Should -Match 'Circular dependency'
        }
        finally { Remove-Pp2TestHome $Home_ }
    }
}
