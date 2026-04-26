#!/usr/bin/env pwsh
# Test service that immediately exits - for auto-restart and immediate stop detection tests
param([int]$ExitCode = 0)

Write-Host "=== CRASH TEST SERVICE ==="
Write-Host "PID: $PID"
Write-Host "CWD: $PWD.Path"
Write-Host "Args: $($args -join ' ')"
Write-Host "Env TEST_CRASH_VAR: $([Environment]::GetEnvironmentVariable('TEST_CRASH_VAR'))"
Write-Host "Will exit immediately with code $ExitCode"

exit $ExitCode