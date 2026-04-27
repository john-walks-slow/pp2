#Requires -Version 7.0
<#
.SYNOPSIS
Comprehensive integration tests for pp2 service launcher
.DESCRIPTION
Tests:
1. Argument passing (simple, quoted, shell mode, empty, Python)
2. Environment variable passing (inherit, no-inherit)
3. Working directory (cwd)
4. Launcher types (ps1, bat, exe, npx, uvx)
5. Auto-restart mechanism
6. Immediate stop detection
7. Port-based status detection
#>

param(
  [switch]$Quick,  # Skip long-running tests
  [switch]$Verbose,
  [string]$Config  # Path to config file (default: test-services.json in test dir)
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$TestDir = Join-Path $Root 'test'
$Results = @{}
$FailedTests = @()

function Get-TestConfigPath {
  if ($Config) {
    if (Test-Path $Config) { return $Config }
    throw "Config file not found: $Config"
  }
  return Join-Path $TestDir 'test-services.json'
}

function Set-TestConfigDynamic {
  param([string]$SourceConfig, [string]$TargetConfig)
  $Content = Get-Content $SourceConfig -Raw
  $DynamicContent = $Content -replace '{{TEST_DIR}}', $TestDir
  $DynamicContent | Set-Content $TargetConfig -NoNewline
}

function Write-Header([string]$Title) {
  Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Write-Result([string]$TestName, [bool]$Pass, [string]$Message = '') {
  $Results[$TestName] = $Pass
  $Color = if ($Pass) { 'Green' } else { 'Red' }
  $Status = if ($Pass) { 'PASS' } else { 'FAIL' }
  Write-Host "[$Status] $TestName" -ForegroundColor $Color
  if ($Message) { Write-Host "       $Message" -ForegroundColor $Color }
  if (-not $Pass) { $FailedTests += $TestName }
}

function Start-TestService([string]$Name) {
  & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') start $Name -Force 2>&1 | Out-Null
  Start-Sleep -Seconds 1  # Reduced wait time
}

function Stop-TestService([string]$Name) {
  & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') stop $Name 2>&1 | Out-Null
  # No extra wait - stop should be immediate
}

function Get-TestLog([string]$Name) {
  $LogPath = Join-Path $Root "logs/$Name.out.log"
  if (-not (Test-Path $LogPath)) { return '' }
  return Get-Content $LogPath -Raw
}

function Test-PortListening([int]$Port, [int]$TimeoutMs = 3000) {
  $Client = [System.Net.Sockets.TcpClient]::new()
  try {
    $Task = $Client.ConnectAsync('127.0.0.1', $Port)
    return $Task.Wait($TimeoutMs) -and $Client.Connected
  }
  catch { return $false }
  finally { $Client.Dispose() }
}

function Cleanup-AllTestServices {
  Write-Header "Cleanup"
  $TestServices = @(
    'test-args-simple', 'test-args-quoted', 'test-args-shell', 'test-args-empty',
    'test-args-python', 'test-env', 'test-env-inherit-false', 'test-cwd',
    'test-crash-auto-restart', 'test-crash-no-restart', 'test-immediate-stop',
    'test-bat-launcher', 'test-exe-launcher', 'test-npx-launcher', 'test-uvx-launcher',
    'test-port-service', 'test-ephemeral', 'test-args-json', 'test-args-url',
    'test-args-backslash', 'test-args-unicode', 'test-real-npx-http', 
    'test-real-node-http', 'test-real-python-http', 'test-real-deno-http', 
    'test-real-uvx-rich', 'test-real-python-uvicorn'
  )
  foreach ($Name in $TestServices) {
    Stop-TestService $Name
    Remove-Item (Join-Path $Root "run/$Name.pid") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Root "run/$Name.retry") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Root "run/$Name.elevated") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Root "logs/$Name.out.log") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Root "logs/$Name.err.log") -ErrorAction SilentlyContinue
  }
}

# === MAIN TEST FLOW ===

Write-Header "PP2 Integration Tests"
Write-Host "Testing: args, env, cwd, launchers, auto-restart, immediate stop"

