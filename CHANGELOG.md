# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-17

### Added

- Config-editing commands, so `services.json` no longer has to be edited by
  hand: `pp2 show <name>`, `pp2 add <name> -Field @{...}`,
  `pp2 set <name> <field> <value>` and `pp2 remove <name>[,<name>]`. Values are
  written with the type the field expects (`set web maxRetries 5` stores a
  number, not `"5"`), and a definition is validated before it is saved, so a
  missing `command`, a non-numeric port, an `ephemeral` service without
  `shutdownCommand` or a `dependsOn` naming a service that does not exist is
  rejected at the edit instead of silently persisted.
- `-Restart` on an edit restarts the services it touched. Without it an edit
  changes only the stored config; a running service keeps the settings it was
  launched with, and `pp2` says so rather than appearing to do nothing.
- `-Force` skips the confirmation prompt shown when an edit targets a running
  service, and `-Purge` on `remove` also deletes that service's state files
  and logs.

### Fixed

- The watchdog never auto-restarted anything. `lib/pp2-watchdog.ps1` declared a
  parameter named `$Config`, which in that script's scope is the same variable
  as pp2-core's `$script:Config` holding the parsed configuration. A parameter
  binding outranks an assignment, so `$script:Config` kept the path string and
  `$Config.services` threw `PropertyNotFoundException`. The throw landed in the
  `foreach` header of the monitoring loop, so the body was skipped for every
  service while the loop kept spinning: the watchdog stayed alive and held a
  valid PID file, nothing was logged, and every service silently lost its
  auto-restart. The parameter is now `-ConfigPath`; the new integration tests in
  `tests/Integration/Watchdog.Tests.ps1` fail against the old name.

## [1.0.2] - 2026-10-17

### Fixed

- `pp2 monit` crashed on every invocation with `PropertyNotFoundException:
  Cannot find property 'CancelKeyPress'`. `CancelKeyPress` is a .NET event
  and the module runs under `Set-StrictMode -Version Latest`, which refuses
  to read an event as a property; the `+=` subscription idiom therefore
  threw. The dashboard now subscribes through
  `[Console]::add_CancelKeyPress` / `remove_CancelKeyPress`, which are
  method calls and unaffected by strict mode, so Ctrl+C works and the
  terminal is restored on exit.
- `pp2 monit` now reports "needs an interactive console" and returns
  cleanly when output is redirected, instead of failing with a raw .NET
  exception part-way through drawing.

## [1.0.1] - 2026-10-17

### Fixed

- `Install-Module pp2` failed on PowerShell 7.6+ with "The following
  commands are already available on this system: 'Start-ThreadJob'...
  use -AllowClobber parameter", leaving nothing installed. PowerShell 7.6
  bundles `Microsoft.PowerShell.ThreadJob` machine-wide, and the module's
  hard `RequiredModules` entry collided with it during the per-user
  install. ThreadJob is now resolved at runtime by either of its names
  (`Microsoft.PowerShell.ThreadJob` on 7.6+, `ThreadJob` before) and is
  optional: without it, services in the same dependency layer start and
  stop sequentially instead of in parallel.
- `pp2 start all` printed stray `True` lines, one per service, because the
  parallel worker's Boolean return value was passed through.
- `Publish-Module` could not be used at all on non-English Windows; the
  build now publishes with `Publish-PSResource`, which packs in-process.
- Publishing from `src/` shipped `PSScriptAnalyzerSettings.psd1` to
  consumers; the build publishes only the staged `output/` tree.

## [1.0.0] - 2026-10-17

First published release
([PSGallery](https://www.powershellgallery.com/packages/pp2)).

### Added

- Service lifecycle management (start, stop, restart)
- Dependency-aware startup ordering, with parallel start/stop within a layer
- Watchdog auto-restart with exponential backoff, `maxRetries`, and a
  stability window (`healthCheckGrace`) after which the retry budget resets
- Port health checking
- Ephemeral service support (launcher pattern)
- Elevated/sudo service support
- Live log monitoring with `pp2 logs -Watch`
- Windows Terminal multi-pane log viewer (`pp2 monit`)
- Windows startup integration via Task Scheduler
- `PP2_HOME` environment variable for state-root override
- `-Config <path>` per-invocation config override
- PowerShell function API alongside the `pp2` CLI
  (`Start-Pp2Service`, `Get-Pp2Status`, ...)
- Pester test suite (unit + integration), run by `tests/run-tests.ps1`

### Fixed

- Module root resolution pointed at `Private/` after the Public/Private split,
  so no service could launch.
- `$script:IsWindows = ...` collided with the PowerShell 6+ read-only
  automatic variable, killing every service on start.
- `PP2_HOME` and `-Config` were read once at import time, so changing either
  had no effect until the module was re-imported.
- Dependency layers were flattened by `$Layers += @($Layer)`, silently
  degrading parallel start/stop to one service at a time.
- The watchdog cleared the retry counter on every restart, so `maxRetries`
  was never reached and crash-looping services restarted forever.
- The watchdog killed its own restart subprocess after a fixed ~8s, which is
  shorter than a cold PowerShell start on Windows; a restart legitimately in
  progress was discarded and the service left down.
- Services whose command could not start (mistyped binary, bad argument) were
  reported as started; startup now waits for the launch script's banner and a
  settle window.
- `pp2 status` emitted `Format-Table` format records instead of objects,
  breaking `Where-Object`, `ConvertTo-Json`, and pipelines.
- Uptime was computed from PID-file mtime, which is wrong after a clock
  change or on PID reuse; it is now tracked from when pp2 recorded the PID.
- `startup-install` resolved the manifest path via `$PSScriptRoot` inside a
  dot-sourced function, pointing at `Public\pp2.psd1`, which does not exist.
- `Format-Duration`'s `-f` operand bound to the whole array, so a 95-second
  uptime printed as `2m 35s`.
- `RequiredModules` used `ThreadJob`, which PowerShell 7.6 renamed to
  `Microsoft.PowerShell.ThreadJob` and warns about; the module now falls back
  to the legacy name on 7.4 and earlier.
- Non-ASCII source files lacked a UTF-8 BOM, which would mis-decode on
  Windows PowerShell 5.1 if the module is ever loaded there.

### Removed

- Legacy `test/` directory — a Pester-3-era manual harness superseded by
  `tests/Integration`.
- Unreferenced `examples/` scripts — the README carries the same samples.
- `src/pp2/services.example.json` — excluded from publish, and its content
  was already duplicated in the README.
- `.opencode/` dev-agent scratchpads (now gitignored).

### Security

- `Publish-Module` (PowerShellGet v2) shells out to `nuget.exe` and parses
  its stdout with a hardcoded English regex, which throws
  "Cannot index into a null array" on non-English Windows. Publishing now
  goes through `Publish-PSResource` (PSResourceGet), which packs in-process.
