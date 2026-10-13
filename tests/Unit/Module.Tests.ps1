<#
.SYNOPSIS
    Unit tests for module structure, manifest integrity and path resolution.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $ModuleRoot = Get-Pp2ModuleRoot
    Import-Module (Join-Path $ModuleRoot 'pp2.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module pp2 -Force -ErrorAction SilentlyContinue
}

Describe 'Module structure' {
    It 'exports every documented function' {
        $Exported = (Get-Module pp2).ExportedFunctions.Keys
        $Expected = @(
            'pp2'
            'Start-Pp2Service', 'Stop-Pp2Service', 'Restart-Pp2Service'
            'Get-Pp2Status', 'Get-Pp2Logs', 'Watch-Pp2Logs'
            'Start-Pp2Watchdog', 'Stop-Pp2Watchdog', 'Get-Pp2WatchdogStatus'
            'Install-Pp2Startup', 'Uninstall-Pp2Startup'
        )
        foreach ($Name in $Expected) {
            $Exported | Should -Contain $Name
        }
    }

    It 'has a manifest whose exported functions match the module' {
        $Manifest = Test-ModuleManifest -Path (Join-Path $ModuleRoot 'pp2.psd1')
        $FromManifest = $Manifest.ExportedFunctions.Keys | Sort-Object
        $FromModule = (Get-Module pp2).ExportedFunctions.Keys | Sort-Object
        $FromManifest | Should -Be $FromModule
    }

    It 'declares a version, author and description' {
        $Manifest = Test-ModuleManifest -Path (Join-Path $ModuleRoot 'pp2.psd1')
        $Manifest.Version | Should -BeGreaterThan ([version]'0.0.0')
        $Manifest.Author | Should -Not -BeNullOrEmpty
        $Manifest.Description | Should -Not -BeNullOrEmpty
        $Manifest.LicenseUri | Should -Not -BeNullOrEmpty
        $Manifest.ProjectUri | Should -Not -BeNullOrEmpty
    }

    It 'parses every source file without syntax errors' {
        $Errors = @()
        Get-ChildItem $ModuleRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' | ForEach-Object {
            $ParseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$ParseErrors)
            if ($ParseErrors) { $Errors += "$($_.Name): $($ParseErrors[0].Message)" }
        }
        $Errors | Should -BeNullOrEmpty
    }
}

Describe 'Path resolution' {
    # Regression guard: $script:ModuleRoot used to resolve to the Private/
    # directory, because it was assigned from $PSScriptRoot inside
    # Private/pp2-core.ps1. Every derived path then pointed at
    # Private/lib/..., so no service could ever start.
    It 'resolves ModuleRoot to the module directory, not Private/' {
        $Actual = & (Get-Module pp2) {
            Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
            $script:ModuleRoot
        }
        $Actual | Should -Be (Get-Pp2ModuleRoot)
        Split-Path $Actual -Leaf | Should -Be 'pp2'
    }

    It 'can locate every script the module launches' {
        $Missing = & (Get-Module pp2) {
            Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
            @(
                'lib\pp2-run-service.ps1'
                'lib\pp2-watchdog.ps1'
                'lib\pp2-watch-logs.ps1'
                'pp2.psd1'
                'Private\pp2-core.ps1'
            ) | Where-Object { -not (Test-Path (Join-Path $script:ModuleRoot $_)) }
        }
        $Missing | Should -BeNullOrEmpty
    }

    It 'reads PP2_HOME at call time, not import time' {
        $First = New-Pp2TestHome
        $Second = New-Pp2TestHome
        try {
            (& (Get-Module pp2) { Get-Pp2Root }) | Should -Be $Second
            $env:PP2_HOME = $First
            (& (Get-Module pp2) { Get-Pp2Root }) | Should -Be $First
        }
        finally {
            Remove-Pp2TestHome $First
            Remove-Pp2TestHome $Second
        }
    }
}

Describe 'Script-host compatibility' {
    # Regression guard: pp2-core.ps1 assigned $script:IsWindows, which
    # collides with the read-only automatic variable PowerShell 6+ provides.
    # Inside a module scope that assignment is tolerated, but the moment the
    # same file is dot-sourced from a running script (as pp2-run-service.ps1
    # does for every service launch) it throws and the service dies on start.
    It 'dot-sources cleanly in script scope' {
        $Core = Join-Path (Get-Pp2ModuleRoot) 'Private\pp2-core.ps1'
        $Script = Join-Path ([IO.Path]::GetTempPath()) "pp2-dotsource-$([guid]::NewGuid().ToString('n').Substring(0, 8)).ps1"
        Set-Content -Path $Script -Value ". '$Core'`nWrite-Output 'ok'" -Encoding UTF8
        try {
            $Result = & pwsh -NoProfile -File $Script 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $Result
            $Result | Should -Match 'ok'
            $Result | Should -Not -Match 'IsWindows'
        }
        finally { Remove-Item $Script -Force -ErrorAction SilentlyContinue }
    }
}