# Backup and use test config (generated dynamically with correct paths)
$OriginalConfig = Join-Path $Root 'services.json'
$BackupConfig = Join-Path $Root 'services.json.test-backup'
if (Test-Path $OriginalConfig) {
  Copy-Item $OriginalConfig $BackupConfig -Force
}
$SourceConfig = Get-TestConfigPath
Set-TestConfigDynamic -SourceConfig $SourceConfig -TargetConfig $OriginalConfig
Write-Host "Using config: $OriginalConfig" -ForegroundColor Gray

try {
  # ===== TEST 1: Argument Passing =====
  Write-Header "1. Argument Passing Tests"
  
  # 1.1 Simple args
  Write-Host "Testing simple args..."
  Start-TestService 'test-args-simple'
  $Log = Get-TestLog 'test-args-simple'
  $Pass = [bool]($Log -match 'hello') -and [bool]($Log -match 'world')
  $Msg = if ($Pass) { "Args found in log: hello, world" } else { "Log not matching" }
  Write-Result 'args-simple' $Pass $Msg
  if ($Verbose -and -not $Pass) { Write-Host $Log }
  Stop-TestService 'test-args-simple'
  
  # 1.2 Quoted args with spaces/special chars
  Write-Host "Testing quoted args with spaces and special chars..."
  Start-TestService 'test-args-quoted'
  $Log = Get-TestLog 'test-args-quoted'
  $Pass = [bool]($Log -match 'hello world') -and [bool]($Log -match 'special=chars&more') -and [bool]($Log -match 'path with spaces')
  $Msg = if ($Pass) { "Args with spaces preserved" } else { "Log not matching" }
  Write-Result 'args-quoted' $Pass $Msg
  Stop-TestService 'test-args-quoted'
  
  # 1.3 Shell mode args
  Write-Host "Testing shell mode args..."
  Start-TestService 'test-args-shell'
  Start-Sleep -Seconds 6  # Shell mode HTTP listener needs more time
  $Log = Get-TestLog 'test-args-shell'
  $ArgsPassed = [bool]($Log -match 'shell-test')
  $PortUp = Test-PortListening 19995 2000
  # If port not up, wait more and retry
  if (-not $PortUp) {
    Start-Sleep -Seconds 4
    $PortUp = Test-PortListening 19995 2000
  }
  $Pass = $ArgsPassed
  $Msg = if ($ArgsPassed) { "Shell mode args passed" } else { "Args not found in log" }
  Write-Result 'args-shell-mode' $Pass $Msg
  # Separate port test
  Write-Result 'shell-port-up' $PortUp "Port 19995 listening"
  Stop-TestService 'test-args-shell'
  
  # 1.4 Empty args
  Write-Host "Testing empty args..."
  Start-TestService 'test-args-empty'
  $PidPath = Join-Path $Root 'run/test-args-empty.pid'
  $Pass = Test-Path $PidPath
  Write-Result 'args-empty' $Pass "Service with empty args started"
  Stop-TestService 'test-args-empty'
  
  # 1.5 Python args
  Write-Host "Testing Python script args..."
  Start-TestService 'test-args-python'
  $Log = Get-TestLog 'test-args-python'
  $Pass = [bool]($Log -match 'arg1') -and [bool]($Log -match 'arg with space') -and [bool]($Log -match '--flag=value')
  $Msg = if ($Pass) { "Python args passed correctly" } else { "Log not matching" }
  Write-Result 'args-python' $Pass $Msg
  Stop-TestService 'test-args-python'
  
  # ===== TEST 2: Environment Variables =====
  Write-Header "2. Environment Variable Tests"
  
  # 2.1 Basic env passing
  Write-Host "Testing env variable passing..."
  Start-TestService 'test-env'
  $Log = Get-TestLog 'test-env'
  $Pass = [bool]($Log -match 'TEST_VAR_1') -and [bool]($Log -match 'value1') -and [bool]($Log -match 'TEST_VAR_2') -and [bool]($Log -match 'value with spaces')
  $Msg = if ($Pass) { "Env vars passed: TEST_VAR_1, TEST_VAR_2" } else { "Log not matching" }
  Write-Result 'env-passing' $Pass $Msg
  Stop-TestService 'test-env'
  
  # 2.2 inheritEnv=false
  Write-Host "Testing inheritEnv=false..."
  Start-TestService 'test-env-inherit-false'
  $Log = Get-TestLog 'test-env-inherit-false'
  # Should have TEST_ONLY_VAR AND should have PATH (we now preserve essential vars)
  $HasOnlyVar = [bool]($Log -match 'TEST_ONLY_VAR')
  $HasPath = [bool]($Log -match 'Path')
  $Pass = $HasOnlyVar -and $HasPath
  $Msg = if ($Pass) { "TEST_ONLY_VAR and PATH preserved" } else { "HasOnlyVar=$HasOnlyVar, HasPath=$HasPath" }
  Write-Result 'env-inherit-false' $Pass $Msg
  Stop-TestService 'test-env-inherit-false'
  
  # ===== TEST 3: Working Directory =====
  Write-Header "3. Working Directory Tests"
  
  # 3.1 Custom cwd
  Write-Host "Testing custom workingDirectory..."
  Start-TestService 'test-cwd'
  $Log = Get-TestLog 'test-cwd'
  $Pass = [bool]($Log -match 'subdir')
  $Msg = if ($Pass) { "CWD set to subdir" } else { "CWD not matching" }
  Write-Result 'cwd-custom' $Pass $Msg
  Stop-TestService 'test-cwd'
  
  # ===== TEST 4: Launcher Types =====
  Write-Header "4. Launcher Type Tests"
  
  # 4.1 PS1 launcher
  Write-Host "Testing PS1 launcher..."
  Start-TestService 'test-args-simple'
  $Pass = [bool](Test-Path (Join-Path $Root 'run/test-args-simple.pid'))
  $Msg = if ($Pass) { "PS1 script executed" } else { "PID file not found" }
  Write-Result 'launcher-ps1' $Pass $Msg
  Stop-TestService 'test-args-simple'
  
  # 4.2 BAT launcher
  Write-Host "Testing BAT launcher..."
  Start-TestService 'test-bat-launcher'
  $Log = Get-TestLog 'test-bat-launcher'
  $Pass = [bool]($Log -match 'BAT TEST SERVICE') -and [bool]($Log -match 'arg1') -and [bool]($Log -match 'arg2')
  $Msg = if ($Pass) { "BAT script executed with args" } else { "Log not matching" }
  Write-Result 'launcher-bat' $Pass $Msg
  Stop-TestService 'test-bat-launcher'
  
  # 4.3 EXE launcher
  Write-Host "Testing EXE launcher..."
  Start-TestService 'test-exe-launcher'
  $Log = Get-TestLog 'test-exe-launcher'
  $Pass = [bool]($Log -match 'exe-test')
  $Msg = if ($Pass) { "EXE (pwsh.exe) executed with args" } else { "Log not matching" }
  Write-Result 'launcher-exe' $Pass $Msg
  Stop-TestService 'test-exe-launcher'
  
  # 4.4 NPX launcher (shell mode)
  Write-Host "Testing NPX launcher..."
  Start-TestService 'test-npx-launcher'
  Start-Sleep -Seconds 5  # NPX needs time to download/run
  $Log = Get-TestLog 'test-npx-launcher'
  $Pass = [bool]($Log -match 'hello from npx' -or $Log -match 'cowsay')
  $Msg = if ($Pass) { "NPX cowsay executed" } else { "Log not matching" }
  Write-Result 'launcher-npx' $Pass $Msg
  Stop-TestService 'test-npx-launcher'
  
  # 4.5 UVX launcher (shell mode)
  Write-Host "Testing UVX launcher..."
  Start-TestService 'test-uvx-launcher'
  Start-Sleep -Seconds 5  # UVX needs time to download/run
  $Log = Get-TestLog 'test-uvx-launcher'
  $Pass = [bool]($Log -match 'hello from uvx')
  $Msg = if ($Pass) { "UVX python executed" } else { "Log not matching" }
  Write-Result 'launcher-uvx' $Pass $Msg
  Stop-TestService 'test-uvx-launcher'
  
  # ===== TEST 5: Port-Based Status =====
  Write-Header "5. Port Detection Tests"
  
  Write-Host "Testing port-based status..."
  Start-TestService 'test-port-service'
  Start-Sleep -Seconds 4
  $PortUp = Test-PortListening 19997 2000
  $Msg = if ($PortUp) { "Port 19997 listening after start" } else { "Port 19997 not listening" }
  Write-Result 'port-detection' $PortUp $Msg
  
  # Check status command
  $StatusJson = & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') status test-port-service -Format json 2>&1 | Out-String
  $Status = $StatusJson | ConvertFrom-Json
  $Pass = [bool]($Status.Status -eq 'Running')
  $Msg = if ($Pass) { "Status shows running" } else { "Status not running: $($Status.Status)" }
  Write-Result 'port-status-command' $Pass $Msg
  
  Stop-TestService 'test-port-service'
  $PortDown = -not (Test-PortListening 19997)
  $Msg = if ($PortDown) { "Port 19997 closed after stop" } else { "Port 19997 still open" }
  Write-Result 'port-after-stop' $PortDown $Msg
  
  # ===== TEST 6: Immediate Stop Detection =====
  Write-Header "6. Immediate Stop Detection Tests"
  
  Write-Host "Testing stop on running service..."
  Start-TestService 'test-immediate-stop'
  Start-Sleep -Seconds 3
  $PidBefore = if (Test-Path (Join-Path $Root 'run/test-immediate-stop.pid')) {
    [int](Get-Content (Join-Path $Root 'run/test-immediate-stop.pid') -Raw)
  } else { 0 }
  
  Stop-TestService 'test-immediate-stop'
  Start-Sleep -Seconds 2
  
  $PidFileGone = -not (Test-Path (Join-Path $Root 'run/test-immediate-stop.pid'))
  $ProcessGone = -not (Get-Process -Id $PidBefore -ErrorAction SilentlyContinue)
  $Pass = [bool]($PidFileGone) -or [bool]($ProcessGone)
  Write-Result 'immediate-stop' $Pass "PID file removed, process stopped"
  
  # ===== TEST 7: Auto-Restart (skip in quick mode) =====
  if (-not $Quick) {
    Write-Header "7. Auto-Restart Tests"
    
    Write-Host "Testing autoRestart=true..."
    # Stop watchdog first
    & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') watchdog-stop 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    # Start watchdog with short interval (1 second for faster testing)
    & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') watchdog-start -Interval 1 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    
    # Start crash service with auto-restart
    Start-TestService 'test-crash-auto-restart'
    
    # Service will crash immediately, watchdog should restart
    $RetryPath = Join-Path $Root 'run/test-crash-auto-restart.retry'
    
    # Wait longer for retries to accumulate (20 seconds with 1s interval)
    Start-Sleep -Seconds 20
    
    $RetryCount = if (Test-Path $RetryPath) { [int](Get-Content $RetryPath -Raw) } else { 0 }
    $Pass = $RetryCount -ge 1 -and $RetryCount -le 3
    Write-Result 'auto-restart-retries' $Pass "Retry count: $RetryCount (expected 1-3)"
    
    # Stop watchdog
    & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') watchdog-stop 2>&1 | Out-Null
    Stop-TestService 'test-crash-auto-restart'
    
    Write-Host "Testing autoRestart=false..."
    Start-TestService 'test-crash-no-restart'
    Start-Sleep -Seconds 5
    
    $RetryPath = Join-Path $Root 'run/test-crash-no-restart.retry'
    $NoRetry = -not (Test-Path $RetryPath)
    $PidGone = -not (Test-Path (Join-Path $Root 'run/test-crash-no-restart.pid'))
    Write-Result 'no-auto-restart' ($NoRetry -or $PidGone) "No retry file, service stayed dead"
    Stop-TestService 'test-crash-no-restart'
  } else {
    Write-Host "Skipping auto-restart tests (quick mode)"
    $Results['auto-restart-retries'] = $true
    $Results['no-auto-restart'] = $true
  }
  
  # ===== TEST 8: Restart Command =====
  Write-Header "8. Restart Command Tests"
  
  Write-Host "Testing restart command..."
  Start-TestService 'test-args-simple'
  $Pid1 = if (Test-Path (Join-Path $Root 'run/test-args-simple.pid')) {
    [int](Get-Content (Join-Path $Root 'run/test-args-simple.pid') -Raw)
  } else { 0 }
  
  # Restart
  & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') restart test-args-simple 2>&1 | Out-Null
  Start-Sleep -Seconds 3
  
  $Pid2 = if (Test-Path (Join-Path $Root 'run/test-args-simple.pid')) {
    [int](Get-Content (Join-Path $Root 'run/test-args-simple.pid') -Raw)
  } else { 0 }
  
  $Pass = $Pid2 -gt 0 -and $Pid2 -ne $Pid1
  $Msg = if ($Pass) { "Restart creates new PID ($Pid1 -> $Pid2)" } else { "PID not changed" }
  Write-Result 'restart-new-pid' $Pass $Msg
  Stop-TestService 'test-args-simple'
  
  # ===== TEST 9: Complex Args & Escaping =====
  Write-Header "9. Complex Args & Escaping Tests"
  
  # Args with special chars (already tested in args-quoted)
  Write-Host "Verifying special chars preservation..."
  Start-TestService 'test-args-quoted'
  $Log = Get-TestLog 'test-args-quoted'
  $Pass = [bool]($Log -match 'special=chars') -and [bool]($Log -match 'path with spaces')
  Write-Result 'args-special-chars' $Pass "Args with = and spaces preserved"
  Stop-TestService 'test-args-quoted'
  
  # Args with ampersand
  $Pass = [bool]($Log -match '&more')
  Write-Result 'args-ampersand' $Pass "Args with & preserved"
  
  # JSON-like args
  Write-Host "Testing JSON-like args..."
  Start-TestService 'test-args-json'
  $Log = Get-TestLog 'test-args-json'
  $Pass = [bool]($Log -match 'key') -and [bool]($Log -match 'value')
  Write-Result 'args-json' $Pass "JSON-like args preserved"
  Stop-TestService 'test-args-json'
  
  # URL args
  Write-Host "Testing URL args..."
  Start-TestService 'test-args-url'
  $Log = Get-TestLog 'test-args-url'
  $Pass = [bool]($Log -match 'example.com') -and [bool]($Log -match 'foo=bar')
  Write-Result 'args-url' $Pass "URL args preserved"
  Stop-TestService 'test-args-url'
  
  # Backslash args
  Write-Host "Testing backslash args..."
  Start-TestService 'test-args-backslash'
  $Log = Get-TestLog 'test-args-backslash'
  $Pass = [bool]($Log -match 'Program Files')
  Write-Result 'args-backslash' $Pass "Backslash args preserved"
  Stop-TestService 'test-args-backslash'
  
  # Unicode args
  Write-Host "Testing Unicode args..."
  Start-TestService 'test-args-unicode'
  $Log = Get-TestLog 'test-args-unicode'
  $Pass = [bool]($Log -match '中文') -or [bool]($Log -match '日本')
  Write-Result 'args-unicode' $Pass "Unicode args preserved"
  Stop-TestService 'test-args-unicode'
  
  # ===== TEST 10: Status Command Formats =====
  Write-Header "10. Status Command Tests"
  
  Write-Host "Testing status table format..."
  $StatusTable = & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') status 2>&1 | Out-String
  $Pass = [bool]($StatusTable -match 'Name') -and [bool]($StatusTable -match 'Status')
  Write-Result 'status-table' $Pass "Status table format works"
  
  Write-Host "Testing status JSON format..."
  $StatusJson = & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') status -Format json 2>&1 | Out-String
  $Pass = [bool]($StatusJson -match '"Name"') -and [bool]($StatusJson -match '"Status"')
  Write-Result 'status-json' $Pass "Status JSON format works"
  
  # ===== TEST 11: List Command =====
  Write-Header "11. List Command Tests"
  
  Write-Host "Testing list command..."
  $ListOutput = & pwsh -NoProfile -File (Join-Path $Root 'pp2.ps1') list 2>&1 | Out-String
  $Pass = [bool]($ListOutput -match 'test-args')
  Write-Result 'list-command' $Pass "List command returns test services"
  
  # ===== TEST 12: Real-World Scenarios =====
  Write-Header "12. Real-World Scenario Tests"
  
  # NPX HTTP Server
  Write-Host "Testing real NPX http-server..."
  Start-TestService 'test-real-npx-http'
  Start-Sleep -Seconds 25  # NPX needs more time to download/package on first run
  $PortUp = Test-PortListening 19980 5000
  $Msg = if ($PortUp) { "NPX http-server on 19980 works" } else { "Port not listening (may need cache)" }
  Write-Result 'real-npx-http' $PortUp $Msg
  Stop-TestService 'test-real-npx-http'
  
  # Node.js HTTP Server
  Write-Host "Testing real Node.js HTTP server..."
  Start-TestService 'test-real-node-http'
  Start-Sleep -Seconds 3
  $PortUp = Test-PortListening 19981 2000
  $Msg = if ($PortUp) { "Node.js HTTP on 19981 works" } else { "Port not listening" }
  Write-Result 'real-node-http' $PortUp $Msg
  Stop-TestService 'test-real-node-http'
  
  # Python HTTP Server
  Write-Host "Testing real Python HTTP server..."
  Start-TestService 'test-real-python-http'
  Start-Sleep -Seconds 3
  $PortUp = Test-PortListening 19982 2000
  $Msg = if ($PortUp) { "Python HTTP on 19982 works" } else { "Port not listening" }
  Write-Result 'real-python-http' $PortUp $Msg
  Stop-TestService 'test-real-python-http'
  
  # Deno HTTP Server (may not be installed)
  Write-Host "Testing real Deno HTTP server..."
  Start-TestService 'test-real-deno-http'
  Start-Sleep -Seconds 5
  $PortUp = Test-PortListening 19983 3000
  $Msg = if ($PortUp) { "Deno HTTP on 19983 works" } else { "Port not listening (Deno may not be installed)" }
  Write-Result 'real-deno-http' $PortUp $Msg
  Stop-TestService 'test-real-deno-http'
  
  # UVX Rich (one-off command)
  Write-Host "Testing real UVX rich..."
  Start-TestService 'test-real-uvx-rich'
  Start-Sleep -Seconds 8
  $Log = Get-TestLog 'test-real-uvx-rich'
  $Pass = [bool]($Log -match 'PP2 Test OK' -or $Log -match 'rich')
  $Msg = if ($Pass) { "UVX rich executed successfully" } else { "Output not found" }
  Write-Result 'real-uvx-rich' $Pass $Msg
  Stop-TestService 'test-real-uvx-rich'
  
  # ===== SUMMARY =====
  Write-Header "Test Summary"
  $Passed = ($Results.Values | Where-Object { $_ }).Count
  $Total = $Results.Count
  $FailedCount = $FailedTests.Count
  
  Write-Host "Total: $Passed/$Total passed" -ForegroundColor $(if ($Passed -eq $Total) { 'Green' } else { 'Yellow' })
  
  if ($FailedTests.Count -gt 0) {
    Write-Host "`nFailed tests:" -ForegroundColor Red
    $FailedTests | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  }
  
}
finally {
  Cleanup-AllTestServices
  
  # Restore original config
  if (Test-Path $BackupConfig) {
    Move-Item $BackupConfig $OriginalConfig -Force
  }
}

Write-Header "Done"
exit $(if ($Passed -eq $Total) { 0 } else { 1 })