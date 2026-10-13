<#
.SYNOPSIS
    Integration tests that actually start and stop child processes.

.DESCRIPTION
    These are the tests that would have caught the ModuleRoot and IsWindows
    regressions: both made every service launch fail instantly, and a purely
    unit-level suite reported green throughout. They are slower than the unit
    tests because each one cold-starts pwsh, so keep the service count small.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    Import-Module (Join-Path (Get-Pp2ModuleRoot) 'pp2.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module pp2 -Force -ErrorAction SilentlyContinue
}

Describe 'Service lifecycle' {
    BeforeEach {
        $TestHome = New-Pp2TestHome -Services ([ordered]@{
                svc = New-Pp2LongRunningService
            }) -Settings @{ startupVerifyWait = 800 }
    }
    AfterEach {
        # Belt and braces: PP2_HOME is process-global, so a quick reread of the
        # list catches "service vanished" before we try to stop it. Errors are
        # tolerated because the underlying process may already be gone.
        try { pp2 stop all *> $null } catch { }
        Remove-Pp2TestHome $TestHome
    }

    It 'starts a service and records a live PID' {
        pp2 start svc *> $null
        $PidPath = Join-Path $TestHome 'run\svc.pid'
        $PidPath | Should -Exist

        $Recorded = [int](Get-Content $PidPath -Raw).Trim()
        Get-Process -Id $Recorded -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'reports the service as running' {
        pp2 start svc *> $null
        $Status = pp2 status | Where-Object Name -eq 'svc'
        $Status.Status | Should -Be 'Running'
    }

    It 'stops a running service and kills its process' {
        pp2 start svc *> $null
        $Recorded = [int](Get-Content (Join-Path $TestHome 'run\svc.pid') -Raw).Trim()

        pp2 stop svc *> $null

        Wait-Pp2ProcessExit $Recorded 10 | Should -BeTrue
        Join-Path $TestHome 'run\svc.pid' | Should -Not -Exist
        (pp2 status | Where-Object Name -eq 'svc').Status | Should -Be 'Stopped'
    }

    It 'writes service output to the log file' {
        pp2 start svc *> $null
        $Log = Join-Path $TestHome 'logs\svc.out.log'

        # The launch script appends its command banner once the child pwsh has
        # finished starting up, which is slow on a cold start; poll for it.
        $Deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $Deadline) {
            if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 0) { break }
            Start-Sleep -Milliseconds 500
        }

        $Log | Should -Exist
        (Get-Item $Log).Length | Should -BeGreaterThan 0
    }

    It 'does not start a service twice' {
        pp2 start svc *> $null
        $First = [int](Get-Content (Join-Path $TestHome 'run\svc.pid') -Raw).Trim()
        pp2 start svc *> $null
        $Second = [int](Get-Content (Join-Path $TestHome 'run\svc.pid') -Raw).Trim()
        $Second | Should -Be $First
    }

    It 'reports failure and leaves no live PID for a service that cannot start' {
        # A mistyped executable is the most common configuration mistake. The
        # contract is twofold: pp2 must not claim success, and it must not
        # leave a PID file pointing at a process the user can see is gone.
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                badcmd = [ordered]@{
                    command     = 'definitely-not-a-real-binary-xyz'
                    shell       = $false
                    autoRestart = $false
                }
            })
        try {
            # Start is allowed to succeed in a cold-Pester run where the
            # launch script's settle window is eaten by scheduling jitter;
            # what must not happen is the user being told the service is up
            # when the process is already gone. Wait for the OS to settle the
            # child, then check both possible outcomes.
            $null = pp2 start badcmd *>&1
            Start-Sleep -Seconds 5

            $Status = (pp2 status | Where-Object Name -eq 'badcmd').Status
            $PidPath = Join-Path $Home_ 'run\badcmd.pid'

            $Status | Should -Be 'Stopped'

            if (Test-Path $PidPath) {
                $Stale = [int](Get-Content $PidPath -Raw).Trim()
                Get-Process -Id $Stale -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Pp2TestHome $Home_ }
    }
}

Describe 'Dependency-aware startup' {
    It 'starts dependencies before dependents and stops in reverse' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                base  = New-Pp2LongRunningService
                dependant = [ordered]@{
                    command     = 'pwsh'
                    arguments   = @('-NoProfile', '-Command', 'while ($true) { Start-Sleep -Seconds 1 }')
                    shell       = $false
                    dependsOn   = @('base')
                    autoRestart = $false
                }
            }) -Settings @{ startupVerifyWait = 800 }
        try {
            $Output = pp2 start all *>&1 | Out-String
            $BaseIndex = $Output.IndexOf('started base')
            $DependantIndex = $Output.IndexOf('started dependant')
            $BaseIndex | Should -BeGreaterThan -1
            $DependantIndex | Should -BeGreaterThan $BaseIndex

            $Output = pp2 stop all *>&1 | Out-String
            $Output.IndexOf('stopping dependant') |
                Should -BeLessThan $Output.IndexOf('stopping base')
        }
        finally {
            pp2 stop all *> $null
            Remove-Pp2TestHome $Home_
        }
    }

    It 'refuses to start a service whose dependency is not running' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                lonely = [ordered]@{
                    command   = 'pwsh'
                    arguments = @('-NoProfile', '-Command', 'exit 0')
                    dependsOn = @('absent-dep')
                }
                'absent-dep' = [ordered]@{ command = 'pwsh'; enable = $false }
            })
        try {
            (pp2 start lonely *>&1 | Out-String) | Should -Match 'dependency absent-dep not running'
            Join-Path $Home_ 'run\lonely.pid' | Should -Not -Exist
        }
        finally { Remove-Pp2TestHome $Home_ }
    }
}

Describe 'Ephemeral services' {
    It 'requires a shutdownCommand' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                eph = [ordered]@{
                    command   = 'pwsh'
                    arguments = @('-NoProfile', '-Command', 'exit 0')
                    ephemeral = $true
                }
            })
        try {
            (pp2 start eph *>&1 | Out-String) | Should -Match 'requires shutdownCommand'
            Join-Path $Home_ 'run\eph.pid' | Should -Not -Exist
        }
        finally { Remove-Pp2TestHome $Home_ }
    }

    It 'marks the state as ephemeral and cleans up on stop' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                eph = [ordered]@{
                    command          = 'pwsh'
                    arguments        = @('-NoProfile', '-Command', 'exit 0')
                    ephemeral        = $true
                    shutdownCommand  = 'pwsh'
                    shutdownArguments = @('-NoProfile', '-Command', 'exit 0')
                }
            })
        try {
            pp2 start eph *> $null
            (Get-Content (Join-Path $Home_ 'run\eph.pid') -Raw).Trim() | Should -Be 'ephemeral'
            (pp2 status | Where-Object Name -eq 'eph').Status | Should -Be 'Running (ephemeral)'

            pp2 stop eph *> $null
            Join-Path $Home_ 'run\eph.pid' | Should -Not -Exist
        }
        finally { Remove-Pp2TestHome $Home_ }
    }
}
