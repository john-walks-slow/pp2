param(
  [int]$Interval = 60
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'lib\pp2-core.ps1')
Initialize-Pw2Context -ScriptRoot $Root

$WatchPidPath = Join-Path $RunDir 'watchdog.pid'
$LogPath = Join-Path $LogDir 'watchdog.log'
$ChildProcesses = @{}

function Write-WatchdogLog([string]$Message) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Add-Content $LogPath
}

function Invoke-ServiceRestart([string]$ServiceName) {
  $Pw2Path = Join-Path $Root 'pp2.ps1'
  $Process = Start-Process -FilePath (Get-PwshPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Pw2Path, 'internal-start', $ServiceName) -PassThru -WindowStyle Hidden
  $ChildProcesses[$Process.Id] = $ServiceName

  Start-Sleep -Seconds 3
  $Process.WaitForExit(5000)
  if (-not $Process.HasExited) {
    $Process.Kill()
    Write-WatchdogLog "WARNING: restart process pid=$($Process.Id) didn't exit, killed"
  }
  $ChildProcesses.Remove($Process.Id)
}

function Clear-RestartChildren([string]$ServiceName) {
  foreach ($ChildPid in @($ChildProcesses.Keys)) {
    if ($ChildProcesses[$ChildPid] -ne $ServiceName) { continue }

    $Child = Get-Process -Id $ChildPid -ErrorAction SilentlyContinue
    if ($Child -and -not $Child.HasExited) {
      $Child.Kill()
      Write-WatchdogLog "killed orphan restart process pid=$ChildPid"
    }
    $ChildProcesses.Remove($ChildPid)
  }
}

function Remove-ExitedChildren {
  foreach ($ChildPid in @($ChildProcesses.Keys)) {
    $Child = Get-Process -Id $ChildPid -ErrorAction SilentlyContinue
    if (-not $Child -or $Child.HasExited) { $ChildProcesses.Remove($ChildPid) }
  }
}

Set-Content -Path $WatchPidPath -Value $PID -NoNewline
Write-WatchdogLog "watchdog started pid=$PID interval=$Interval"

while ($true) {
  Start-Sleep -Seconds $Interval

  foreach ($ServiceName in $Config.services.PSObject.Properties.Name) {
    $Service = Get-ServiceConfig $ServiceName
    
    # Skip ephemeral services (they manage other processes, launcher pattern)
    $IsEphemeral = (Get-ServiceProperty $Service 'ephemeral' $false) -eq $true
    if ($IsEphemeral) {
      # Verify ephemeral service has PID file (indicates "running" state)
      $PidPath = Get-PidPath $ServiceName
      if (Test-Path $PidPath) {
        $PidContent = (Get-Content $PidPath -Raw).Trim()
        if ($PidContent -eq 'ephemeral') {
          # Ephemeral service is running, no process monitoring needed
          continue
        }
      }
      # No PID file means stopped, skip monitoring
      continue
    }
    
    if (-not (Get-ServiceProperty $Service 'autoRestart' $false)) { continue }

    $PidPath = Get-PidPath $ServiceName
    if (-not (Test-Path $PidPath)) { continue }

    $RecordedPid = [int](Get-Content $PidPath -Raw)
    $Process = Get-Process -Id $RecordedPid -ErrorAction SilentlyContinue
    $RetryPath = Get-RetryPath $ServiceName

    if ($Process) {
      if (Test-Path $RetryPath) {
        Remove-Item $RetryPath -ErrorAction SilentlyContinue
        Write-WatchdogLog "$ServiceName recovered, retry counter cleared"
      }
      continue
    }

    $Retries = if (Test-Path $RetryPath) { [int](Get-Content $RetryPath -Raw) } else { 0 }
    $MaxRetries = [int](Get-ServiceProperty $Service 'maxRetries' 3)

    if ($Retries -ge $MaxRetries) {
      Write-WatchdogLog "max retries ($MaxRetries) reached for $ServiceName, giving up"
      Remove-ServiceState $ServiceName
      Clear-RestartChildren $ServiceName
      continue
    }

    $RetryDelay = [math]::Min(4 * [math]::Pow(2, $Retries), 120)
    Write-WatchdogLog "$ServiceName crashed, waiting $RetryDelay s before retry $($Retries + 1)/$MaxRetries"
    Start-Sleep -Seconds $RetryDelay

    Set-Content -Path $RetryPath -Value ($Retries + 1) -NoNewline
    Write-WatchdogLog "auto-restarting $ServiceName..."
    Invoke-ServiceRestart $ServiceName

    if (-not (Test-Path $PidPath)) {
      Write-WatchdogLog "restart failed for $ServiceName (no PID file created)"
      continue
    }

    $NewPid = [int](Get-Content $PidPath -Raw)
    $NewProcess = Get-Process -Id $NewPid -ErrorAction SilentlyContinue
    if ($NewProcess -and $NewPid -ne $RecordedPid) {
      Remove-Item $RetryPath -ErrorAction SilentlyContinue
      Write-WatchdogLog "restart succeeded for $ServiceName new_pid=$NewPid"
    }
    elseif ($NewPid -eq $RecordedPid) {
      Write-WatchdogLog "WARNING: PID file not updated after restart (still shows dead pid=$RecordedPid)"
    }
    else {
      Write-WatchdogLog "restart failed for $ServiceName (no process found for pid=$NewPid)"
    }
  }

  Remove-ExitedChildren
}
