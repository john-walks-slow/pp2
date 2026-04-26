Set-StrictMode -Version Latest

function Initialize-Pw2Context {
  param([Parameter(Mandatory = $true)][string]$ScriptRoot)

  $script:Root = $ScriptRoot
  $script:ConfigPath = Join-Path $script:Root 'services.json'
  $script:RunDir = Join-Path $script:Root 'run'
  $script:LogDir = Join-Path $script:Root 'logs'
  $script:TaskName = 'pp2 Startup'

  New-Item -ItemType Directory -Force -Path $script:RunDir, $script:LogDir | Out-Null
  $script:Config = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
}

function Get-Setting([string]$Name, $Default) {
  $Settings = $script:Config.settings
  if (-not $Settings) { return $Default }
  $Property = $Settings.PSObject.Properties[$Name]
  if ($Property) { return $Property.Value }
  return $Default
}

function Get-ServiceNames([string]$Name = 'all') {
  if ($Name -eq 'all') { return @($Config.services.PSObject.Properties.Name) }
  if (-not $Config.services.PSObject.Properties[$Name]) { throw "Unknown service: $Name" }
  return @($Name)
}

function Get-ServiceConfig([string]$ServiceName) {
  $Property = $Config.services.PSObject.Properties[$ServiceName]
  if (-not $Property) { throw "Unknown service: $ServiceName" }
  return $Property.Value
}

function Get-ServiceProperty([pscustomobject]$Service, [string]$PropertyName, $Default = $null) {
  $Property = $Service.PSObject.Properties[$PropertyName]
  if ($Property) { return $Property.Value }
  return $Default
}

