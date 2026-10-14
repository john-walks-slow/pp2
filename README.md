# pp<super>2</super> - PowerShell Process Manager

> Inspired by [pm2](https://pm2.keymetrics.io/) — the Node.js process manager.

[English](README.md) | [中文](README_CN.md)

PowerShell-based service manager for managing background processes with dependency handling, auto-restart, and monitoring.

**pp2 = PowerShell × pm2**

> **Status:** stable, 48/48 tests passing, public on GitHub. **Not yet on
> the PowerShell Gallery** — install from a clone for now (see below).
> Track publication: [github.com/john-walks-slow/pp2/releases](https://github.com/john-walks-slow/pp2/releases).

## Installation

### Prerequisites

- **PowerShell 7+**: Required (`winget install Microsoft.PowerShell`)
- **Windows Terminal**: Optional
- **sudo for Windows**: Optional for `elevated` option (`winget install gerardog.gsudo`)

### Local clone (currently the only way to get it)

The module is not yet published to the PowerShell Gallery. Until it is,
install it from a clone of the public GitHub repository
([john-walks-slow/pp2](https://github.com/john-walks-slow/pp2)):

```pwsh
git clone https://github.com/john-walks-slow/pp2.git
cd pp2
.\install.ps1
```

`install.ps1` copies `src/pp2/` into the first writable directory in
`$env:PSModulePath`, so `Import-Module pp2` works afterwards. The
`pp2` command is then available in any PowerShell 7+ session.

| Action                 | Command                                          |
| ---------------------- | ------------------------------------------------ |
| Reinstall              | `.\install.ps1 -Force`                           |
| Uninstall              | `.\install.ps1 -Uninstall`                       |
| Run without installing | `./pp2.ps1 <action> [name]` (uses the source tree directly) |

### PowerShell Gallery (planned)

Once a release is published to PSGallery:

```pwsh
Install-Module -Name pp2 -Repository PSGallery
Import-Module pp2
```

Until then `Install-Module -Name pp2` will fail with "Package 'pp2' was
not found in the PowerShell Gallery". Track publication status at
[github.com/john-walks-slow/pp2/releases](https://github.com/john-walks-slow/pp2/releases).

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

# Multi-pane log monitoring dashboard
pp2 monit

# Auto-start on boot
pp2 startup-install
```

## Configuration Example

Define services in `services.json` under the pp2 config directory.

| Location                | Resolved as                                    |
| ----------------------- | ---------------------------------------------- |
| `$PP2_HOME` (env var)   | used verbatim if set                            |
| Default (no env var)    | `$HOME/.pp2` on Windows, Linux, and macOS       |

Every `pp2` invocation re-reads `PP2_HOME`, so changing it between commands
takes effect without re-importing the module. `-Config <path>` overrides
`services.json` for a single command.

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
| `enable`            | boolean | no          | Enable/disable service (disabled services are invisible) |
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

| Mode           | `shell` | Execution Method          | Best For                              |
| -------------- | ------- | ------------------------- | ------------------------------------- |
| **Direct**     | `false` | `& $command @arguments`   | Native executables; precise args      |
| **Shell**      | `true`  | `pwsh -Command $fullLine` | CLI tools; shell features needed      |

**Direct mode (`shell: false`)** - Default:

- Each argument is passed as a separate token; boundaries are preserved
- No shell features (no pipes, redirects, wildcards, PATH lookup)
- Recommended for direct executables and Node.js scripts

**Shell mode (`shell: true`)**:

- The command and its arguments are joined into a single string
- Executed via `pwsh -NoProfile -NonInteractive -Command ...`
- Recommended for CLI tools and package runners (`npx`, `uvx`, `pipx`, `dotnet tool`)
- The command is logged to `<service>.out.log` before execution so the actual invocation is auditable

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

| Field                | Type   | Default | Description                                                          |
| -------------------- | ------ | ------- | -------------------------------------------------------------------- |
| `watchdogInterval`   | number | 60      | Watchdog check interval (seconds)                                    |
| `portCheckTimeout`   | number | 200     | Port check timeout (milliseconds)                                    |
| `startupVerifyWait`  | number | 20000   | How long to wait for a service to start before reporting a failure (ms) |
| `startupSettleWait`  | number | 3000    | After the launch script's banner, wait this long for a crash (ms)   |
| `shutdownTimeout`    | number | 5000    | Shutdown exit timeout (milliseconds)                                 |
| `shutdownWaitDelay`  | number | 2000    | Wait after shutdown command (ms)                                     |
| `healthCheckGrace`   | number | 30      | Seconds a service must be up before its retry counter is cleared    |
| `restartTimeout`     | number | 120     | Max seconds the watchdog waits for its own restart subprocess        |

## Commands Reference

### Core Actions

```pwsh
pp2 status [name]              # Show status table (-Format json for JSON)
pp2 status -Watch              # Live status dashboard (-Interval 5)
pp2 start [name]               # Start service (autoRestart=true starts watchdog)
pp2 stop [name]                # Stop service
pp2 restart [name]             # Restart service
pp2 logs <name> [-Tail 80]     # Live log monitoring (default, Ctrl+C to exit)
pp2 logs <name> -Watch:$false  # Static log view
```

### Utility Commands

```pwsh
pp2 monit [name] [-Cols 3]     # Multi-pane log dashboard (Ctrl+C to exit)
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

**Service starts then disappears from `pp2 status`:**

- A bad `command`, missing binary, or bad arguments cause the launch script
  to exit before reaching the user's program. The check is the "exited
  immediately" warning in stdout; the service then has no PID file.
- Increase `startupVerifyWait` and `startupSettleWait` if a healthy service
  fails the startup check on a slow machine (cold start of `pwsh` can take
  10-15s on Windows).

**Service won't auto-restart:**

- Run `pp2 watchdog-status` to check status
- Start manually: `pp2 watchdog-start`
- After `maxRetries` the watchdog gives up and leaves the service stopped.
  Fix the underlying crash, then run `pp2 start <name>` again.

**`pp2` is not found after install:**

- `Install-Module pp2 -Scope CurrentUser` requires PowerShell 7+ and
  PowerShellGet 2.x. Check `$PSVersionTable.PSVersion` and run
  `Install-Module -Name PowerShellGet -Force` if needed.
- If you installed with `-Scope AllUsers`, restart the shell so the new
  `PSModulePath` is picked up.

**`PP2_HOME` is ignored between commands:**

- This is fixed in the current source: every command re-reads
  `PP2_HOME`. If you still see the previous home, check that you are not
  running an older copy of the module
  (`Get-Module pp2 | Select-Object Version,Path`).

## Releases

Version history lives in [CHANGELOG.md](CHANGELOG.md). Tagged GitHub
releases are at [github.com/john-walks-slow/pp2/releases](https://github.com/john-walks-slow/pp2/releases);
each release is built and tested by
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).

A future `v1.0.0` tag will also publish the module to the PowerShell
Gallery via [`.github/workflows/publish.yml`](.github/workflows/publish.yml).
Until that happens `Install-Module -Name pp2` returns "Package not found" — use the local-clone install path above.