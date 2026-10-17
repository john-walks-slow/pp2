function pp2 {
    param(
        [Parameter(Position = 0)]
        [ValidateSet('status', 'start', 'stop', 'restart', 'logs', 'monit', 'list', 'config',
                     'add', 'remove', 'set', 'show',
                     'internal-start', 'watchdog-start', 'watchdog-stop', 'watchdog-status',
                     'startup-install', 'startup-uninstall', 'help')]
        [string]$Action = 'status',

        [Parameter(Position = 1)]
        [string[]]$Name = @('all'),

        # add takes a field mapping (-Field @{command='npx'}), set takes a field
        # name and a value (pp2 set web maxRetries 5). One parameter serves both
        # spellings, so it is typed loosely and each branch narrows it.
        [Parameter(Position = 2)]
        [object]$Field,

        [Parameter(Position = 3)]
        [AllowNull()]
        [string]$Value,

        [int]$Tail = 80,
        [ValidateSet('table', 'json')]
        [string]$Format = 'table',
        [int]$Interval = 5,
        [int]$Cols = 3,
        [switch]$Force,
        [switch]$Watch,
        [switch]$Restart,
        [switch]$Purge,
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

    # Every config-editing action takes service names; the rest of the CLI
    # defaults $Name to 'all'. Check before dispatch so the message is the same
    # wherever it is hit, and treat 'all' as absent -- it is what the default
    # supplies, and an explicit `pp2 add all` is just as wrong.
    #
    # A positional [string[]] binds at most one argument, so `pp2 remove a b`
    # cannot mean two services: 'b' lands in $Field. Rather than act on half the
    # request, each action declares what it accepts and a stray argument is
    # rejected. remove takes a comma-separated list.
    if ($Action -in @('add', 'remove', 'set', 'show')) {
        $Names = @($Name | Where-Object { $_ -ne 'all' })
        if ($Names.Count -eq 0) { throw "$Action requires a service name" }

        if ($Action -eq 'remove') {
            if ($PSBoundParameters.ContainsKey('Field')) {
                throw 'remove takes a comma-separated list, e.g. pp2 remove a,b'
            }
        }
        elseif ($Names.Count -ne 1) {
            throw "$Action requires exactly one service name"
        }

        switch ($Action) {
            'add' {
                if ($Field -isnot [hashtable]) {
                    throw "add requires a -Field mapping, e.g. pp2 add web -Field @{command='npx'}"
                }
                if ($PSBoundParameters.ContainsKey('Value')) { throw 'add does not take a value argument' }
            }
            'set' {
                if ($Field -isnot [string]) { throw "set requires a field and a value, e.g. pp2 set web maxRetries 5" }
                if (-not $PSBoundParameters.ContainsKey('Value')) { throw "set requires a value, e.g. pp2 set web $Field <value>" }
            }
            'show' {
                if ($PSBoundParameters.ContainsKey('Field') -or $PSBoundParameters.ContainsKey('Value')) { throw 'show does not take extra arguments' }
            }
        }
    }

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

Service Config:
  show <name>                Show one service definition (-Format json)
  add <name> -Field @{...}   Add a service (or replace one with -Force)
  set <name> <field> <value> Change a single field
  remove <name>[,<name>]       Remove services from the config
                             (-Purge also deletes state and logs)

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
  -Restart                   Restart the services an edit touched
  -Purge                     (remove) also delete state files and logs
  -Config <path>             Use specified services.json file

Examples:
  pp2 status
  pp2 status -Watch
  pp2 start cloudflared
  pp2 stop all
  pp2 logs cloudflared
  pp2 add web -Field @{command='npx'; arguments=@('-y','http-server'); ports=@(8080)}
  pp2 set web autoRestart true -Restart
  pp2 remove web -Purge
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
        'show' {
            $Service = Get-ServiceConfig $Name[0]
            if ($Format -eq 'json') { $Service | ConvertTo-Json -Depth 32 }
            else { Show-ServiceConfig $Name[0] $Service }
        }
        'add' {
            Assert-ServiceName $Name[0]
            Add-ServiceConfig $Name[0] $Field $Force.IsPresent $Restart.IsPresent
        }
        'set' {
            Set-ServiceConfigField $Name[0] $Field $Value $Force.IsPresent $Restart.IsPresent
        }
        'remove' {
            Remove-ServiceConfig $Name -Purge:$Purge -Force:$Force.IsPresent -Restart:$Restart.IsPresent
        }
        'watchdog-start' { Start-WatchdogProcess }
        'watchdog-stop' { Stop-Watchdog }
        'watchdog-status' { Show-WatchdogStatus }
        'startup-install' { Install-StartupTask (Join-Path $script:ModuleRoot 'pp2.psd1') (Get-Pp2Root) $script:ConfigPath }
        'startup-uninstall' { Uninstall-StartupTask }
    }
}