function Test-IsElevated {
  $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
  return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PwshPath {
  $Pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
  if ($Pwsh) { return $Pwsh }
  return (Get-Command powershell.exe).Source
}

function Get-StatePath([string]$ServiceName, [string]$Kind) { Join-Path $RunDir "$ServiceName.$Kind" }
function Get-PidPath([string]$ServiceName) { Get-StatePath $ServiceName 'pid' }
function Get-ElevatedPath([string]$ServiceName) { Get-StatePath $ServiceName 'elevated' }
function Get-RetryPath([string]$ServiceName) { Get-StatePath $ServiceName 'retry' }
function Get-OutLog([string]$ServiceName) { Join-Path $LogDir "$ServiceName.out.log" }
function Get-ErrLog([string]$ServiceName) { Join-Path $LogDir "$ServiceName.err.log" }

function Remove-ServiceState([string]$ServiceName) {
  'pid', 'elevated', 'retry' | ForEach-Object {
    Remove-Item (Get-StatePath $ServiceName $_) -ErrorAction SilentlyContinue
  }
}

function Get-RecordedProcess([string]$ServiceName) {
  $PidPath = Get-PidPath $ServiceName
  if (-not (Test-Path $PidPath)) { return $null }

  $PidContent = (Get-Content $PidPath -Raw).Trim()
  
  # Handle ephemeral services (launcher pattern)
  if ($PidContent -eq 'ephemeral') {
    return 'ephemeral'
  }

  $RecordedPid = 0
  if (-not [int]::TryParse($PidContent, [ref]$RecordedPid)) {
    Remove-ServiceState $ServiceName
    return $null
  }

  return Get-Process -Id $RecordedPid -ErrorAction SilentlyContinue
}

function Test-Port([int]$Port, [int]$TimeoutMs) {
  if (-not $TimeoutMs) { $TimeoutMs = [int](Get-Setting 'portCheckTimeout' 200) }
  $Client = [System.Net.Sockets.TcpClient]::new()
  try {
    $ConnectTask = $Client.ConnectAsync('127.0.0.1', $Port)
    if ($ConnectTask.Wait($TimeoutMs)) { return $Client.Connected }
    return $false
  }
  finally { $Client.Dispose() }
}

function Get-ProcessByPort([int]$Port) {
  $Conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($Conn) { return [int]$Conn.OwningProcess }
  return $null
}

function Get-ProcessStats([System.Diagnostics.Process]$Process) {
  if (-not $Process) { return @{ CPU = '-'; Memory = '-' } }
  try {
    return @{
      CPU = "$($Process.CPU.ToString('F1')) s"
      Memory = "$([math]::Round($Process.WorkingSet64 / 1MB, 1).ToString('F1')) MB"
    }
  }
  catch { return @{ CPU = '-'; Memory = '-' } }
}

function Invoke-ElevatedPwsh([string]$Command) {
  $SudoPath = (Get-Command sudo.exe -ErrorAction SilentlyContinue).Source
  if (-not $SudoPath) { throw 'sudo not available' }

  $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
  & $SudoPath pwsh -NoProfile -EncodedCommand $Encoded 2>&1 | Out-Null
}

function ConvertTo-PwshLiteral([string]$Value) {
  return "'$($Value -replace "'", "''")'"
}

function Stop-ProcessTree([int]$ProcessId, [switch]$Elevated) {
  if ($Elevated -and -not (Test-IsElevated)) {
    Invoke-ElevatedPwsh "taskkill.exe /PID $ProcessId /T /F | Out-Null"
    return
  }

  & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
}

function Invoke-ShutdownCommand([string]$ServiceName, [pscustomobject]$Service, [bool]$IsElevated) {
  $ShutdownCommand = Get-ServiceProperty $Service 'shutdownCommand'
  if (-not $ShutdownCommand) { return }

  $Command = [string]$ShutdownCommand
  $Arguments = @(Get-ServiceProperty $Service 'shutdownArguments' @()) | Where-Object { $_ }

  if ($IsElevated -and -not (Test-IsElevated)) {
    $LiteralArgs = ($Arguments | ForEach-Object { ConvertTo-PwshLiteral ([string]$_) }) -join ', '
    Invoke-ElevatedPwsh "& $(ConvertTo-PwshLiteral $Command) @($LiteralArgs) | Out-Null"
    return
  }

  & $Command @Arguments 2>&1 | Out-Null
}

function Test-Dependencies([string]$ServiceName) {
  $Service = Get-ServiceConfig $ServiceName
  foreach ($Dep in @(Get-ServiceProperty $Service 'dependsOn' @()) | Where-Object { $_ }) {
    if (-not (Get-RecordedProcess $Dep)) {
      Write-Host "dependency $Dep not running, cannot start $ServiceName"
      return $false
    }

    foreach ($Port in @(Get-ServiceProperty (Get-ServiceConfig $Dep) 'ports' @()) | Where-Object { $_ }) {
      if (-not (Test-Port $Port)) {
        Write-Host "dependency $Dep port $Port not ready"
        return $false
      }
    }
  }
  return $true
}

function Get-StopOrder([string[]]$ServiceNames) {
  if ($ServiceNames.Count -le 1) { return $ServiceNames }

  $DependentsOf = @{}
  foreach ($ServiceName in $Config.services.PSObject.Properties.Name) { $DependentsOf[$ServiceName] = @() }

  foreach ($ServiceName in $Config.services.PSObject.Properties.Name) {
    foreach ($Dep in @(Get-ServiceProperty (Get-ServiceConfig $ServiceName) 'dependsOn' @()) | Where-Object { $_ }) {
      if ($DependentsOf.ContainsKey($Dep)) { $DependentsOf[$Dep] += $ServiceName }
    }
  }

  $Ordered = @()
  $Remaining = @($ServiceNames)
  while ($Remaining.Count -gt 0) {
    $ProgressMade = $false
    foreach ($ServiceName in @($Remaining)) {
      $Dependents = @($DependentsOf[$ServiceName]) | Where-Object { $_ -in $ServiceNames }
      if ((@($Dependents | Where-Object { $_ -notin $Ordered })).Count -eq 0) {
        $Ordered += $ServiceName
        $Remaining = @($Remaining | Where-Object { $_ -ne $ServiceName })
        $ProgressMade = $true
      }
    }
    if (-not $ProgressMade) { return @($Ordered + $Remaining) }
  }
  return $Ordered
}

function Stop-One([string]$ServiceName) {
  $Service = Get-ServiceConfig $ServiceName
  $ProcessOrEphemeral = Get-RecordedProcess $ServiceName
  
  # Handle ephemeral services
  if ($ProcessOrEphemeral -eq 'ephemeral') {
    if (-not (Get-ServiceProperty $Service 'shutdownCommand')) {
      Write-Host "ERROR: ephemeral service $ServiceName requires shutdownCommand"
      return
    }
    
    Write-Host "stopping $ServiceName (ephemeral)..."
    $IsElevated = Test-Path (Get-ElevatedPath $ServiceName)
    Invoke-ShutdownCommand $ServiceName $Service $IsElevated
    Remove-ServiceState $ServiceName
    Write-Host "stopped $ServiceName"
    return
  }
  
  # Handle normal services
  $Process = $ProcessOrEphemeral
  if (-not $Process) {
    Remove-ServiceState $ServiceName
    Write-Host "$ServiceName already stopped"
    return
  }

  Write-Host "stopping $ServiceName..."
  $IsElevated = Test-Path (Get-ElevatedPath $ServiceName)

  if (Get-ServiceProperty $Service 'shutdownCommand') {
    Write-Host "executing shutdown command for $ServiceName..."
    Invoke-ShutdownCommand $ServiceName $Service $IsElevated
    Start-Sleep -Seconds 2
    $ShutdownTimeout = [int](Get-Setting 'shutdownTimeout' 5000)
    $Process.WaitForExit($ShutdownTimeout)
  }

  if (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue) {
    Stop-ProcessTree $Process.Id -Elevated:$IsElevated
  }

  Remove-ServiceState $ServiceName
  Write-Host "stopped $ServiceName"
}

function Stop-Many([string[]]$ServiceNames) {
  foreach ($ServiceName in (Get-StopOrder $ServiceNames)) { Stop-One $ServiceName }
}

function Stop-Watchdog {
  $WatchPidPath = Join-Path $RunDir 'watchdog.pid'
  if (-not (Test-Path $WatchPidPath)) {
    Write-Host 'watchdog not running'
    return
  }

  $WatchPid = [int](Get-Content $WatchPidPath -Raw)
  $WatchProcess = Get-Process -Id $WatchPid -ErrorAction SilentlyContinue
  if ($WatchProcess) { & taskkill.exe /PID $WatchPid /F 2>&1 | Out-Null }
  Remove-Item $WatchPidPath -ErrorAction SilentlyContinue
  Write-Host "stopped watchdog pid=$WatchPid"
}

function Start-WatchdogProcess([int]$Interval, [switch]$ReplaceExisting) {
  if (-not $Interval) { $Interval = [int](Get-Setting 'watchdogInterval' 60) }
  $WatchPidPath = Join-Path $RunDir 'watchdog.pid'
  $TempPidPath = Join-Path $RunDir 'watchdog.pid.new'

  if (-not $ReplaceExisting -and (Test-Path $WatchPidPath)) {
    $WatchPid = [int](Get-Content $WatchPidPath -Raw)
    if (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue) {
      Write-Host "watchdog already running pid=$WatchPid"
      return
    }
    Remove-Item $WatchPidPath -ErrorAction SilentlyContinue
  }

  $Process = Start-Process -FilePath (Get-PwshPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'lib/pp2-watchdog.ps1'), '-Interval', $Interval) -WindowStyle Hidden -PassThru
  Set-Content -Path $TempPidPath -Value $Process.Id -NoNewline
  Start-Sleep -Milliseconds 500

  if (-not (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)) {
    Remove-Item $TempPidPath -ErrorAction SilentlyContinue
    Write-Host 'WARNING: watchdog failed to start'
    return
  }

  if ($ReplaceExisting -and (Test-Path $WatchPidPath)) {
    $OldPid = [int](Get-Content $WatchPidPath -Raw)
    if (Get-Process -Id $OldPid -ErrorAction SilentlyContinue) {
      & taskkill.exe /PID $OldPid /F 2>&1 | Out-Null
      Write-Host "restarted watchdog (old=$OldPid -> new=$($Process.Id))"
    }
  }
  else {
    Write-Host "started watchdog pid=$($Process.Id)"
  }

  Move-Item -Path $TempPidPath -Destination $WatchPidPath -Force
}

