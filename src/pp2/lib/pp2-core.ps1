Set-StrictMode -Version Latest
$script:IsWindows = $env:OS -eq 'Windows_NT'

function Initialize-Pp2Context {
  param([Parameter(Mandatory = $true)][string]$ScriptRoot)

  $script:Root = $ScriptRoot
  $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
  $script:ConfigPath = Join-Path $script:Root 'services.json'
  $script:RunDir = Join-Path $script:Root 'run'
  $script:LogDir = Join-Path $script:Root 'logs'
  $script:TaskName = 'pp2 Startup'

  New-Item -ItemType Directory -Force -Path $script:RunDir, $script:LogDir | Out-Null

  # Auto-create default services.json if not exists
  if (-not (Test-Path $script:ConfigPath)) {
    # Create minimal valid config structure
    $DefaultJson = '{"settings":{},"services":{}}'
    Set-Content -Path $script:ConfigPath -Value $DefaultJson -Encoding UTF8
    $script:Config = $DefaultJson | ConvertFrom-Json
  } else {
    # Handle empty file gracefully
    $ConfigContent = (Get-Content $script:ConfigPath -Raw -ErrorAction SilentlyContinue).Trim()
    if ([string]::IsNullOrWhiteSpace($ConfigContent)) {
      $script:Config = '{"settings":{},"services":{}}' | ConvertFrom-Json
    } else {
      $script:Config = $ConfigContent | ConvertFrom-Json
    }
  }

  # Ensure config has required structure (handle edge cases from JSON parsing)
  if (-not $script:Config.PSObject.Properties['settings']) {
    $script:Config | Add-Member -MemberType NoteProperty -Name 'settings' -Value ([PSCustomObject]@{}) -Force
  }
  if (-not $script:Config.PSObject.Properties['services']) {
    $script:Config | Add-Member -MemberType NoteProperty -Name 'services' -Value ([PSCustomObject]@{}) -Force
  }
  # Ensure services is PSCustomObject not Hashtable
  if ($script:Config.services -is [System.Collections.Hashtable]) {
    $script:Config.services = [PSCustomObject]$script:Config.services
  }
}

function Get-Setting([string]$Name, $Default) {
  $Settings = $script:Config.settings
  if (-not $Settings) { return $Default }
  $Property = $Settings.PSObject.Properties[$Name]
  if ($Property) { return $Property.Value }
  return $Default
}

function Test-EnabledService([string]$ServiceName) {
  $Service = Get-ServiceConfig $ServiceName
  return (Get-ServiceProperty $Service 'enable' $true) -eq $true
}

function Get-ServiceNames([string[]]$Name = @('all')) {
  $ServicesObj = $script:Config.services
  
  $RequestedNames = @($Name | Where-Object { $_ -ne 'all' })
  if ($RequestedNames.Count -eq 0) {
    if ($null -eq $ServicesObj) { return @() }
    $Props = $ServicesObj.PSObject.Properties
    if ($null -eq $Props) { return @() }
    $PropCount = @($Props).Count
    if ($PropCount -eq 0) { return @() }
    return @($Props.Name | Where-Object { Test-EnabledService $_ })
  }
  
  foreach ($ServiceName in $RequestedNames) {
    if ($null -eq $ServicesObj -or $null -eq $ServicesObj.PSObject.Properties[$ServiceName]) { 
      throw "Unknown service: $ServiceName" 
    }
    if (-not (Test-EnabledService $ServiceName)) {
      throw "Unknown service: $ServiceName"
    }
  }
  return $RequestedNames
}

function Get-ServiceConfig([string]$ServiceName) {
  $Property = $script:Config.services.PSObject.Properties[$ServiceName]
  if (-not $Property) { throw "Unknown service: $ServiceName" }
  return $Property.Value
}

function Get-ServiceProperty([pscustomobject]$Service, [string]$PropertyName, $Default = $null) {
  $Property = $Service.PSObject.Properties[$PropertyName]
  if ($Property) { return $Property.Value }
  return $Default
}

