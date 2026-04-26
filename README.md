# pp<super>2</super> - PowerShell Process Manager

> Inspired by [pm2](https://pm2.keymetrics.io/) — the Node.js process manager.

PowerShell-based service manager for managing background processes with dependency handling, auto-restart, and monitoring.

**pp2 = PowerShell × pm2**

## Features

- **No Bullshit**: If it can be started via command line, it can be managed by pp2. No weird compatibility issues. Supports environment variable injection and working directory configuration
- **Auto-Restart**: Watchdog monitoring, automatically restarts crashed services
- **Log Viewing**: Centralized log management, supports Windows Terminal split-pane monitoring
- **Port Checking**: Check port health, handle port conflicts
- **Windows Startup Integration**: Set services to auto-start on user login
- **Privilege Elevation**: Supports Sudo for Windows to elevate service privileges

## Quick Start

```pwsh
# Show service status
pp2 status

# Start all services
pp2 start all

# Stop all services
pp2 stop all

# Multi-pane log monitoring (requires Windows Terminal)
pp2 monit

# Auto-start on boot
pp2 startup-install
```

## Configuration

Create `services.json` in the same directory:

```json
{
  "services": {
    "my-service": {
      "displayName": "My Service",
      "description": "Description shown in status",
      "workingDirectory": "C:/path/to/workdir",
      "command": "C:/path/to/executable.exe",
      "arguments": ["--port", "8080"],
      "ports": [8080],
      "autoRestart": true,
      "maxRetries": 3,
      "dependsOn": ["another-service"],
      "elevated": false,
      "env": {
        "ENV_VAR": "value"
      },
      "shell": false,
      "shutdownCommand": "C:/path/to/shutdown.exe",
      "shutdownArguments": ["--stop"]
    }
  }
}
```

### Configuration Fields

| Field               | Type    | Required | Description                                                 |
| ------------------- | ------- | -------- | ----------------------------------------------------------- |
| `displayName`       | string  | no       | Display name                                                |
| `description`       | string  | no       | Service description                                         |
| `workingDirectory`  | string  | no       | Process working directory                                   |
| `command`           | string  | **yes**  | Executable path or command                                  |
| `arguments`         | array   | no       | Command arguments                                           |
| `ports`             | array   | no       | Service ports (for port health check, empty array disables) |
| `ephemeral`         | boolean | no       | Launcher pattern - process exits after starting (default: false) |
| `autoRestart`       | boolean | no       | Auto-restart on crash (default: false, ignored for ephemeral) |
| `maxRetries`        | number  | no       | Max restart attempts (default: 3)                           |
| `dependsOn`         | array   | no       | Dependent services (affects startup order)                  |
| `elevated`          | boolean | no       | Elevate via sudo                                            |
| `env`               | object  | no       | Environment variables to inject                             |
| `inheritEnv`        | boolean | no       | Inherit system environment variables (default: true)        |
| `shell`             | boolean | no       | Run via pwsh (default: true)                                |
| `shutdownCommand`   | string  | conditional | Custom shutdown command (**required** for ephemeral)     |
| `shutdownArguments` | array   | no       | Arguments for shutdownCommand                               |
| `legacyProcessName` | string  | no       | Additional process name to clean up legacy processes        |

### Ephemeral Services (Launcher Pattern)

Some services are **launcher scripts** that start other processes and then exit immediately. For example:
- A wrapper script that launches a background daemon (`nohup my-daemon &`)
- A CLI tool that starts a service and exits (like `cloudflared tunnel run` in certain modes)
- A process manager script that spawns child processes

For these cases, use `ephemeral: true`:

```json
{
  "services": {
    "my-launcher": {
      "displayName": "My Launcher",
      "command": "pwsh",
      "arguments": ["-File", "launch-background.ps1"],
      "ephemeral": true,
      "shutdownCommand": "pwsh",
      "shutdownArguments": ["-File", "stop-background.ps1"]
    }
  }
}
```

**Behavior:**
- PID file contains `'ephemeral'` marker instead of real PID
- Watchdog **skips process monitoring** (no auto-restart)
- `pp2 stop` calls `shutdownCommand` to clean up spawned processes
- Status shows `Running (ephemeral)` with PID = `-`

**Requirements:**
- `shutdownCommand` is **mandatory** for ephemeral services
- `autoRestart` is automatically disabled (cannot monitor ephemeral processes)

## Commands Reference

### Core Actions

```pwsh
pp2 status [name]              # Show status table (-Format json for JSON output)
pp2 status -Watch              # Live status dashboard (-Interval 5)
pp2 start [name]               # Start service (autoRestart=true also starts watchdog)
pp2 stop [name]                # Stop service
pp2 restart [name]             # Restart service
pp2 logs <name> [-Tail 80]     # View logs
pp2 logs <name> -Watch         # Live log monitoring
```

### Utility Commands

```pwsh
pp2 monit [name] [-Cols 3]     # Windows Terminal multi-pane logs
pp2 list                       # List service names
```

### Watchdog Control

```pwsh
pp2 watchdog-start             # Start auto-restart monitor
pp2 watchdog-stop              # Stop auto-restart monitor
pp2 watchdog-status            # Check watchdog status
```

### Startup Integration

```pwsh
pp2 startup-install            # Add to Windows startup (Task Scheduler)
pp2 startup-uninstall          # Remove from Windows startup
```

### Options

```pwsh
-Format json|table             # status output format
-Interval 5                    # watch refresh interval (seconds)
-Tail 80                       # Log lines to display
-Cols 3                        # monit max columns
-Force                         # Skip confirmation prompts
```

## Dependency Handling

Services with `dependsOn` start in correct order. Stop operations use reverse dependency order:

```json
{
  "database": { ... },
  "api": {
    "dependsOn": ["database"]
  },
  "web": {
    "dependsOn": ["api"]
  }
}
```

- **Start order**: database → api → web
- **Stop order**: web → api → database

## Log Management

Logs stored in `logs/` directory:

- `logs/<service>.out.log` - Standard output
- `logs/<service>.err.log` - Standard error

PID tracking in `run/` directory:

- `run/<service>.pid` - Process ID
- `run/<service>.elevated` - Elevated service marker
- `run/watchdog.pid` - Watchdog process ID

## Configuration Examples

### Node.js Service (npx)

```json
{
  "my-app": {
    "command": "npx",
    "arguments": ["my-package", "--port", "3000"],
    "ports": [3000],
    "shell": true,
    "autoRestart": true
  }
}
```

### Elevated Service

```json
{
  "privileged-service": {
    "command": "C:/path/to/service.exe",
    "elevated": true,
    "autoRestart": true
  }
}
```

### Custom Shutdown Command

```json
{
  "graceful-service": {
    "command": "C:/path/to/server.exe",
    "shutdownCommand": "C:/path/to/server.exe",
    "shutdownArguments": ["--shutdown"]
  }
}
```

## Troubleshooting

**Service won't start:**

- Check `logs/<service>.err.log`
- Verify port is not occupied: `netstat -ano | findstr :<port>`

**Service won't auto-restart:**

- Run `pp2 watchdog-status` to check status
- Start manually: `pp2 watchdog-start`

**Elevated service fails:**

- Ensure sudo is installed
