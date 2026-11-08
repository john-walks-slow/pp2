---
name: pp2
description: Drive pp2, the PowerShell process manager on Windows — start/stop/restart background processes, read logs, edit services.json, enable auto-restart, and register services to start at logon. Use when asked to run something in the background or as a service, manage local daemons, check what is running on a port, or make a service start on boot.
---

# pp2

pp2 is a pm2-style service manager for Windows: services are declared in
`services.json` and managed by one CLI. It runs on PowerShell 7+.

```pwsh
Import-Module pp2          # once per session
pp2 status
```

If `Import-Module pp2` fails, install it:
`Install-Module pp2 -Repository PSGallery -Scope CurrentUser` (or `Install-PSResource pp2`).

## Rules for an agent

- **Never run the interactive commands.** `status -Watch`, `logs -Watch`, and
  `monit` block until Ctrl+C. Use `pp2 status` and `pp2 logs <name> -Tail N`.
- **Parse with `-Format json`.** `pp2 status -Format json` and
  `pp2 show <name> -Format json` return structured data.
- **Verify with status, not with the start output.** `pp2 start` launches a
  hidden process and returns before the service is proven healthy; confirm with
  `pp2 status <name>` (Status + Ports) and `pp2 logs <name> -Tail 50`.
- **`pp2 start` / `stop` / `restart` accept one name, a comma list, or `all`.**
  Omitting the name means `all`.
- **Exit code is not a reliable signal for service health.** The service may
  have started and died. Always check `status`.

## Where things live

| What | Path |
| --- | --- |
| Config | `$PP2_HOME/services.json`, default `~/.pp2/services.json` |
| PID files | `<home>/run/<service>.pid` |
| Logs | `<home>/logs/<service>.out.log`, `<service>.err.log` |

`PP2_HOME` is re-read on every command; `-Config <path>` overrides the config
file for a single invocation.

## Commands

```pwsh
pp2 status [name] [-Format json]   # status table / JSON
pp2 list                           # service names
pp2 start [name]                   # start (also starts the watchdog if autoRestart)
pp2 stop [name]
pp2 restart [name]
pp2 logs <name> [-Tail 80]         # static log view
pp2 logs <name> -Watch             # INTERACTIVE — do not use
pp2 show <name> [-Format json]
pp2 add <name> -Field @{...}       # add; -Force replaces an existing definition
pp2 set <name> <field> <value>     # edit one field; -Restart applies it
pp2 remove <name>[,<name>]         # -Purge also deletes state and logs
pp2 watchdog-start|stop|status
pp2 startup-install [name]         # start at logon
pp2 startup-uninstall [name]
pp2 config                         # open services.json in an editor
```

## Minimal loop

```pwsh
pp2 add web -Field @{
  command   = 'npx'
  arguments = @('-y', 'http-server')
  shell     = $true
  ports     = @(8080)
  autoRestart = $true
}
pp2 start web
pp2 status web            # expect Status=Running, Ports=8080:open
pp2 logs web -Tail 50     # if it is not running, read the err log
```

Editing a definition of an already-running service does nothing until it is
restarted: use `pp2 set web ports 9000 -Restart`, or `pp2 restart web` after a
direct config edit.

## Configuration essentials

```json
{
  "settings": { "watchdogInterval": 60 },
  "services": {
    "api": {
      "command": "node",
      "arguments": ["server.js"],
      "workingDirectory": "D:/app",
      "ports": [3000],
      "autoRestart": true,
      "maxRetries": 3,
      "dependsOn": ["db"],
      "env": { "NODE_ENV": "production" }
    }
  }
}
```

- `command` is the only required field.
- `shell: false` (default) runs the command directly with argument boundaries
  preserved — use it for executables and scripts. It has no pipes, redirects,
  or wildcards, but a bare command name is still resolved through PATH.
- `shell: true` joins command + arguments into one line run by
  `pwsh -NoProfile -NonInteractive -Command` — use it for `npx`, `uvx`, `pipx`,
  or anything needing pipes and shell expansion.
- `ephemeral: true` is for launchers that spawn something and exit;
  `shutdownCommand` is then **required**. `autoRestart` is ignored.
- `autoRestart: true` is what starts the watchdog. After `maxRetries` crashes
  the watchdog stops retrying and leaves the service down; fix the cause, then
  `pp2 start <name>`. The watchdog only watches the services it was started
  for (recorded in `run/watchdog.services`); `pp2 stop <name>` removes that
  service from the set, and a bare `pp2 watchdog-start` covers every
  `autoRestart` service.
- `elevated: true` starts the service through sudo-for-Windows.
- `dependsOn` orders start (dependencies first) and reverses stop.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Service missing right after start | `logs/<name>.err.log`; the command exited before the program ran |
| Port shows `closed` while Running | wrong port in `ports`, or the app bound a different one |
| No auto-restart | `pp2 watchdog-status`; `autoRestart` must be true |
| Start refused: dependency not running | start the dependency, or name it too |
| `pp2: not found` | PowerShell 7+, and the module is imported in this session |
| Something else owns the port | `Get-NetTCPConnection -LocalPort <port> -State Listen`; pass `-Force` to `pp2 start` to replace the owner |
| Start hangs with no output | it is waiting on a console prompt, e.g. "Kill it? [y/N]". Run with `-Force`, or from a session with a console |

## Startup at logon (Windows)

`pp2 startup-install [name]` registers a Task Scheduler job at the current
user's normal integrity level, so it needs no admin shell.

- `pp2 startup-install dsh` → starts only `dsh`; the task is named
  `pp2 Startup (dsh)`.
- `pp2 startup-uninstall` with no name removes every `pp2 Startup*` task.
- A subset does not pull in `dependsOn` services; name them too if required.
- The watchdog it starts covers only that subset.
- With no console (the scheduled task has none) a "kill the process holding
  this port?" prompt is skipped rather than answered, so the service starts
  only if its port is free.
- Registering from a source-tree `Import-Module .\src\pp2\pp2.psd1` is refused,
  because the task imports pp2 by name and would load a different copy.