function Start-WatchdogIfNeeded([string]$Name = 'all') {
  $NeedsWatchdog = (Get-ServiceNames $Name | Where-Object { Get-ServiceProperty (Get-ServiceConfig $_) 'autoRestart' $false } | Select-Object -First 1) -ne $null
  if ($NeedsWatchdog) { Start-WatchdogProcess -ReplaceExisting }
}

function Stop-LegacyOwners([string]$ServiceName, [bool]$Force) {
  $Service = Get-ServiceConfig $ServiceName
  $Tracked = Get-RecordedProcess $ServiceName
  $OwnerPids = @{}

  foreach ($Port in @(Get-ServiceProperty $Service 'ports' @()) | Where-Object { $_ }) {
    foreach ($Connection in Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
      $OwnerPids[[int]$Connection.OwningProcess] = "port $Port"
    }
  }

  $LegacyProcessName = Get-ServiceProperty $Service 'legacyProcessName'
  if ($LegacyProcessName) {
    Get-Process -Name $LegacyProcessName -ErrorAction SilentlyContinue | ForEach-Object {
      $OwnerPids[[int]$_.Id] = "process $LegacyProcessName"
    }
  }

  foreach ($OwnerPid in $OwnerPids.Keys) {
    if ($Tracked -and $Tracked.Id -eq $OwnerPid) { continue }
    $OwnerProcess = Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue
    if (-not $OwnerProcess) { continue }

    if (-not $Force) {
      Write-Host "WARNING: $($OwnerPids[$OwnerPid]) occupied by $($OwnerProcess.ProcessName) (pid=$OwnerPid)"
      if ((Read-Host 'Kill it? [y/N]') -ne 'y') { continue }
    }

    Write-Host "stopping legacy owner for $ServiceName pid=$OwnerPid"
    Stop-ProcessTree $OwnerPid
  }
}

