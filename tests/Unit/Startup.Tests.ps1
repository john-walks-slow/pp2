<#
.SYNOPSIS
    Unit tests for the startup (logon task) commands.

.DESCRIPTION
    The task itself is an OS side effect, so these tests cover the pure pieces
    that decide what gets registered: the task name, the command line it runs,
    and the guard that refuses to register a task importing an uninstalled copy
    of pp2. That last guard is a regression test: the old implementation
    registered a Highest task from a non-elevated shell, swallowed "access
    denied", and printed success.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    Import-Module (Join-Path (Get-Pp2ModuleRoot) 'pp2.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module pp2 -Force -ErrorAction SilentlyContinue
}

Describe 'Startup task naming' {
    It 'uses the base name when no service is named' {
        $Actual = & (Get-Module pp2) { Get-StartupTaskName @('all') }
        $Actual | Should -Be 'pp2 Startup'
    }

    It 'names the task after the services it starts' {
        $Actual = & (Get-Module pp2) { Get-StartupTaskName @('dsh') }
        $Actual | Should -Be 'pp2 Startup (dsh)'
    }

    It 'sorts and de-duplicates so the same set reuses one task' {
        $Actual = & (Get-Module pp2) { Get-StartupTaskName @('dsh', 'cpa', 'dsh') }
        $Actual | Should -Be 'pp2 Startup (cpa,dsh)'
    }

    It 'accepts a comma-separated list like the rest of the CLI' {
        $Actual = & (Get-Module pp2) { Get-StartupServiceNames @('cpa,dsh') }
        $Actual | Should -Be @('cpa', 'dsh')
    }

    It 'treats a named service as more specific than all' {
        $Actual = & (Get-Module pp2) { Get-StartupServiceNames @('all', 'dsh') }
        $Actual | Should -Be @('dsh')
    }
}

Describe 'Startup task action' {
    It 'starts every service when none is named' {
        $Arguments = & (Get-Module pp2) {
            New-StartupTaskAction -ModuleName 'pp2' -StateRoot 'C:\Users\test\.pp2' -Name @('all')
        } | ForEach-Object Arguments

        $Arguments | Should -Match 'pp2 start all'
        $Arguments | Should -Not -Match 'pp2 start all.*-Config'
    }

    It 'starts only the named services' {
        $Arguments = & (Get-Module pp2) {
            New-StartupTaskAction -ModuleName 'pp2' -StateRoot 'C:\Users\test\.pp2' -Name @('dsh')
        } | ForEach-Object Arguments

        $Arguments | Should -Match "pp2 start @\('dsh'\)"
        $Arguments | Should -Not -Match 'start all'
    }

    It 'imports the module by name so upgrades are picked up' {
        $Arguments = & (Get-Module pp2) {
            New-StartupTaskAction -ModuleName 'pp2' -StateRoot 'C:\Users\test\.pp2' -Name @('dsh')
        } | ForEach-Object Arguments

        $Arguments | Should -Match "Import-Module -Name 'pp2'"
        $Arguments | Should -Not -Match '\.psd1'
    }

    It 'pins a custom config path but not the default one' {
        $Default = & (Get-Module pp2) {
            New-StartupTaskAction -ModuleName 'pp2' -StateRoot 'C:\Users\test\.pp2' `
                -Name @('dsh') -ConfigPath 'C:\Users\test\.pp2\services.json'
        } | ForEach-Object Arguments
        $Custom = & (Get-Module pp2) {
            New-StartupTaskAction -ModuleName 'pp2' -StateRoot 'C:\Users\test\.pp2' `
                -Name @('dsh') -ConfigPath 'D:\other\services.json'
        } | ForEach-Object Arguments

        $Default | Should -Not -Match '-Config'
        $Custom | Should -Match "-Config 'D:\\other\\services.json'"
    }

    It 'launches pwsh hidden so logon does not flash a window' {
        $Arguments = & (Get-Module pp2) {
            New-StartupTaskAction -ModuleName 'pp2' -StateRoot 'C:\Users\test\.pp2' -Name @('dsh')
        } | ForEach-Object Arguments

        $Arguments | Should -Match '-WindowStyle Hidden'
    }
}

Describe 'Startup module resolution' {
    # The candidate list is injected so these cases do not depend on pp2 being
    # installed on the machine, which CI (and a fresh clone) does not guarantee.
    BeforeAll {
        $script:InstalledBase = Join-Path ([IO.Path]::GetTempPath()) 'mods/pp2/1.2.0'
        $script:Installed = @([pscustomobject]@{ ModuleBase = $script:InstalledBase })
    }

    It 'accepts the copy PowerShell resolves for the name' {
        $Accepted = & (Get-Module pp2) {
            param($Root, $Avail)
            Test-ModuleRootResolvable -ModuleRoot $Root -ModuleName pp2 -Available $Avail
        } $script:InstalledBase $script:Installed

        $Accepted | Should -BeTrue
    }

    It 'ignores case and a trailing separator in the module root' {
        $Accepted = & (Get-Module pp2) {
            param($Root, $Avail)
            Test-ModuleRootResolvable -ModuleRoot $Root -ModuleName pp2 -Available $Avail
        } ($script:InstalledBase.ToUpper() + '\') $script:Installed

        $Accepted | Should -BeTrue
    }

    It 'refuses a path that merely sits beneath a PSModulePath entry' {
        # Walking up to find a PSModulePath entry would accept any nested
        # directory (e.g. a clone under a module root), but Import-Module looks
        # only at <entry>/<name>/<version>/, so the task would fail at logon.
        $Accepted = & (Get-Module pp2) {
            param($Root, $Avail)
            Test-ModuleRootResolvable -ModuleRoot $Root -ModuleName pp2 -Available $Avail
        } (Join-Path $script:InstalledBase 'src/pp2') $script:Installed

        $Accepted | Should -BeFalse
    }

    It 'refuses when the name resolves to nothing' {
        $Accepted = & (Get-Module pp2) {
            param($Root, $Avail)
            Test-ModuleRootResolvable -ModuleRoot $Root -ModuleName pp2 -Available $Avail
        } $script:InstalledBase @()

        $Accepted | Should -BeFalse
    }

    It 'reports the failure through Assert-ModuleOnPSModulePath' {
        {
            & (Get-Module pp2) {
                param($Root) Assert-ModuleOnPSModulePath -ModuleRoot $Root -ModuleName pp2
            } (Join-Path ([IO.Path]::GetTempPath()) 'pp2-checkout/src/pp2')
        } | Should -Throw '*not the copy Import-Module resolves*'
    }

    It 'rejects an unknown service before touching Task Scheduler' {
        $TestHome = New-Pp2TestHome -Services ([ordered]@{ dsh = @{ command = 'pwsh' } })
        try {
            { pp2 startup-install nosuch } | Should -Throw '*Unknown service*'
        }
        finally { Remove-Pp2TestHome $TestHome }
    }

    It 'rejects mixing all with service names' {
        $TestHome = New-Pp2TestHome -Services ([ordered]@{ dsh = @{ command = 'pwsh' } })
        try {
            { pp2 startup-install all,dsh } | Should -Throw '*either*not both*'
        }
        finally { Remove-Pp2TestHome $TestHome }
    }

    It 'rejects a second positional name instead of dropping it' {
        $TestHome = New-Pp2TestHome -Services ([ordered]@{ dsh = @{ command = 'pwsh' } })
        try {
            { pp2 startup-install a b } | Should -Throw '*comma-separated list*'
        }
        finally { Remove-Pp2TestHome $TestHome }
    }
}