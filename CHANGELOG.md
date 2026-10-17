# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
