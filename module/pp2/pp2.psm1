<#
.SYNOPSIS
    pp2 - PowerShell Process Manager

.DESCRIPTION
    PowerShell-based service manager for managing background processes with dependency handling, 
    auto-restart, and monitoring. Inspired by pm2.

    Use `pp2 help` to see all available commands.

.EXAMPLE
    pp2 status
    Show status of all services.

.EXAMPLE
    pp2 start cloudflared
    Start a specific service.

.EXAMPLE
    Install-Module pp2
    Install from PowerShell Gallery.

.LINK
    https://github.com/your-username/services
#>

$script:Pp2Root = Split-Path -Parent $PSScriptRoot
$script:ConfigPath = Join-Path $script:Pp2Root 'services.json'

# Import helper functions
. (Join-Path $PSScriptRoot 'lib\pp2-core.ps1')

function pp2 {
    <#
    .SYNOPSIS
        Main pp2 CLI entry point
    
    .DESCRIPTION
        Manage background services with status, start, stop, restart, logs, and watchdog commands.
    
    .EXAMPLE
        pp2 status
        pp2 start cloudflared
        pp2 stop all
    #>
    param(
        [Parameter(Position = 0)]
        [ValidateSet('status', 'start', 'stop', 'restart', 'logs', 'monit', 'list', 
                     'watchdog-start', 'watchdog-stop', 'watchdog-status',
                     'startup-install', 'startup-uninstall', 'help')]
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
    
    # Initialize context with module directory as root
    Initialize-Pw2Context -ScriptRoot $script:Pp2Root
    
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
  -Force                     Skip confirmation prompts

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
            foreach ($ServiceName in Get-ServiceNames $Name) { 
                Start-One $ServiceName $Force.IsPresent | Out-Null 
            }
        }
        'stop' { Stop-Many (Get-ServiceNames $Name) }
        'restart' {
            $ServicesToRestart = Get-ServiceNames $Name
            Stop-Many $ServicesToRestart
            Start-Sleep -Seconds 1
            Start-WatchdogIfNeeded $Name
            foreach ($ServiceName in $ServicesToRestart) { 
                Start-One $ServiceName $Force.IsPresent | Out-Null 
            }
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
        'startup-install' { Install-StartupTask (Join-Path $script:Pp2Root 'pp2.ps1') }
        'startup-uninstall' { Uninstall-StartupTask }
    }
}

function Start-Pp2Service {
    <#
    .SYNOPSIS
        Start pp2 services
    
    .DESCRIPTION
        Start one or more services. Dependencies are handled automatically.
    
    .PARAMETER Name
        Service name or 'all'
    
    .PARAMETER Force
        Skip confirmation prompts
    
    .EXAMPLE
        Start-Pp2Service -Name 'cloudflared'
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [switch]$Force
    )
    pp2 start $Name -Force:$Force
}

function Stop-Pp2Service {
    <#
    .SYNOPSIS
        Stop pp2 services
    
    .DESCRIPTION
        Stop one or more services. Dependencies are handled in reverse order.
    
    .PARAMETER Name
        Service name or 'all'
    
    .EXAMPLE
        Stop-Pp2Service -Name 'cloudflared'
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    pp2 stop $Name
}

function Restart-Pp2Service {
    <#
    .SYNOPSIS
        Restart pp2 services
    
    .EXAMPLE
        Restart-Pp2Service -Name 'cloudflared'
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    pp2 restart $Name
}

function Get-Pp2Status {
    <#
    .SYNOPSIS
        Get pp2 service status
    
    .PARAMETER Name
        Service name or 'all'
    
    .PARAMETER Format
        Output format: 'table' or 'json'
    
    .EXAMPLE
        Get-Pp2Status
        Get-Pp2Status -Name 'cloudflared' -Format json
    #>
    param(
        [string]$Name = 'all',
        [ValidateSet('table', 'json')]
        [string]$Format = 'table'
    )
    pp2 status $Name -Format $Format
}

function Get-Pp2Logs {
    <#
    .SYNOPSIS
        View pp2 service logs
    
    .PARAMETER Name
        Service name (required)
    
    .PARAMETER Tail
        Number of lines to show
    
    .EXAMPLE
        Get-Pp2Logs -Name 'cloudflared' -Tail 50
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [int]$Tail = 80
    )
    pp2 logs $Name -Tail $Tail
}

function Watch-Pp2Logs {
    <#
    .SYNOPSIS
        Watch pp2 service logs in real-time
    
    .EXAMPLE
        Watch-Pp2Logs -Name 'cloudflared'
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    pp2 logs $Name -Watch
}

function Start-Pp2Watchdog {
    <#
    .SYNOPSIS
        Start the watchdog auto-restart monitor
    
    .EXAMPLE
        Start-Pp2Watchdog
    #>
    pp2 watchdog-start
}

function Stop-Pp2Watchdog {
    <#
    .SYNOPSIS
        Stop the watchdog auto-restart monitor
    
    .EXAMPLE
        Stop-Pp2Watchdog
    #>
    pp2 watchdog-stop
}

function Get-Pp2WatchdogStatus {
    <#
    .SYNOPSIS
        Check watchdog status
    
    .EXAMPLE
        Get-Pp2WatchdogStatus
    #>
    pp2 watchdog-status
}

function Install-Pp2Startup {
    <#
    .SYNOPSIS
        Add pp2 to Windows startup
    
    .DESCRIPTION
        Creates a scheduled task to start pp2 on user login
    
    .EXAMPLE
        Install-Pp2Startup
    #>
    pp2 startup-install
}

function Uninstall-Pp2Startup {
    <#
    .SYNOPSIS
        Remove pp2 from Windows startup
    
    .EXAMPLE
        Uninstall-Pp2Startup
    #>
    pp2 startup-uninstall
}

# Export functions
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