function Open-ConfigFile {
  <#
  .SYNOPSIS
    Open the services.json config file in default editor
  #>
  $Editor = $env:EDITOR
  if (-not $Editor) {
    # Try common editors on Windows
    $Editor = (Get-Command code.cmd -ErrorAction SilentlyContinue).Source
    if (-not $Editor) { $Editor = (Get-Command notepad.exe -ErrorAction SilentlyContinue).Source }
  }
  
  if (-not $Editor) {
    Write-Host "No editor found. Set EDITOR env var or install VS Code."
    Write-Host "Config path: $script:ConfigPath"
    return
  }

  Write-Host "Opening config: $script:ConfigPath"
  & $Editor $script:ConfigPath
}

function Test-IsElevated {
  $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
  return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PwshPath {
  $Pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
  if ($Pwsh) { return $Pwsh }
  $Pwsh = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
  if ($Pwsh) { return $Pwsh }
  throw "PowerShell executable not found. Ensure PowerShell 7+ is installed."
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
  if (-not $IsWindows) { return $null }
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

function Get-DependencyLayers([string[]]$ServiceNames, [switch]$Reverse) {
  <#
  .SYNOPSIS
    Group services into dependency layers for parallel execution
    
  .DESCRIPTION
    Returns array of layers (each layer is array of service names).
    For start: layer 0 = no dependencies, layer 1 = depends on layer 0, etc.
    For stop: reverse order (dependents first, then dependencies)
    
  .PARAMETER Reverse
    If true, returns layers in reverse order (for stop: dependents first)
  #>
  $ServiceNames = @($ServiceNames)  # Ensure array
  $IsReverse = $Reverse.IsPresent
  if ($ServiceNames.Count -eq 0) { return @() }
  if ($ServiceNames.Count -eq 1) { return @(@($ServiceNames)) }

  $ServicesObj = $script:Config.services
  $DependsOn = @{}  # Service -> its dependencies
  $DependentsOf = @{}  # Service -> services that depend on it
  
  # Initialize maps
  foreach ($ServiceName in $ServiceNames) {
    $DependsOn[$ServiceName] = @()
    $DependentsOf[$ServiceName] = @()
  }
  
  # Build dependency graph
  foreach ($ServiceName in $ServiceNames) {
    $Service = Get-ServiceConfig $ServiceName
    foreach ($Dep in @(Get-ServiceProperty $Service 'dependsOn' @()) | Where-Object { $_ }) {
      if ($Dep -in $ServiceNames) {
        $DependsOn[$ServiceName] += $Dep
        $DependentsOf[$Dep] += $ServiceName
      }
    }
  }

  # Build layers using topological sort
  $Layers = @()
  $Remaining = @($ServiceNames)
  
  while ($Remaining.Count -gt 0) {
    # Find services with no unresolved dependencies (or no dependents for reverse)
    $Layer = @()
    $PrevLayer = if ($Layers.Count -gt 0) { @($Layers[-1]) } else { @() }
    foreach ($ServiceName in @($Remaining)) {
      if ($IsReverse) {
        # For stop: no dependents remaining in this batch
        $UnresolvedDependents = @(@($DependentsOf[$ServiceName]) | Where-Object { $_ -in $Remaining -and $_ -notin $PrevLayer })
        if ($UnresolvedDependents.Count -eq 0) { $Layer += $ServiceName }
      } else {
        # For start: no dependencies remaining in this batch
        $UnresolvedDeps = @(@($DependsOn[$ServiceName]) | Where-Object { $_ -in $Remaining -and $_ -notin $PrevLayer })
        if ($UnresolvedDeps.Count -eq 0) { $Layer += $ServiceName }
      }
    }
    
    if ($Layer.Count -eq 0) {
      Write-Warning "Circular dependency detected among: $($Remaining -join ', ')"
      $Layers += @($Remaining)
      break
    }
    
    $Layers += @($Layer)
    $Remaining = @($Remaining | Where-Object { $_ -notin $Layer })
  }
  
  return $Layers
}

function Get-StopOrder([string[]]$ServiceNames) {
  # Legacy function - returns flat array for compatibility
  $Layers = Get-DependencyLayers $ServiceNames -Reverse
  return $Layers | ForEach-Object { $_ }  # Flatten
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
    $ShutdownWait = [int](Get-Setting 'shutdownWaitDelay' 2000)
    Start-Sleep -Milliseconds $ShutdownWait
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
  $ServiceNames = @($ServiceNames)  # Ensure array
  $Layers = Get-DependencyLayers $ServiceNames -Reverse
  foreach ($Layer in $Layers) {
    $Layer = @($Layer)  # Ensure layer is array
    if ($Layer.Count -eq 1) {
      Stop-One $Layer[0]
    } else {
      # Parallel stop for same layer
      $Jobs = $Layer | ForEach-Object {
        Start-ThreadJob -ScriptBlock {
          param($ServiceName, $ModuleRoot, $Root, $ConfigJson)
          $script:ModuleRoot = $ModuleRoot
          $script:Root = $Root
          $script:Config = $ConfigJson | ConvertFrom-Json
          $script:ConfigPath = Join-Path $Root 'services.json'
          $script:RunDir = Join-Path $Root 'run'
          $script:LogDir = Join-Path $Root 'logs'
          # Import Stop-One and its dependencies
          . (Join-Path $ModuleRoot 'lib/pp2-core.ps1')
          Stop-One $ServiceName
        } -ArgumentList $_, $script:ModuleRoot, $script:Root, ($script:Config | ConvertTo-Json -Depth 10)
      }
      $Jobs | Wait-Job | Receive-Job
      $Jobs | Remove-Job
    }
  }
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

  $Process = Start-Process -FilePath (Get-PwshPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ModuleRoot 'lib/pp2-watchdog.ps1'), '-Interval', $Interval, '-Root', $Root) -WindowStyle Hidden -PassThru
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

function Start-WatchdogIfNeeded([string[]]$Name = @('all')) {
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

  $StartArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ModuleRoot 'lib/pp2-run-service.ps1'), '-Name', $ServiceName, '-Root', $Root)
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

function Start-Many([string[]]$ServiceNames, [bool]$Force) {
  $ServiceNames = @($ServiceNames)  # Ensure array
  $Layers = Get-DependencyLayers $ServiceNames
  foreach ($Layer in $Layers) {
    $Layer = @($Layer)  # Ensure layer is array
    if ($Layer.Count -eq 1) {
      Start-One $Layer[0] $Force | Out-Null
    } else {
      # Parallel start for same layer
      $Jobs = $Layer | ForEach-Object {
        Start-ThreadJob -ScriptBlock {
          param($ServiceName, $Force, $ModuleRoot, $Root, $ConfigJson)
          $script:ModuleRoot = $ModuleRoot
          $script:Root = $Root
          $script:Config = $ConfigJson | ConvertFrom-Json
          $script:ConfigPath = Join-Path $Root 'services.json'
          $script:RunDir = Join-Path $Root 'run'
          $script:LogDir = Join-Path $Root 'logs'
          # Import Start-One and its dependencies
          . (Join-Path $ModuleRoot 'lib/pp2-core.ps1')
          Start-One $ServiceName $Force | Out-Null
        } -ArgumentList $_, $Force, $script:ModuleRoot, $script:Root, ($script:Config | ConvertTo-Json -Depth 10)
      }
      $Jobs | Wait-Job | Receive-Job
      $Jobs | Remove-Job
    }
  }
}

function Show-Status([string[]]$Name = @('all'), [string]$Format = 'table') {
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

function Watch-Status([string[]]$Name, [string]$Format, [int]$Interval) {
  while ($true) {
    Clear-Host
    Write-Host "$(Get-Date -Format 'HH:mm:ss') Service Status (Ctrl+C to exit)"
    Show-Status $Name $Format
    Start-Sleep -Seconds $Interval
  }
}

function Show-Logs([string]$ServiceName, [int]$Tail, [bool]$WatchMode) {
  $WatchLogsPath = Join-Path $script:ModuleRoot 'lib/pp2-watch-logs.ps1'
  if ($WatchMode) { & $WatchLogsPath -ServiceName $ServiceName -LogDir $script:LogDir -Tail $Tail -Watch }
  else { & $WatchLogsPath -ServiceName $ServiceName -LogDir $script:LogDir -Tail $Tail }
}

function Show-Monit([string[]]$Name, [int]$Cols, [switch]$Interactive) {
  $ServicesToMonitor = Get-ServiceNames $Name
  if ($ServicesToMonitor.Count -eq 0) { Write-Host 'No services to monitor'; return }

  # Interactive service selection (only when no Name arg specified)
  if ($Interactive) {
    $allServices = $ServicesToMonitor
    if ($allServices.Count -eq 1) {
      Write-Host "Only one service available: $($allServices[0])"
    } else {
      $idx = 0
      $allServices | ForEach-Object { Write-Host "  [$($idx+1)] $_"; $idx++ }
      Write-Host ''
      $input = Read-Host "Select services (comma-separated numbers, or * for all)"
      if ($input -eq '*' -or [string]::IsNullOrWhiteSpace($input)) { $ServicesToMonitor = $allServices }
      else {
        $parsed = @()
        $invalid = @()
        foreach ($token in ($input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })) {
          $num = 0
          if ([int]::TryParse($token, [ref]$num)) {
            if ($num -ge 1 -and $num -le $allServices.Count) { $parsed += $allServices[$num - 1] }
            else { $invalid += $token }
          } else { $invalid += $token }
        }
        if ($invalid.Count -gt 0) { Write-Host "Ignored invalid input: $($invalid -join ', ')" -ForegroundColor Yellow }
        $ServicesToMonitor = $parsed
        if ($ServicesToMonitor.Count -eq 0) { Write-Host 'No services selected'; return }
      }
    }
  }

  Show-MonitDashboard -Services $ServicesToMonitor -Cols $Cols
}

function Show-MonitDashboard {
  param(
    [Parameter(Mandatory)][string[]]$Services,
    [int]$Cols = 3
  )

  $LogDir = $script:LogDir
  $ServiceCount = $Services.Count
  $MaxCols = [Math]::Max(1, [Math]::Min($Cols, $ServiceCount))

  # Ctrl+C handler
  $script:monitExit = $false
  $cancelHandler = [ConsoleCancelEventHandler]{ param($s,$e) $e.Cancel = $true; $script:monitExit = $true }
  [Console]::CancelKeyPress += $cancelHandler

  # Per-service state: file positions + circular buffer
  $state = @{}
  foreach ($svc in $Services) {
    $state[$svc] = @{
      outPos = 0; errPos = 0
      lines = [System.Collections.Generic.List[string]]::new()
      colors = [System.Collections.Generic.List[ConsoleColor]]::new()
    }
  }

  $origVis = try { [Console]::CursorVisible } catch { $true }
  $origBg = [Console]::BackgroundColor

  try {
    try { [Console]::CursorVisible = $false } catch { }
    Clear-Host

    while (-not $script:monitExit) {
      $w = [Console]::WindowWidth
      $h = [Console]::WindowHeight
      $rows = [Math]::Ceiling($ServiceCount / $MaxCols)
      $cellW = [Math]::Max(10, [Math]::Floor($w / $MaxCols))
      $cellH = [Math]::Max(2, [Math]::Floor(($h - 1) / $rows))
      $contentH = $cellH - 1

      # Read new log content for each service
      foreach ($svc in $Services) {
        $s = $state[$svc]

        foreach ($stream in @(
          @{ path = Join-Path $LogDir "$svc.out.log"; posRef = 'outPos'; color = [ConsoleColor]::Green },
          @{ path = Join-Path $LogDir "$svc.err.log"; posRef = 'errPos'; color = [ConsoleColor]::Yellow }
        )) {
          try {
            $fs = [System.IO.FileStream]::new($stream.path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $len = $fs.Length
            $pos = $s[$stream.posRef]
            if ($len -gt $pos) {
              $null = $fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
              $reader = [System.IO.StreamReader]::new($fs)
              while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                $s.lines.Add($line)
                $s.colors.Add($stream.color)
              }
              $s[$stream.posRef] = $fs.Position
              $reader.Close()
            } elseif ($len -lt $pos) {
              $s[$stream.posRef] = 0
              $fs.Close()
            } else {
              $fs.Close()
            }
          } catch [System.IO.FileNotFoundException] { }
          catch { Write-Debug "monit read $($stream.path): $_" }
        }

        # Trim buffer to avoid unbounded growth
        if ($s.lines.Count -gt 1000) {
          $s.lines.RemoveRange(0, $s.lines.Count - 1000)
          $s.colors.RemoveRange(0, $s.colors.Count - 1000)
        }
      }

      # Draw grid (iterate full rows×cols to clean unused cells)
      for ($ri = 0; $ri -lt $rows; $ri++) {
        for ($ci = 0; $ci -lt $MaxCols; $ci++) {
          $i = $ri * $MaxCols + $ci
          $svc = if ($i -lt $ServiceCount) { $Services[$i] } else { $null }
          $x = $ci * $cellW
          $y = $ri * $cellH

          # Header
          [Console]::SetCursorPosition($x, $y)
          if ($svc) {
            $header = " $svc "
            $header = $header.PadRight($cellW - 1, '─')
            if ($header.Length -gt $cellW) { $header = $header.Substring(0, $cellW) }
            [Console]::ForegroundColor = 'Cyan'
            [Console]::BackgroundColor = 'DarkBlue'
          } else {
            $header = ''.PadRight($cellW)
            [Console]::ForegroundColor = 'DarkGray'
            [Console]::BackgroundColor = $origBg
          }
          [Console]::Write($header)
          [Console]::BackgroundColor = $origBg

          # Content
          $s = if ($svc) { $state[$svc] } else { $null }
          $bufCount = if ($s) { $s.lines.Count } else { 0 }
          $startIdx = [Math]::Max(0, $bufCount - $contentH)

          for ($li = 0; $li -lt $contentH; $li++) {
            [Console]::SetCursorPosition($x, $y + 1 + $li)
            $bi = $startIdx + $li
            if ($s -and $bi -lt $bufCount) {
              $text = $s.lines[$bi]
              if ($text.Length -gt $cellW) { $text = $text.Substring(0, $cellW - 1) + '…' }
              [Console]::ForegroundColor = $s.colors[$bi]
              [Console]::Write($text.PadRight($cellW))
            } else {
              [Console]::Write(''.PadRight($cellW))
            }
          }
        }
      }

      # Status bar
      [Console]::SetCursorPosition(0, $h - 1)
      [Console]::ForegroundColor = 'DarkGray'
      $status = " pp2-monit | $ServiceCount services | Ctrl+C to exit ".PadRight($w, '─')
      if ($status.Length -gt $w) { $status = $status.Substring(0, $w) }
      [Console]::Write($status)

      Start-Sleep -Milliseconds 200
    }
  }
  finally {
    [Console]::CancelKeyPress -= $cancelHandler
    try { [Console]::CursorVisible = $origVis } catch { }
    [Console]::ResetColor()
    Write-Host "pp2-monit: exited" -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 200
    Clear-Host
  }
}

function Show-WatchdogStatus {
  $WatchPidPath = Join-Path $RunDir 'watchdog.pid'
  if (-not (Test-Path $WatchPidPath)) { Write-Host 'watchdog not running'; return }

  $WatchPid = [int](Get-Content $WatchPidPath -Raw)
  if (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue) { Write-Host "watchdog running pid=$WatchPid" }
  else { Write-Host 'watchdog not running (stale PID file)' }
}

function Install-StartupTask([string]$ModuleManifestPath, [string]$StateRoot) {
  $Command = "& { `$env:PP2_HOME = $(ConvertTo-PwshLiteral $StateRoot); Import-Module -Name $(ConvertTo-PwshLiteral $ModuleManifestPath) -Force; pp2 start all }"
  $ActionDef = New-ScheduledTaskAction -Execute (Get-PwshPath) -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$Command`""
  $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $ActionDef -Trigger $Trigger -Principal $Principal -Force | Out-Null
  Write-Host "installed startup task: $TaskName"
}

function Uninstall-StartupTask {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "uninstalled startup task: $TaskName"
}
