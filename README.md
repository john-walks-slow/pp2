# pp<super>2</super> - PowerShell Process Manager

> Inspired by [pm2](https://pm2.keymetrics.io/) — the Node.js process manager.

[English](README.md) | [中文](README_CN.md)

PowerShell-based service manager for managing background processes with dependency handling, auto-restart, and monitoring.

**pp2 = PowerShell × pm2**

## Installation

### Prerequisites

- **PowerShell 7+**: Required (`winget install Microsoft.PowerShell`)
- **Windows Terminal**: Optional for `monit` (`winget install Microsoft.WindowsTerminal`)
- **sudo for Windows**: Optional for `elevated` option (`winget install gerardog.gsudo`)

### Local Installation

```pwsh
git clone https://github.com/john-walks-slow/pp2.git
cd pp2
.\install.ps1
```

The `pp2` command is available after installation.

To reinstall: `.\install.ps1 -Force`

To uninstall: `.\install.ps1 -Uninstall`

## Quick Start

```pwsh
# Show service status
pp2 status

# Start all services
pp2 start all

# Stop service
pp2 stop my-service

# View logs
pp2 logs my-service

# Multi-pane log monitoring (requires Windows Terminal)
pp2 monit

# Auto-start on boot
pp2 startup-install
```

## Configuration Example

Define services in `services.json` under the pp2 config directory. (Default: `$HOME/.pp2`, override with `PP2_HOME`)

```json
{
  "services": {
    "http-server": {
      "displayName": "Simple Http Server",
      "description": "a simple http server",
      "workingDirectory": "D:/path/to/website",
      "command": "npx",
      "arguments": ["-y", "http-server"],
      "shell": true,
      "env": {
        "PORT": 1234
      },
      "ports": [1234],
      "autoRestart": true,
      "maxRetries": 3
    }
  }
}
```

### Configuration Fields

| Field               | Type    | Required    | Description                                            |
| ------------------- | ------- | ----------- | ------------------------------------------------------ |
| `displayName`       | string  | no          | Display name                                           |
| `description`       | string  | no          | Service description                                    |
| `workingDirectory`  | string  | no          | Process working directory                              |
| `command`           | string  | **yes**     | Executable path or command                             |
| `arguments`         | array   | no          | Command arguments                                      |
| `shell`             | boolean | no          | ⚠ **Run mode - critical, see below** (default: false) |
| `ports`             | array   | no          | Service ports (for port health check, empty disables) |
| `ephemeral`         | boolean | no          | Launcher pattern - exits after starting (default: false) |
| `autoRestart`       | boolean | no          | Auto-restart on crash (default: false, ignored for ephemeral) |
| `maxRetries`        | number  | no          | Max restart attempts (default: 3)                     |
| `dependsOn`         | array   | no          | Dependent services (affects startup order)            |
| `elevated`          | boolean | no          | Elevate via sudo                                       |
| `env`               | object  | no          | Environment variables to inject                        |
| `inheritEnv`        | boolean | no          | Inherit system env vars (default: true)               |
| `shutdownCommand`   | string  | conditional | Custom shutdown command (**required** for ephemeral)  |
| `shutdownArguments` | array   | no          | Arguments for shutdownCommand                          |
| `legacyProcessName` | string  | no          | Additional process name for legacy cleanup            |

### Shell Mode vs Direct Execution

The `shell` option controls command execution:

| Mode           | `shell` | Execution Method    | Best For                              |
| -------------- | ------- | ------------------- | ------------------------------------- |
| **Direct**     | `false` | `& $command $args`  | Native executables; precise args      |
| **Shell**      | `true`  | `Invoke-Expression` | CLI tools; shell features needed      |

**Direct mode (`shell: false`)** - Default:

- Each argument passed as separate token, boundaries preserved
- No shell features (no pipes, redirects, wildcards, PATH)
- Recommended for direct executables

**Shell mode (`shell: true`)**:

- Command concatenated as string, executed via pwsh
- Arguments properly quoted and escaped
- Recommended for CLI tools and package runners (`npx`, `uvx`, `pipx`)

### Ephemeral Services (Launcher Pattern)

Some services are **launcher scripts** that start other processes then exit immediately. For example:

- Wrapper scripts that launch background daemons (`nohup my-daemon &`)
- CLI tools that start services and exit
- Process manager scripts that spawn child processes

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

**Notes:**

- `shutdownCommand` is **required** for ephemeral services
- `autoRestart` doesn't apply to ephemeral services
- PID file contains `'ephemeral'` marker instead of real PID

### Global Settings

Configure in `services.json` under `settings`:

```json
{
  "settings": {
    "watchdogInterval": 60,
    "portCheckTimeout": 200,
    "startupVerifyWait": 2500,
    "shutdownTimeout": 5000
  }
}
```

| Field               | Type   | Default | Description                        |
| ------------------- | ------ | ------- | ---------------------------------- |
| `watchdogInterval`  | number | 60      | Watchdog check interval (seconds)  |
| `portCheckTimeout`  | number | 200     | Port check timeout (milliseconds)  |
| `startupVerifyWait` | number | 2500    | Startup verification wait (ms)     |
| `shutdownTimeout`   | number | 5000    | Shutdown exit timeout (milliseconds) |

## Commands Reference

### Core Actions

```pwsh
pp2 status [name]              # Show status table (-Format json for JSON)
pp2 status -Watch              # Live status dashboard (-Interval 5)
pp2 start [name]               # Start service (autoRestart=true starts watchdog)
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
-Config <path>                 # Use specified services.json file
```

## Log Management

Logs stored in `logs/` subdirectory under config directory:

- `logs/<service>.out.log` - Standard output
- `logs/<service>.err.log` - Standard error

PID tracking in `run/` subdirectory under config directory:

- `run/<service>.pid` - Process ID
- `run/<service>.elevated` - Elevated service marker
- `run/watchdog.pid` - Watchdog process ID

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

## Troubleshooting

**Service won't start:**

- Check `logs/<service>.err.log`
- Verify port not occupied: `netstat -ano | findstr :<port>`

**Service won't auto-restart:**

- Run `pp2 watchdog-status` to check status
- Start manually: `pp2 watchdog-start`