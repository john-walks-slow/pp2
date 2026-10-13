# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-10

### Added

- Initial release of pp2 - PowerShell Process Manager
- Service lifecycle management (start, stop, restart)
- Dependency-aware startup ordering
- Watchdog auto-restart with configurable retry policy
- Port health checking
- Ephemeral service support (launcher pattern)
- Elevated/sudo service support
- Live log monitoring with `pp2 logs -Watch`
- Windows Terminal multi-pane log viewer (`pp2 monit`)
- Windows startup integration via Task Scheduler
- `PP2_HOME` environment variable for state-root override
- `-Config <path>` per-invocation config override

### Fixed

- `pp2 status` output is now pipeline-friendly (`Where-Object`, `ConvertTo-Json`)
- `startup-install` resolves the manifest path from the actual module root
- Watchdog restart subprocess is no longer killed by an arbitrary 3-5s timeout
- `startupVerifyWait` now waits for the launch script's banner before declaring a service healthy
- Services whose command cannot start (typo, bad binary) are no longer reported as started

## [Unreleased]

### Fixed

- Module root resolution no longer points at `Private/` (regression from the
  Public/Private split). Services can actually launch.
- `$script:IsWindows = ...` removed; collided with PowerShell 6+ read-only
  automatic variable, causing every service to die on start.
- Retry counter is preserved across watchdog-driven restarts so `maxRetries`
  can actually be reached. It is cleared only after a service has been
  healthy for `healthCheckGrace` seconds.
- Dependency layers are now correctly nested (parallel start/stop
  previously degraded to one-service-at-a-time due to array flattening).

### Removed

- Legacy `test/` directory (Pester-3-era manual harness, superseded by
  `tests/Integration`).
- Unreferenced `examples/` scripts (README carries the same samples).
- `src/pp2/services.example.json` (already excluded from publish; content
  duplicated in README).
- `.opencode/` dev-agent scratchpads (untracked).
