@{
    RootModule        = 'pp2.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'JohnnRen'
    CompanyName       = 'JohnnRen'
    Copyright         = '(c) 2026 JohnnRen. MIT License.'
    Description       = 'PowerShell-based service manager for managing background processes with dependency handling, auto-restart, and monitoring. Inspired by pm2.'
    PowerShellVersion = '7.0'
    
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
            Tags         = @('powershell', 'process-manager', 'pm2', 'service-manager', 'windows', 'background-process')
            LicenseUri   = 'https://github.com/john-walks-slow/pp2/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/john-walks-slow/pp2'
            IconUri      = ''
            ReleaseNotes = 'Initial release: PowerShell service manager with dependency handling, auto-restart, and monitoring.'
        }
    }
    
    HelpInfoURI = 'https://github.com/john-walks-slow/pp2#readme'
}