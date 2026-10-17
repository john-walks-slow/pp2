@{
    RootModule           = 'pp2.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6e5b2c1a-8f4d-4a3e-9b7c-2d1f0e8a6c4b'
    Author               = 'JohnnRen'
    CompanyName          = 'JohnnRen'
    Copyright            = '(c) 2026 JohnnRen. MIT License.'
    Description          = 'PowerShell-based service manager for managing background processes with dependency handling, auto-restart, and monitoring. Inspired by pm2.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')

    # Parallel start/stop uses ThreadJob. Microsoft.PowerShell.ThreadJob is the
    # canonical name as of PowerShell 7.6; ThreadJob is the legacy name still
    # shipped with 7.4 and earlier. The module's .psm1 will fall back to the
    # legacy name when the new one is not available, so the manifest only
    # requires the canonical one and lets the loader resolve either.
    # ThreadJob is intentionally NOT a RequiredModule. PowerShell 7.6+ bundles
    # Microsoft.PowerShell.ThreadJob, so installing it per-user collides with
    # the bundled copy and Install-Module aborts with "commands are already
    # available on this system... use -AllowClobber". Naming it here would make
    # the documented `Install-Module pp2` fail for every user. pp2 imports it
    # at runtime when available and falls back to serial start/stop when not.
    FunctionsToExport = @(
        'pp2'
        'Start-Pp2Service'
        'Stop-Pp2Service'
        'Restart-Pp2Service'
        'Get-Pp2Status'
        'Get-Pp2Logs'
        'Watch-Pp2Logs'
        'Start-Pp2Watchdog'
        'Stop-Pp2Watchdog'
        'Get-Pp2WatchdogStatus'
        'Install-Pp2Startup'
        'Uninstall-Pp2Startup'
    )

    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('powershell', 'process-manager', 'pm2', 'service-manager', 'windows', 'background-process', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/john-walks-slow/pp2/blob/master/LICENSE'
            ProjectUri   = 'https://github.com/john-walks-slow/pp2'
            ReleaseNotes = 'Initial release: PowerShell service manager with dependency handling, auto-restart, and monitoring.'
        }
    }

    HelpInfoURI = 'https://github.com/john-walks-slow/pp2#readme'
}
