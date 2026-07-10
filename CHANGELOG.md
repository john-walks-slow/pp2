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
