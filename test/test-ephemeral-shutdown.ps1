# Shutdown script for ephemeral service
# This is called by pp2 stop when ephemeral=true

$PidFile = Join-Path $PSScriptRoot "..\run\test-ephemeral-bg.pid"

if (Test-Path $PidFile) {
    $Pid = [int](Get-Content $PidFile -Raw)
    $Process = Get-Process -Id $Pid -ErrorAction SilentlyContinue
    
    if ($Process) {
        Write-Host "ephemeral-shutdown: stopping background process pid=$Pid"
        Stop-Process -Id $Pid -Force
    }
    
    Remove-Item $PidFile -ErrorAction SilentlyContinue
}

# Clean up the generated background script
$BgScript = Join-Path $PSScriptRoot "test-ephemeral-bg.ps1"
Remove-Item $BgScript -ErrorAction SilentlyContinue

Write-Host "ephemeral-shutdown: complete"
exit 0