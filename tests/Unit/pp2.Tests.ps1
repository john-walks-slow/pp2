BeforeAll {
    $ModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\pp2'
    Import-Module (Join-Path $ModuleRoot 'pp2.psd1') -Force -ErrorAction Stop
}

Describe 'Module structure' {
    It 'Should export all expected functions' {
        $Exported = Get-Module pp2 | Select-Object -ExpandProperty ExportedFunctions
        $Exported.Keys | Should -Contain 'pp2'
        $Exported.Keys | Should -Contain 'Start-Pp2Service'
        $Exported.Keys | Should -Contain 'Stop-Pp2Service'
        $Exported.Keys | Should -Contain 'Restart-Pp2Service'
        $Exported.Keys | Should -Contain 'Get-Pp2Status'
        $Exported.Keys | Should -Contain 'Get-Pp2Logs'
        $Exported.Keys | Should -Contain 'Watch-Pp2Logs'
        $Exported.Keys | Should -Contain 'Start-Pp2Watchdog'
        $Exported.Keys | Should -Contain 'Stop-Pp2Watchdog'
        $Exported.Keys | Should -Contain 'Get-Pp2WatchdogStatus'
        $Exported.Keys | Should -Contain 'Install-Pp2Startup'
        $Exported.Keys | Should -Contain 'Uninstall-Pp2Startup'
    }

    It 'Should have a valid module manifest' {
        $Manifest = Test-ModuleManifest -Path (Join-Path $ModuleRoot 'pp2.psd1') -ErrorAction Stop
        $Manifest.Version | Should -BeGreaterThan '0.0.0'
        $Manifest.Author | Should -Not -BeNullOrEmpty
        $Manifest.Description | Should -Not -BeNullOrEmpty
    }

    It 'Should have Public and Private directories' {
        Join-Path $ModuleRoot 'Public' | Should -Exist
        Join-Path $ModuleRoot 'Private' | Should -Exist
    }
}

Describe 'pp2 CLI' {
    It 'Should accept help action without error' {
        { pp2 help } | Should -Not -Throw
    }
}
