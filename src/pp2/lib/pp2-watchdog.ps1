param(
  [int]$Interval = 60,
  [Parameter(Mandatory = $true)]
  [string]$Root,
  # Not named $Config: this script's scope also holds pp2-core's $script:Config,
  # the parsed configuration. A parameter of that name is the same variable, and
  # a parameter binding outranks an assignment -- so $script:Config kept holding
  # this path string, Read-Pp2Config's assignment never took effect, and
  # $Config.services threw PropertyNotFoundException.
  #
  # Where that throw lands is what made this so quiet. The foreach enumerates
  # $Config.services... in its own header, so the exception aborts the loop body
  # before the first service is looked at -- and the loop keeps iterating, because
  # the throw is outside the foreach. The watchdog stayed alive and its PID file
  # stayed valid, so nothing looked wrong, but not one service was ever checked:
  # auto-restart was dead for all of them. The only trace was on the hidden
  # process's stderr, which goes nowhere.
  [string]$ConfigPath
)

$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Private\pp2-core.ps1')
Initialize-Pp2Context -ScriptRoot $Root
if ($ConfigPath) { $script:ConfigPath = $ConfigPath }
Read-Pp2Config

$DefaultInterval = [int](Get-Setting 'watchdogInterval' 60)
if (-not $Interval) { $Interval = $DefaultInterval }

$WatchPidPath = Join-Path $RunDir 'watchdog.pid'
$LogPath = Join-Path $LogDir 'watchdog.log'
$ChildProcesses = @{}

function Write-WatchdogLog([string]$Message) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Add-Content $LogPath
}

function Invoke-ServiceRestart([string]$ServiceName) {
  $ModuleManifestPath = Join-Path $ModuleRoot 'pp2.psd1'
  # PP2_HOME and -Config are both propagated so a service managed from a
  # non-default root or explicit config file restarts against the same state.
  $Command = "& { `$env:PP2_HOME = $(ConvertTo-PwshLiteral $Root); Import-Module -Name $(ConvertTo-PwshLiteral $ModuleManifestPath) -Force; pp2 internal-start $(ConvertTo-PwshLiteral $ServiceName) -Config $(ConvertTo-PwshLiteral $script:ConfigPath) }"
  $Process = Start-Process -FilePath (Get-PwshPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $Command) -PassThru -WindowStyle Hidden
  $ChildProcesses[$Process.Id] = $ServiceName

  # Wait for the restart to actually finish instead of assuming a fixed
  # duration: a cold pwsh start plus module import can take tens of seconds.
  # Killing too early leaves the PID file stale and the service down.
  $TimeoutSec = [int](Get-Setting 'restartTimeout' 120)
  if (-not $Process.WaitForExit($TimeoutSec * 1000)) {
    $Process.Kill()
    Write-WatchdogLog "WARNING: restart process pid=$($Process.Id) didn't exit within ${TimeoutSec}s, killed"
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
    
    # Skip disabled services
    if (-not (Get-ServiceProperty $Service 'enable' $true)) { continue }

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
      # Healthy. Once it has held up through the grace period, forget the
      # crash history so a later, unrelated crash gets a fresh retry budget.
      if (Test-ServiceStability $ServiceName) {
        if (Test-Path (Get-RetryPath $ServiceName)) {
          Write-WatchdogLog "$ServiceName stable, resetting retry counter"
        }
        Reset-RetryState $ServiceName
      }
      continue
    }

    # Not running: drop the stability timer so the next successful start has
    # to earn its grace period again.
    Clear-ServiceStability $ServiceName

    $Retries = if (Test-Path $RetryPath) { [int](Get-Content $RetryPath -Raw) } else { 0 }
    $MaxRetries = [int](Get-ServiceProperty $Service 'maxRetries' 3)

    if ($Retries -ge $MaxRetries) {
      Write-WatchdogLog "max retries ($MaxRetries) reached for $ServiceName, giving up"
      Remove-ServiceState $ServiceName
      Clear-RestartChildren $ServiceName
      continue
    }

    # Back off before the first retry, then exponentially: 4s, 8s, 16s ... capped at 2min.
    $RetryDelay = [math]::Min(4 * [math]::Pow(2, $Retries), 120)
    Write-WatchdogLog "$ServiceName crashed, waiting $RetryDelay s before retry $($Retries + 1)/$MaxRetries"
    Start-Sleep -Seconds $RetryDelay

    # Record the attempt before starting it: Start-One must not clear the
    # counter, otherwise maxRetries can never be reached.
    Set-Content -Path $RetryPath -Value ($Retries + 1) -NoNewline
    Write-WatchdogLog "auto-restarting $ServiceName..."
    Invoke-ServiceRestart $ServiceName

    if (-not (Test-Path $PidPath)) {
      Write-WatchdogLog "restart failed for $ServiceName (no PID file created)"
      continue
    }

    $NewPid = [int](Get-Content $PidPath -Raw)
    $NewProcess = Get-Process -Id $NewPid -ErrorAction SilentlyContinue
    if (-not $NewProcess) {
      Write-WatchdogLog "restart failed for $ServiceName (no process found for pid=$NewPid)"
    }
    elseif ($NewPid -ne $RecordedPid) {
      Write-WatchdogLog "restart succeeded for $ServiceName new_pid=$NewPid"
    }
    else {
      Write-WatchdogLog "WARNING: PID file not updated after restart (still shows dead pid=$RecordedPid)"
    }
  }

  Remove-ExitedChildren
}