function Start-One([string]$ServiceName, [bool]$Force, [bool]$NoRetryReset = $false) {
  $ProcessOrEphemeral = Get-RecordedProcess $ServiceName
  if ($ProcessOrEphemeral) {
    Write-Host "$ServiceName already running"
    return $true
  }
  if (-not (Test-Dependencies $ServiceName)) { return $false }

  $Service = Get-ServiceConfig $ServiceName
  $IsEphemeral = (Get-ServiceProperty $Service 'ephemeral' $false) -eq $true
  
  # Validate ephemeral service configuration
  if ($IsEphemeral -and -not (Get-ServiceProperty $Service 'shutdownCommand')) {
    Write-Host "ERROR: ephemeral service $ServiceName requires shutdownCommand"
    return $false
  }
  
  $RequiresElevated = (Get-ServiceProperty $Service 'elevated' $false) -eq $true
  $CurrentlyElevated = Test-IsElevated
  if ($RequiresElevated -and -not $CurrentlyElevated) { Write-Host "WARNING: $ServiceName requires elevated privileges" }

  Stop-LegacyOwners $ServiceName $Force

  $StartArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'lib/pp2-run-service.ps1'), '-Name', $ServiceName)
  $OutLog = Get-OutLog $ServiceName
  $ErrLog = Get-ErrLog $ServiceName
  $ActualPid = $null

  if ($RequiresElevated -and -not $CurrentlyElevated) {
    Write-Host "starting $ServiceName with elevated privileges..."
    $TempPidFile = Join-Path $RunDir "$ServiceName.pid.tmp"
    $ScriptPath = Join-Path $RunDir "$ServiceName.start.ps1"
    $LiteralArgs = ($StartArgs | ForEach-Object { ConvertTo-PwshLiteral ([string]$_) }) -join ', '
    @"
`$Process = Start-Process -FilePath $(ConvertTo-PwshLiteral (Get-PwshPath)) -ArgumentList @($LiteralArgs) -WindowStyle Hidden -RedirectStandardOutput $(ConvertTo-PwshLiteral $OutLog) -RedirectStandardError $(ConvertTo-PwshLiteral $ErrLog) -PassThru
Set-Content -Path $(ConvertTo-PwshLiteral $TempPidFile) -Value `$Process.Id -NoNewline
"@ | Set-Content -Path $ScriptPath -Encoding UTF8

    try { Invoke-ElevatedPwsh "& $(ConvertTo-PwshLiteral $ScriptPath)" }
    finally { Remove-Item $ScriptPath -ErrorAction SilentlyContinue }

    for ($i = 0; $i -lt 5; $i++) {
      Start-Sleep -Seconds 1
      if (Test-Path $TempPidFile) {
        $ActualPid = [int](Get-Content $TempPidFile -Raw)
        Remove-Item $TempPidFile -ErrorAction SilentlyContinue
        break
      }
    }

    if (-not $ActualPid) {
      $Ports = @(Get-ServiceProperty $Service 'ports' @()) | Where-Object { $_ }
      if ($Ports.Count -gt 0) { $ActualPid = Get-ProcessByPort $Ports[0] }
    }

    if ($ActualPid) { Set-Content -Path (Get-ElevatedPath $ServiceName) -Value 'true' -NoNewline }
  }
  else {
    $Process = Start-Process -FilePath (Get-PwshPath) -ArgumentList $StartArgs -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -PassThru
    $ActualPid = $Process.Id
    if ($CurrentlyElevated) { Set-Content -Path (Get-ElevatedPath $ServiceName) -Value 'true' -NoNewline }
  }

  if (-not $ActualPid) {
    Write-Host "ERROR: Failed to start $ServiceName (PID tracking failed)"
    return $false
  }

  # Ephemeral services: write 'ephemeral' marker instead of PID
  if ($IsEphemeral) {
    Set-Content -Path (Get-PidPath $ServiceName) -Value 'ephemeral' -NoNewline
    if (-not $NoRetryReset) { Remove-Item (Get-RetryPath $ServiceName) -ErrorAction SilentlyContinue }
    Write-Host "started $ServiceName (ephemeral mode)"
    return $true
  }

  # Normal services: write PID and verify process stays alive
  Set-Content -Path (Get-PidPath $ServiceName) -Value $ActualPid -NoNewline
  if (-not $NoRetryReset) { Remove-Item (Get-RetryPath $ServiceName) -ErrorAction SilentlyContinue }
  $VerifyWaitMs = [int](Get-Setting 'startupVerifyWait' 2500)
  Start-Sleep -Milliseconds $VerifyWaitMs

  if (-not (Get-Process -Id $ActualPid -ErrorAction SilentlyContinue)) {
    Write-Host "WARNING: $ServiceName process (pid=$ActualPid) exited immediately"
    Remove-ServiceState $ServiceName
    return $false
  }

  Write-Host "started $ServiceName pid=$ActualPid"
  return $true
}

