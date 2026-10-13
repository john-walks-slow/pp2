function pp2 {
    param(
        [Parameter(Position = 0)]
        [ValidateSet('status', 'start', 'stop', 'restart', 'logs', 'monit', 'list', 'config',
                     'internal-start', 'watchdog-start', 'watchdog-stop', 'watchdog-status',
                     'startup-install', 'startup-uninstall', 'help')]
        [string]$Action = 'status',

        [Parameter(Position = 1)]
        [string[]]$Name = @('all'),

        [int]$Tail = 80,
        [ValidateSet('table', 'json')]
        [string]$Format = 'table',
        [int]$Interval = 5,
        [int]$Cols = 3,
        [switch]$Force,
        [switch]$Watch,
        [string]$Config
    )

    $ErrorActionPreference = 'Stop'

    # Resolve the state root per invocation so PP2_HOME changes take effect
    # without re-importing the module.
    Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)

    if ($Config) {
        if (-not (Test-Path $Config)) { throw "Config file not found: $Config" }
        $script:ConfigPath = (Resolve-Path $Config).Path
    }
    Read-Pp2Config

    switch ($Action) {
        'help' {
            @'
Usage: pp2 <action> [name] [options]

Core Actions:
  status [name]              Show status table (-Format json for JSON output)
  status [name] -Watch       Live status dashboard (Ctrl+C to exit)
  start [name]               Start services + watchdog if autoRestart enabled
  stop [name]                Stop services (respecting dependencies)
  restart [name]             Restart services + watchdog if needed
  logs <name> [-Tail 80]     View service logs
  logs <name> -Watch         Live log monitoring (Ctrl+C to exit)

Utility Actions:
  monit [name]               Live logs in Windows Terminal split panes
  list                       List service names
  config                     Open services.json in default editor

Watchdog Control:
  watchdog-start             Start auto-restart monitor
  watchdog-stop              Stop auto-restart monitor
  watchdog-status            Check watchdog status

Startup Control:
  startup-install            Add to Windows startup
  startup-uninstall          Remove from Windows startup

Options:
  -Watch                     Live monitoring mode (for status/logs)
  -Format json|table         Output format
  -Interval 5                Refresh interval for status -Watch
  -Tail 80                   Log lines to show
  -Cols 3                    Max columns for monit layout
  -Force                     Skip confirmation prompts
  -Config <path>             Use specified services.json file

Examples:
  pp2 status
  pp2 status -Watch
  pp2 start cloudflared
  pp2 stop all
  pp2 logs cloudflared
'@ | Write-Host
        }
        'list' { Get-ServiceNames $Name }
        'status' {
            if ($Watch) { Watch-Status $Name $Format $Interval }
            else { Show-Status $Name $Format }
        }
        'start' {
            Start-WatchdogIfNeeded $Name
            Start-Many (Get-ServiceNames $Name) $Force.IsPresent
        }
        'internal-start' {
            # Watchdog-driven restart: preserve the crash-retry counter so that
            # maxRetries is actually reachable.
            Start-Many (Get-ServiceNames $Name) $true $true
        }
        'stop' { Stop-Many (Get-ServiceNames $Name) }
        'restart' {
            $ServicesToRestart = Get-ServiceNames $Name
            Stop-Many $ServicesToRestart
            Start-Sleep -Seconds 1
            Start-WatchdogIfNeeded $Name
            Start-Many $ServicesToRestart $Force.IsPresent
        }
        'logs' {
            if ($Name -eq 'all') { throw 'logs requires a service name' }
            Get-ServiceNames $Name | Out-Null
            Show-Logs $Name $Tail $Watch.IsPresent
        }
        'monit' { Show-Monit $Name $Cols -Interactive:(-not $PSBoundParameters.ContainsKey('Name')) }
        'config' { Open-ConfigFile }
        'watchdog-start' { Start-WatchdogProcess }
        'watchdog-stop' { Stop-Watchdog }
        'watchdog-status' { Show-WatchdogStatus }
        'startup-install' { Install-StartupTask (Join-Path $script:ModuleRoot 'pp2.psd1') (Get-Pp2Root) $script:ConfigPath }
        'startup-uninstall' { Uninstall-StartupTask }
    }
}
