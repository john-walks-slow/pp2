<#
Test service - prints environment, args, cwd for verification
#>
param(
    [string]$TestArg1 = '',
    [string]$TestArg2 = '',
    [string]$TestArg3 = '',
    [int]$Port = 0
)

$result = @{
    args = @($TestArg1, $TestArg2, $TestArg3) | Where-Object { $_ }
    env = [Environment]::GetEnvironmentVariables('Process')
    cwd = $PWD.Path
    pid = $PID
    port = $Port
}

Write-Host "=== TEST SERVICE START ==="
Write-Host ($result | ConvertTo-Json -Depth 1)
Write-Host "=== TEST SERVICE END ==="

if ($Port -gt 0) {
    # HTTP listener mode
    $Listener = [System.Net.HttpListener]::new()
    $Listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $Listener.Start()
    Write-Host "Listening on port $Port for 10 seconds..."
    
    $EndTime = (Get-Date).AddSeconds(10)
    while ($Listener.IsListening -and (Get-Date) -lt $EndTime) {
        $Task = $Listener.GetContextAsync()
        if (-not $Task.Wait(1000)) { continue }
        $Ctx = $Task.Result
        $Resp = $Ctx.Response
        $Body = [Text.Encoding]::UTF8.GetBytes("OK from test-service.ps1 port=$Port pid=$PID")
        $Resp.ContentLength64 = $Body.Length
        $Resp.OutputStream.Write($Body, 0, $Body.Length)
        $Resp.Close()
    }
    $Listener.Stop()
} else {
    # Simple run mode - short duration for testing
    Write-Host "Running for 3 seconds..."
    Start-Sleep -Seconds 3
}