# Fall back to the legacy ThreadJob module name on PowerShell 7.4 and
# earlier, which still ship it under that name. PowerShell 7.6 renamed it
# to Microsoft.PowerShell.ThreadJob and now warns about the old one.
if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.ThreadJob) -and
    (Get-Module -ListAvailable -Name ThreadJob)) {
    Import-Module -Name ThreadJob -ErrorAction Stop
}

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
