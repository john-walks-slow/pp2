param(
  [Parameter(Mandatory = $true)]
  [string]$Name,
  [Parameter(Mandatory = $true)]
  [string]$Root
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Private\pp2-core.ps1')
Initialize-Pp2Context -ScriptRoot $Root
Read-Pp2Config
$Service = Get-ServiceConfig $Name

if ((Get-ServiceProperty $Service 'inheritEnv' $true) -eq $false) {
  # Keep PATH and essential system vars, clear others
  $KeepVars = @('PATH', 'SYSTEMROOT', 'TEMP', 'TMP', 'HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'COMSPEC', 'PATHEXT')
  [Environment]::GetEnvironmentVariables('Process').Keys | Where-Object { $_ -notin $KeepVars } | ForEach-Object {
    [Environment]::SetEnvironmentVariable($_, $null, 'Process')
  }
}

if (Get-ServiceProperty $Service 'env') {
  foreach ($Item in (Get-ServiceProperty $Service 'env').PSObject.Properties) {
    [Environment]::SetEnvironmentVariable($Item.Name, [string]$Item.Value, 'Process')
  }
}

if (Get-ServiceProperty $Service 'workingDirectory') {
  Set-Location (Get-ServiceProperty $Service 'workingDirectory')
}

$Command = Get-ServiceProperty $Service 'command'
$RawArgs = Get-ServiceProperty $Service 'arguments' @()
# 确保始终是数组，并过滤 null/空字符串
$ServiceArgs = @($RawArgs) | Where-Object { $_ -and $_ -ne '' }

# 记录实际执行的命令到日志
$LogPath = Join-Path $script:LogDir "$Name.out.log"
$Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

if ((Get-ServiceProperty $Service 'shell' $false) -eq $true) {
  $FullCommand = "$Command $($ServiceArgs -join ' ')"
  $ActualCmd = $FullCommand
  Add-Content -Path $LogPath -Value "[$Timestamp] shell: $ActualCmd"
  & (Get-PwshPath) -NoProfile -NonInteractive -Command $FullCommand
  exit $LASTEXITCODE
}
else {
  # 直接调用：使用数组直接传递
  $ArgsStr = if ($ServiceArgs -and @($ServiceArgs).Count -gt 0) { $ServiceArgs -join ' ' } else { '' }
  $ActualCmd = "& $Command $ArgsStr"
  # 记录实际执行的命令
  Add-Content -Path $LogPath -Value "[$Timestamp] $ActualCmd"
  
  if ($ServiceArgs -and @($ServiceArgs).Count -gt 0) {
    & $Command $ServiceArgs
  }
  else {
    & $Command
  }
}

exit $LASTEXITCODE
