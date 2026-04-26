param(
    [string]$Port = "19998"
)

# Ephemeral launcher pattern: start a background process and exit immediately
# This simulates services like cloudflared tunnel run, process managers, etc.

$LogDir = Join-Path $PSScriptRoot "..\logs"
$OutLog = Join-Path $LogDir "test-ephemeral-bg.out.log"
$ErrLog = Join-Path $LogDir "test-ephemeral-bg.err.log"

# Start background process that will persist after this script exits
$BgScript = @'
param([string]$Port)
$Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, [int]$Port)
$Listener.Start()
Write-Host "ephemeral-bg listening on port $Port"
while ($true) {
    Start-Sleep -Seconds 60
}
'@

$BgScriptPath = Join-Path $PSScriptRoot "test-ephemeral-bg.ps1"
$BgScript | Set-Content -Path $BgScriptPath -Encoding UTF8

# Launch background process
$Process = Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-File", $BgScriptPath, "-Port", $Port) -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -PassThru

Write-Host "ephemeral-launcher: started background process pid=$($Process.Id) on port $Port"
Write-Host "ephemeral-launcher: exiting now (launcher pattern)"

# Save the PID for shutdown script to use
$PidFile = Join-Path $PSScriptRoot "..\run\test-ephemeral-bg.pid"
Set-Content -Path $PidFile -Value $Process.Id -NoNewline

# Exit immediately - this is the ephemeral pattern
exit 0