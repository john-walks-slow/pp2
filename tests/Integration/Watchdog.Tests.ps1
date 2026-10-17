<#
.SYNOPSIS
    Integration tests for the watchdog's auto-restart loop.

.DESCRIPTION
    These start a real watchdog against a real crashing service, because the
    regression they guard against was invisible to every other kind of test: a
    parameter named $Config in lib/pp2-watchdog.ps1 was the same variable as
    pp2-core's $script:Config, so Get-Setting threw inside the monitoring loop
    and ended the script. Services simply stopped being restarted, and the only
    trace was on a hidden process's stderr.

    Keep the service set small: each case runs a real watchdog for ~25s.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    Import-Module (Join-Path (Get-Pp2ModuleRoot) 'pp2.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module pp2 -Force -ErrorAction SilentlyContinue
}

Describe 'Watchdog auto-restart' {
    AfterEach {
        # PP2_HOME is process-global; stop whatever this case left running.
        try { pp2 watchdog-stop *> $null } catch { }
        try { pp2 stop all *> $null } catch { }
        if ($TestHome) { Remove-Pp2TestHome $TestHome }
    }

    It 'restarts a service that dies after it started' {
        # Dies ~3s in, so the PID file exists and the watchdog sees a dead
        # process -- the path that calls Get-Setting 'restartTimeout'.
        $TestHome = New-Pp2TestHome -Settings @{ watchdogInterval = 2; startupVerifyWait = 8000 } -Services ([ordered]@{
                dying = @{
                    command     = 'pwsh'
                    arguments   = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 3; exit 1')
                    autoRestart = $true
                    maxRetries  = 2
                }
            })

        pp2 start dying *> $null
        pp2 watchdog-start *> $null

        $LogPath = Join-Path $TestHome 'logs\watchdog.log'
        # Wait for the outcome, not for the attempt: "auto-restarting" is logged
        # before the restart subprocess has even been spawned, so breaking on it
        # races the "restart succeeded" line this test actually asserts.
        $Deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $Deadline) {
            if ((Test-Path $LogPath) -and (Get-Content $LogPath -Raw) -match 'restart succeeded for dying') { break }
            Start-Sleep -Milliseconds 500
        }

        $Log = if (Test-Path $LogPath) { Get-Content $LogPath -Raw } else { '' }
        $Log | Should -Match 'dying crashed'
        $Log | Should -Match 'auto-restarting dying'
        $Log | Should -Match 'restart succeeded for dying'
    }

    It 'reads its interval from settings instead of the built-in default' {
        $TestHome = New-Pp2TestHome -Settings @{ watchdogInterval = 3 } -Services ([ordered]@{
                idle = @{ command = 'pwsh'; arguments = @('-NoProfile', '-Command', 'exit 0') }
            })

        pp2 watchdog-start *> $null

        $LogPath = Join-Path $TestHome 'logs\watchdog.log'
        $Deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $Deadline) {
            if (Test-Path $LogPath) { break }
            Start-Sleep -Milliseconds 300
        }

        (Get-Content $LogPath -Raw) | Should -Match 'watchdog started.*interval=3'
    }

    It 'keeps running after a settings lookup' {
        # The loop aborted on the first Get-Setting throw, so "the watchdog
        # process still exists" is not enough -- assert it is still doing its
        # job by observing a second, later tick in the log.
        $TestHome = New-Pp2TestHome -Settings @{ watchdogInterval = 2 } -Services ([ordered]@{
                dying = @{
                    command     = 'pwsh'
                    arguments   = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 2; exit 1')
                    autoRestart = $true
                    maxRetries  = 3
                }
            })

        pp2 start dying *> $null
        pp2 watchdog-start *> $null

        $LogPath = Join-Path $TestHome 'logs\watchdog.log'
        $Deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $Deadline) {
            if ((Test-Path $LogPath) -and (Get-Content $LogPath -Raw) -match 'retry 2/3') { break }
            Start-Sleep -Milliseconds 500
        }

        (Get-Content $LogPath -Raw) | Should -Match 'retry 2/3'
    }
}