function Show-Status([string]$Name = 'all', [string]$Format = 'table') {
  $Rows = foreach ($ServiceName in Get-ServiceNames $Name) {
    $Service = Get-ServiceConfig $ServiceName
    $ProcessOrEphemeral = Get-RecordedProcess $ServiceName
    $IsEphemeral = $ProcessOrEphemeral -eq 'ephemeral'
    $Process = if ($IsEphemeral) { $null } else { $ProcessOrEphemeral }
    
    $Ports = @(Get-ServiceProperty $Service 'ports' @())
    $PortStatus = if ($Ports.Count -eq 0) { '-' } else { ($Ports | ForEach-Object { "$($_):$(if (Test-Port $_) { 'open' } else { 'closed' })" }) -join ', ' }
    $Stats = if ($IsEphemeral) { @{ CPU = '-'; Memory = '-' } } else { Get-ProcessStats $Process }
    
    # Calculate uptime from PID file creation time
    $PidPath = Get-PidPath $ServiceName
    $Uptime = if ($Process -and (Test-Path $PidPath)) {
      $PidFileTime = (Get-Item $PidPath).LastWriteTime
      $Duration = (Get-Date) - $PidFileTime
      if ($Duration.TotalDays -ge 1) { "{0}d {1}h" -f [int]$Duration.TotalDays, [int]$Duration.Hours }
      elseif ($Duration.TotalHours -ge 1) { "{0}h {1}m" -f [int]$Duration.TotalHours, [int]$Duration.Minutes }
      else { "{0}m {1}s" -f [int]$Duration.TotalMinutes, [int]$Duration.Seconds }
    } else { '-' }
    
    # Get retry count
    $RetryPath = Get-RetryPath $ServiceName
    $Retries = if (Test-Path $RetryPath) { [int](Get-Content $RetryPath -Raw) } else { 0 }
    $MaxRetries = [int](Get-ServiceProperty $Service 'maxRetries' 3)
    $RetryStatus = if ($Retries -gt 0) { "$Retries/$MaxRetries" } else { '-' }

    [pscustomobject]@{
      Name = $ServiceName
      Status = if ($IsEphemeral) { 'Running (ephemeral)' } elseif ($Process) { 'Running' } else { 'Stopped' }
      Pid = if ($IsEphemeral) { '-' } elseif ($Process) { $Process.Id } else { '' }
      Uptime = $Uptime
      CPU = $Stats.CPU
      Memory = $Stats.Memory
      Ports = $PortStatus
      Retries = $RetryStatus
      AutoRestart = if (Get-ServiceProperty $Service 'autoRestart' $false) { 'yes' } else { 'no' }
      Description = Get-ServiceProperty $Service 'description' ''
    }
  }

  if ($Format -eq 'json') { $Rows | ConvertTo-Json -Depth 2 }
  else { $Rows | Format-Table -AutoSize }
}

function Watch-Status([string]$Name, [string]$Format, [int]$Interval) {
  while ($true) {
    Clear-Host
    Write-Host "$(Get-Date -Format 'HH:mm:ss') Service Status (Ctrl+C to exit)"
    Show-Status $Name $Format
    Start-Sleep -Seconds $Interval
  }
}

