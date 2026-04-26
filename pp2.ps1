param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'start', 'stop', 'restart', 'logs', 'monit', 'list', 'watchdog-start', 'watchdog-stop', 'watchdog-status', 'startup-install', 'startup-uninstall', 'internal-start', 'help')]
  [string]$Action = 'status',

  [Parameter(Position = 1)]
  [string]$Name = 'all',

  [int]$Tail = 80,

  [ValidateSet('table', 'json')]
  [string]$Format = 'table',

  [int]$Interval = 5,

  [int]$Cols = 3,

  [switch]$Force,

  [switch]$Watch
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
. (Join-Path $Root 'lib\pp2-core.ps1')
Initialize-Pw2Context -ScriptRoot $Root

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
  logs <name> [-Tail 120]    View service logs
  logs <name> -Watch         Live log monitoring (Ctrl+C to exit)

Utility Actions:
  monit [name]               Live logs in Windows Terminal split panes
  list                       List service names

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
  -Force                     Skip confirmation prompts for cleanup

Config Fields (services.json):
  settings.watchdogInterval: 60    Watchdog check interval (seconds)
  settings.portCheckTimeout: 200   Port check timeout (milliseconds)
  settings.startupVerifyWait: 2500 Startup verification wait (milliseconds)
  settings.shutdownTimeout: 5000   Shutdown process exit timeout (milliseconds)
  
  autoRestart: true          Auto-restart on crash
  maxRetries: 3              Max restart attempts
  dependsOn: ["pp2"]         Dependencies (must start first)
  elevated: true             Requires admin privileges to run
  ports: [8080]              Ports to verify startup (optional)
  ephemeral: true            Launcher pattern - process exits after starting others
  shutdownCommand: "cmd"     Custom shutdown command (required for ephemeral)
  shutdownArguments: ["-x"]  Arguments for shutdownCommand (optional)

Examples:
  pp2 status
  pp2 status -Watch
  pp2 start cloudflared
  pp2 stop all
  pp2 logs cloudflared
  pp2 logs cloudflared -Watch
'@ | Write-Host
  }
  'list' { Get-ServiceNames $Name }
  'status' {
    if ($Watch) { Watch-Status $Name $Format $Interval }
    else { Show-Status $Name $Format }
  }
  'start' {
    Start-WatchdogIfNeeded $Name
    foreach ($ServiceName in Get-ServiceNames $Name) { Start-One $ServiceName $Force.IsPresent | Out-Null }
  }
  'stop' { Stop-Many (Get-ServiceNames $Name) }
  'restart' {
    $ServicesToRestart = Get-ServiceNames $Name
    Stop-Many $ServicesToRestart
    Start-Sleep -Seconds 1
    Start-WatchdogIfNeeded $Name
    foreach ($ServiceName in $ServicesToRestart) { Start-One $ServiceName $Force.IsPresent | Out-Null }
  }
  'logs' {
    if ($Name -eq 'all') { throw 'logs requires a service name' }
    Get-ServiceNames $Name | Out-Null
    Show-Logs $Name $Tail $Watch.IsPresent
  }
  'monit' { Show-Monit $Name $Cols }
  'watchdog-start' { Start-WatchdogProcess }
  'watchdog-stop' { Stop-Watchdog }
  'watchdog-status' { Show-WatchdogStatus }
  'internal-start' {
    # Internal action for watchdog auto-restart (no watchdog restart, no retry reset)
    # NoRetryReset is always true for internal-start (watchdog manages retry counter)
    foreach ($ServiceName in Get-ServiceNames $Name) { Start-One $ServiceName $Force.IsPresent -NoRetryReset:$true | Out-Null }
  }
  'startup-install' { Install-StartupTask $PSCommandPath }
  'startup-uninstall' { Uninstall-StartupTask }
}
