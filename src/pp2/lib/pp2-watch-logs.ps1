param(
  [Parameter(Mandatory = $true)]
  [string]$ServiceName,
  
  [string]$LogDir,
  
  [int]$Tail = 50,
  
  [switch]$Watch
)

$ErrorActionPreference = 'Stop'

# If LogDir not provided, detect from environment
if (-not $LogDir) {
  $Pp2Home = if ($env:PP2_HOME) { $env:PP2_HOME } else { Join-Path $HOME '.pp2' }
  $LogDir = Join-Path $Pp2Home 'logs'
}

$OutLog = Join-Path $LogDir "$ServiceName.out.log"
$ErrLog = Join-Path $LogDir "$ServiceName.err.log"

$OutColor = 'Green'
$ErrColor = 'Yellow'
$LastPos = @{}

function Read-NewContent([string]$Path, [string]$Color) {
  if (-not (Test-Path $Path)) { return }
  
  try {
    $File = Get-Item $Path
    $CurrentLen = $File.Length
    
    if ($CurrentLen -eq 0) { 
      $LastPos[$Path] = 0
      return
    }
    
    if (-not $LastPos.ContainsKey($Path)) {
      # First read: get last $Tail lines
      $Content = Get-Content $Path -Tail $Tail -ErrorAction SilentlyContinue
      foreach ($Line in $Content) {
        $Ts = Get-Date -Format 'HH:mm:ss'
        Write-Host "[$Ts] " -ForegroundColor $Color -NoNewline
        Write-Host $Line
      }
      $LastPos[$Path] = $CurrentLen
    }
    elseif ($CurrentLen -gt $LastPos[$Path]) {
      # New content added - read from last position
      $FileStream = [System.IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite')
      $FileStream.Seek($LastPos[$Path], 'Begin') | Out-Null
      $Reader = [System.IO.StreamReader]::new($FileStream)
      while (-not $Reader.EndOfStream) {
        $Line = $Reader.ReadLine()
        $Ts = Get-Date -Format 'HH:mm:ss'
        Write-Host "[$Ts] " -ForegroundColor $Color -NoNewline
        Write-Host $Line
      }
      $LastPos[$Path] = $FileStream.Position
      $Reader.Close()
      $FileStream.Close()
    }
    elseif ($CurrentLen -lt $LastPos[$Path]) {
      # File was truncated/rotated - reset
      $LastPos[$Path] = 0
    }
  }
  catch { Write-Debug "Failed to read $Path : $_" }
}

function Show-Static {
  Write-Host "Logs for $ServiceName (green=stdout, yellow=stderr)" -ForegroundColor Cyan
  
  if (-not (Test-Path $OutLog) -and -not (Test-Path $ErrLog)) {
    Write-Host "No log files found"
    return
  }
  
  Read-NewContent $OutLog $OutColor
  Read-NewContent $ErrLog $ErrColor
}

function Show-Watch {
  Write-Host "$(Get-Date -Format 'HH:mm:ss') Logs for $ServiceName (Ctrl+C to exit)" -ForegroundColor Cyan
  Write-Host "green=stdout  yellow=stderr" -ForegroundColor Gray
  
  if (-not (Test-Path $OutLog) -and -not (Test-Path $ErrLog)) {
    Write-Host "No log files found"
    return
  }
  
  # Initial read
  Read-NewContent $OutLog $OutColor
  Read-NewContent $ErrLog $ErrColor
  
  # Continuous monitoring
  while ($true) {
    Start-Sleep -Milliseconds 200
    Read-NewContent $OutLog $OutColor
    Read-NewContent $ErrLog $ErrColor
  }
}

if ($Watch) { Show-Watch }
else { Show-Static }