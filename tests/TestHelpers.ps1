<#
.SYNOPSIS
    Shared test helpers for the pp2 module test suite.

.DESCRIPTION
    Every test runs against a throwaway PP2_HOME so that the developer's real
    ~/.pp2 state (PID files, logs, running services) is never touched.
#>

# Resolve the repository layout from this file's own location rather than
# from $PSScriptRoot, which refers to whichever file dot-sourced us.
$script:Pp2TestsRoot = Split-Path -Parent $PSCommandPath
$script:Pp2ModuleRoot = Join-Path (Split-Path -Parent $script:Pp2TestsRoot) 'src\pp2'

function Get-Pp2ModuleRoot { $script:Pp2ModuleRoot }
function Get-Pp2TestsRoot { $script:Pp2TestsRoot }

# `pwsh -File` runs everything in script scope, so dot-sourcing this file from
# another script leaves the helpers invisible. Use the global scope so they are
# available both to Pester's BeforeAll and to ad-hoc one-off scripts.
function script:New-Pp2TestHome { ... }


function New-Pp2TestHome {
    <#
    .SYNOPSIS
        Create an isolated pp2 state root and point PP2_HOME at it.

    .DESCRIPTION
        The module caches its parsed config in $script:ConfigLoaded, so a
        fresh state root would otherwise inherit whatever was last read in
        this process. Forcing a re-import drops that cache. The re-import is
        a no-op when the module is already the freshly loaded copy.
    #>
    param([hashtable]$Services = @{}, [hashtable]$Settings = @{})

    if (-not (Get-Module pp2)) {
        Import-Module (Join-Path (Get-Pp2ModuleRoot) 'pp2.psd1') -Force -ErrorAction Stop
    }

    $Home_ = Join-Path ([IO.Path]::GetTempPath()) "pp2-test-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    New-Item -ItemType Directory -Path $Home_ -Force | Out-Null

    $Config = [ordered]@{
        settings = [ordered]@{ startupVerifyWait = 500; portCheckTimeout = 300; watchdogInterval = 2 }
        services = [ordered]@{}
    }
    foreach ($Key in $Settings.Keys) { $Config.settings[$Key] = $Settings[$Key] }
    foreach ($Key in $Services.Keys) { $Config.services[$Key] = $Services[$Key] }

    $Config | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $Home_ 'services.json') -Encoding UTF8
    $env:PP2_HOME = $Home_
    return $Home_
}

function Remove-Pp2TestHome {
    param([string]$Path)
    if (-not $Path) { return }

    # Stop anything the tests started before deleting the state directory.
    # Never target this process or its parent: a test that recorded the test
    # runner's own PID would otherwise kill the suite mid-run.
    $Protected = @($PID)
    try {
        $Parent = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
        if ($Parent) { $Protected += [int]$Parent }
    }
    catch { Write-Debug "could not resolve parent process: $_" }

    Get-ChildItem (Join-Path $Path 'run') -Filter '*.pid' -ErrorAction SilentlyContinue | ForEach-Object {
        $Content = (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue).Trim()
        $ServicePid = 0
        if ([int]::TryParse($Content, [ref]$ServicePid) -and $ServicePid -notin $Protected) {
            Get-Process -Id $ServicePid -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-Pp2LongRunningService {
    <#
    .SYNOPSIS
        A service definition that starts quickly and stays up until killed.
    #>
    param([string]$Extra = '')
    return [ordered]@{
        command     = 'pwsh'
        arguments   = @('-NoProfile', '-Command', "while (`$true) { Start-Sleep -Seconds 1 }$Extra")
        shell       = $false
        autoRestart = $false
    }
}

function Wait-Pp2ProcessExit {
    <#
    .SYNOPSIS
        Poll until the process is gone, or the timeout elapses.
    #>
    param([int]$ProcessId, [int]$TimeoutSeconds = 10)
    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $Deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
