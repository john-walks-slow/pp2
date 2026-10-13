<#
.SYNOPSIS
    Unit tests for process lifecycle helpers that do not need a live service.

.NOTES
    Assertions stay outside `& (Get-Module pp2) { ... }`: the module's session
    state does not have Pester's Should command, so values are computed inside
    module scope and asserted in test scope.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    Import-Module (Join-Path (Get-Pp2ModuleRoot) 'pp2.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module pp2 -Force -ErrorAction SilentlyContinue
}

Describe 'Process tracking' {
    BeforeEach {
        $TestHome = New-Pp2TestHome
        & (Get-Module pp2) { Initialize-Pp2Context -ScriptRoot (Get-Pp2Root); Read-Pp2Config } | Out-Null
    }
    AfterEach { Remove-Pp2TestHome $TestHome }

    It 'reports no process when there is no PID file' {
        $Result = & (Get-Module pp2) { Get-RecordedProcess 'nothing' }
        $Result | Should -BeNullOrEmpty
    }

    It 'reports the live process named by the PID file' {
        # A real child process, not $PID: recording the test runner's own PID
        # would make cleanup kill the suite.
        $Child = Start-Process pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -PassThru -WindowStyle Hidden
        try {
            $Result = & (Get-Module pp2) {
                param($ExpectedPid)
                Set-Content (Get-PidPath 'me') -Value $ExpectedPid -NoNewline
                Get-RecordedProcess 'me'
            } $Child.Id
            $Result | Should -Not -BeNullOrEmpty
            $Result.Id | Should -Be $Child.Id
        }
        finally {
            if (-not $Child.HasExited) { $Child.Kill() }
        }
    }

    It 'reports no process for a numeric PID that is not running' {
        # A retired PID is a valid number, so it is not treated as corrupt;
        # the service simply reads as stopped.
        $Result = & (Get-Module pp2) {
            Set-Content (Get-PidPath 'stale') -Value '999999' -NoNewline
            Get-RecordedProcess 'stale'
        }
        $Result | Should -BeNullOrEmpty
    }

    It 'clears state when the PID file is not a number' {
        $Result = & (Get-Module pp2) {
            Set-Content (Get-PidPath 'junk') -Value 'not-a-pid' -NoNewline
            $Found = Get-RecordedProcess 'junk'
            [pscustomobject]@{ Found = $Found; StillExists = Test-Path (Get-PidPath 'junk') }
        }
        $Result.Found | Should -BeNullOrEmpty
        $Result.StillExists | Should -BeFalse
    }

    It 'recognises the ephemeral marker' {
        $Result = & (Get-Module pp2) {
            Set-Content (Get-PidPath 'eph') -Value 'ephemeral' -NoNewline
            Get-RecordedProcess 'eph'
        }
        $Result | Should -Be 'ephemeral'
    }

    It 'clears every state file for a service' {
        $Result = & (Get-Module pp2) {
            foreach ($Kind in @('pid', 'elevated', 'retry', 'healthy')) {
                Set-Content (Get-StatePath 'svc' $Kind) -Value '1' -NoNewline
            }
            Remove-ServiceState 'svc'
            @('pid', 'elevated', 'retry', 'healthy') |
                ForEach-Object { Test-Path (Get-StatePath 'svc' $_) }
        }
        $Result | Should -Not -Contain $true
    }
}

Describe 'Port probing' {
    It 'reports a closed port as unavailable' {
        # Unused high port: nothing is listening.
        (& (Get-Module pp2) { Test-Port 59999 300 }) | Should -BeFalse
    }

    It 'reports an open port as available' {
        $Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $Listener.Start()
        try {
            $Port = $Listener.LocalEndpoint.Port
            (& (Get-Module pp2) { param($P) Test-Port $P 1000 } $Port) | Should -BeTrue
        }
        finally { $Listener.Stop() }
    }

    It 'does not throw when the port is closed' {
        { & (Get-Module pp2) { Test-Port 59998 200 } } | Should -Not -Throw
    }
}

Describe 'Formatting helpers' {
    It 'renders sub-hour durations in minutes and seconds' {
        (& (Get-Module pp2) { Format-Duration ([TimeSpan]::FromSeconds(95)) }) | Should -Be '1m 35s'
    }

    It 'renders sub-day durations in hours and minutes' {
        (& (Get-Module pp2) { Format-Duration ([TimeSpan]::FromMinutes(185)) }) | Should -Be '3h 5m'
    }

    It 'renders multi-day durations in days and hours' {
        (& (Get-Module pp2) { Format-Duration ([TimeSpan]::FromHours(50)) }) | Should -Be '2d 2h'
    }

    It 'quotes values containing single quotes safely' {
        (& (Get-Module pp2) { ConvertTo-PwshLiteral "it's" }) | Should -Be "'it''s'"
    }
}

Describe 'Stability tracking' {
    BeforeEach {
        $TestHome = New-Pp2TestHome -Settings @{ healthCheckGrace = 2 }
        & (Get-Module pp2) { Initialize-Pp2Context -ScriptRoot (Get-Pp2Root); Read-Pp2Config } | Out-Null
    }
    AfterEach { Remove-Pp2TestHome $TestHome }

    It 'reports unstable on the first observation' {
        (& (Get-Module pp2) { Test-ServiceStability 'svc' }) | Should -BeFalse
    }

    It 'reports stable once the grace period has elapsed' {
        & (Get-Module pp2) { Test-ServiceStability 'svc' } | Out-Null
        Start-Sleep -Seconds 3
        (& (Get-Module pp2) { Test-ServiceStability 'svc' }) | Should -BeTrue
    }

    It 'restarts the clock when stability is cleared' {
        & (Get-Module pp2) { Test-ServiceStability 'svc' } | Out-Null
        Start-Sleep -Seconds 3
        (& (Get-Module pp2) { Test-ServiceStability 'svc' }) | Should -BeTrue
        & (Get-Module pp2) { Clear-ServiceStability 'svc' }
        (& (Get-Module pp2) { Test-ServiceStability 'svc' }) | Should -BeFalse
    }

    It 'drops the retry counter when reset' {
        $Result = & (Get-Module pp2) {
            Set-Content (Get-RetryPath 'svc') -Value '2' -NoNewline
            Reset-RetryState 'svc'
            Test-Path (Get-RetryPath 'svc')
        }
        $Result | Should -BeFalse
    }
}
