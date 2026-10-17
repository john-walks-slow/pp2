# ThreadJob powers parallel start/stop but is not required. PowerShell ships
# it under different names across versions (Microsoft.PowerShell.ThreadJob as
# of 7.6, ThreadJob before), and it must not be declared as a RequiredModule
# because the bundled copy collides with a per-user install. pp2 pulls it in on
# first use and falls back to serial start/stop if it is unavailable.
$script:Pp2Root = if ($env:PP2_HOME) { $env:PP2_HOME } else { Join-Path $HOME '.pp2' }

# Import private (internal) functions
. (Join-Path $PSScriptRoot 'Private\pp2-core.ps1')

# Import public (exported) functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | ForEach-Object {
    . $_.FullName
}

Export-ModuleMember -Function @(
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