function Show-Logs([string]$ServiceName, [int]$Tail, [bool]$WatchMode) {
  $WatchLogsPath = Join-Path $Root 'lib/pp2-watch-logs.ps1'
  if ($WatchMode) { & $WatchLogsPath -ServiceName $ServiceName -Tail $Tail -Watch }
  else { & $WatchLogsPath -ServiceName $ServiceName -Tail $Tail }
}

function Show-Monit([string]$Name, [int]$Cols) {
  $WtPath = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
  if (-not $WtPath) {
    Write-Host "Windows Terminal not found. Install from Microsoft Store or winget."
    Write-Host "Fallback: Use 'pp2 logs <name>' to view logs."
    return
  }

  $ServicesToMonitor = Get-ServiceNames $Name
  if ($ServicesToMonitor.Count -eq 0) { Write-Host 'No services to monitor'; return }

  $Pwsh = Get-PwshPath
  $MaxCols = [math]::Max(1, $Cols)
  $RowCount = [int][math]::Ceiling($ServicesToMonitor.Count / $MaxCols)
  $WindowName = "lib/pp2-monit-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  $WatchLogsPath = Join-Path $Root 'lib/pp2-watch-logs.ps1'

  function Get-MonitLogArgs([string]$Svc) { @($Pwsh, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WatchLogsPath, '-ServiceName', $Svc, '-Watch') }
  function Invoke-WtCommand([string[]]$CommandArgs) {
    $WtCommandArgs = @('-w', $WindowName) + $CommandArgs
    & $WtPath @WtCommandArgs
    Start-Sleep -Milliseconds 200
  }

  $FirstPaneArgs = @('new-tab', '--title', $ServicesToMonitor[0], '--suppressApplicationTitle') + (Get-MonitLogArgs $ServicesToMonitor[0])
  Invoke-WtCommand $FirstPaneArgs

  for ($Row = 1; $Row -lt $RowCount; $Row++) {
    $ServiceIndex = $Row * $MaxCols
    $RemainingRows = $RowCount - $Row + 1
    $PaneArgs = @('split-pane', '-H', '-s', [math]::Round(($RemainingRows - 1) / $RemainingRows, 2), '--title', $ServicesToMonitor[$ServiceIndex], '--suppressApplicationTitle') + (Get-MonitLogArgs $ServicesToMonitor[$ServiceIndex])
    Invoke-WtCommand $PaneArgs
  }

  for ($Row = $RowCount - 1; $Row -ge 0; $Row--) {
    $RowStart = $Row * $MaxCols
    $ServicesInRow = [math]::Min($MaxCols, $ServicesToMonitor.Count - $RowStart)
    for ($Col = 1; $Col -lt $ServicesInRow; $Col++) {
      $ServiceIndex = $RowStart + $Col
      $RemainingCols = $ServicesInRow - $Col + 1
      $PaneArgs = @('split-pane', '-V', '-s', [math]::Round(($RemainingCols - 1) / $RemainingCols, 2), '--title', $ServicesToMonitor[$ServiceIndex], '--suppressApplicationTitle') + (Get-MonitLogArgs $ServicesToMonitor[$ServiceIndex])
      Invoke-WtCommand $PaneArgs
    }
    if ($Row -gt 0) { Invoke-WtCommand @('move-focus', 'up') }
  }

  Invoke-WtCommand @('move-focus', 'first')
  Write-Host "Opened Windows Terminal with $($ServicesToMonitor.Count) services."
}

function Show-WatchdogStatus {
  $WatchPidPath = Join-Path $RunDir 'watchdog.pid'
  if (-not (Test-Path $WatchPidPath)) { Write-Host 'watchdog not running'; return }

  $WatchPid = [int](Get-Content $WatchPidPath -Raw)
  if (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue) { Write-Host "watchdog running pid=$WatchPid" }
  else { Write-Host 'watchdog not running (stale PID file)' }
}

function Install-StartupTask([string]$EntryScriptPath) {
  $ActionDef = New-ScheduledTaskAction -Execute (Get-PwshPath) -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$EntryScriptPath`" start all"
  $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $ActionDef -Trigger $Trigger -Principal $Principal -Force | Out-Null
  Write-Host "installed startup task: $TaskName"
}

function Uninstall-StartupTask {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "uninstalled startup task: $TaskName"
}
