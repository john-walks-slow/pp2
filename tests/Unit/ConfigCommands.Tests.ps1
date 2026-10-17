<#
.SYNOPSIS
    Unit tests for the config-editing commands (add / set / remove / show).

.DESCRIPTION
    Every test asserts through a fresh read of services.json rather than through
    the module's in-memory copy: the value of these commands is what lands on
    disk, and an edit that only mutated $script:Config would look correct here
    and do nothing for the next invocation.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    Import-Module (Join-Path (Get-Pp2ModuleRoot) 'pp2.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module pp2 -Force -ErrorAction SilentlyContinue
}

Describe 'Adding a service' {
    BeforeEach { $TestHome = New-Pp2TestHome }
    AfterEach { Remove-Pp2TestHome $TestHome }

    It 'writes the service to services.json' {
        pp2 add web -Field @{ command = 'npx'; arguments = @('-y', 'http-server') } *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.web.command | Should -Be 'npx'
        $Config.services.web.arguments | Should -Be @('-y', 'http-server')
    }

    It 'keeps the other services and the settings section' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{ keep = @{ command = 'pwsh' } }) -Settings @{ portCheckTimeout = 4321 }
        try {
            pp2 add web -Field @{ command = 'npx' } *> $null

            $Config = Get-Content (Join-Path $Home_ 'services.json') -Raw | ConvertFrom-Json
            $Config.services.keep.command | Should -Be 'pwsh'
            $Config.settings.portCheckTimeout | Should -Be 4321
        }
        finally { Remove-Pp2TestHome $Home_ }
    }

    It 'persists nested objects rather than flattening them' {
        # ConvertTo-Json defaults to -Depth 2, which turns a nested object into
        # the string "System.Collections.Specialized.OrderedDictionary"; an
        # unguarded save would corrupt env on the first edit.
        pp2 add web -Field @{ command = 'npx'; env = @{ PORT = '8080'; NESTED = @{ DEEP = 'yes' } } } *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.web.env.PORT | Should -Be '8080'
        $Config.services.web.env.NESTED.DEEP | Should -Be 'yes'
    }

    It 'writes the file without a BOM and without a trailing newline' {
        # Matches how Read-Pp2Config creates the file and how a hand-edited one
        # looks, so a diff after an edit shows only the change.
        pp2 add web -Field @{ command = 'npx' } *> $null

        $Bytes = [IO.File]::ReadAllBytes((Join-Path $TestHome 'services.json'))
        ($Bytes[0..2] -join ',') | Should -Not -Be '239,187,191'
        $Bytes[-1] | Should -Not -Be 10
    }

    It 'refuses to replace an existing service without -Force' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{ web = @{ command = 'original' } })
        try {
            { pp2 add web -Field @{ command = 'replaced' } } | Should -Throw "*already exists*"

            $Config = Get-Content (Join-Path $Home_ 'services.json') -Raw | ConvertFrom-Json
            $Config.services.web.command | Should -Be 'original'
        }
        finally { Remove-Pp2TestHome $Home_ }
    }

    It 'replaces an existing service with -Force' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{ web = @{ command = 'original' } })
        try {
            pp2 add web -Field @{ command = 'replaced' } -Force *> $null

            $Config = Get-Content (Join-Path $Home_ 'services.json') -Raw | ConvertFrom-Json
            $Config.services.web.command | Should -Be 'replaced'
        }
        finally { Remove-Pp2TestHome $Home_ }
    }

    It 'rejects a definition with no command' {
        { pp2 add web -Field @{ arguments = @('x') } } | Should -Throw "*'command' is required*"
    }

    It 'rejects an ephemeral service with no shutdownCommand' {
        { pp2 add web -Field @{ command = 'x'; ephemeral = $true } } |
            Should -Throw "*'shutdownCommand' is required*"
    }

    It 'rejects a dependsOn that names no known service' {
        { pp2 add web -Field @{ command = 'x'; dependsOn = @('ghost') } } |
            Should -Throw "*unknown service 'ghost'*"
    }

    It 'rejects a port that is not a port number' {
        { pp2 add web -Field @{ command = 'x'; ports = @('notaport') } } |
            Should -Throw '*not a port number*'
    }

    It 'rejects a name that cannot be a filename' {
        { pp2 add 'a/b' -Field @{ command = 'x' } } | Should -Throw '*Invalid service name*'
    }

    It 'requires a name' {
        { pp2 add -Field @{ command = 'x' } } | Should -Throw '*requires a service name*'
    }

    It 'rejects a stray argument instead of reading it as a field name' {
        # `pp2 add web extra -Field ...` binds 'extra' to $Value, and add has no
        # use for it -- accepting the command would discard the argument.
        { pp2 add web extra -Field @{ command = 'x' } } | Should -Throw '*add does not take*'
    }
    It 'requires the -Field mapping' {
        { pp2 add web } | Should -Throw '*requires a -Field mapping*'
    }
}

Describe 'Setting a single field' {
    BeforeEach {
        $TestHome = New-Pp2TestHome -Services ([ordered]@{
                web = @{ command = 'npx'; ports = @(8080) }
            })
    }
    AfterEach { Remove-Pp2TestHome $TestHome }

    It 'changes the field and leaves the others alone' {
        pp2 set web maxRetries 5 *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.web.maxRetries | Should -Be 5
        $Config.services.web.command | Should -Be 'npx'
    }

    It 'stores a numeric field as a number' {
        # The value arrives from the command line as a string; without coercion
        # maxRetries would become "5" and (Get-ServiceProperty ... 3) -eq 5
        # comparisons downstream would never match.
        pp2 set web maxRetries 5 *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.web.maxRetries | Should -BeOfType [long]
    }

    It 'stores a boolean field as a boolean' {
        pp2 set web autoRestart true *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.web.autoRestart | Should -BeOfType [bool]
        $Config.services.web.autoRestart | Should -BeTrue
    }

    It 'stores a port list as numbers when written comma-separated' {
        pp2 set web ports '9000,9001' *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.web.ports | Should -Be @(9000, 9001)
        $Config.services.web.ports[0] | Should -BeOfType [long]
    }

    It 'keeps a single value an array rather than collapsing it to a scalar' {
        # PowerShell unrolls a one-element array on return, so without an
        # explicit comma `pp2 set web ports 8080` wrote "ports": 8080 while
        # `pp2 add` wrote "ports": [8080] -- two shapes for one field.
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                keeper = @{ command = 'pwsh' }
                web    = @{ command = 'npx' }
            })
        try {
            pp2 set web ports 8080 *> $null
            pp2 set web dependsOn keeper *> $null
            pp2 set web arguments '-y' *> $null

            $Json = Get-Content (Join-Path $Home_ 'services.json') -Raw
            $Json | Should -Match '"ports":\s*\[\s*8080\s*\]'
            $Json | Should -Match '"dependsOn":\s*\[\s*"keeper"\s*\]'
            $Json | Should -Match '"arguments":\s*\[\s*"-y"\s*\]'
        }
        finally { Remove-Pp2TestHome $Home_ }
    }

    It 'stores a JSON object field as an object' {
        pp2 set web env '{"PORT":"3000"}' *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.web.env.PORT | Should -Be '3000'
    }

    It 'shows the old and new value' {
        $Output = pp2 set web maxRetries 5 *>&1 | Out-String
        $Output | Should -Match 'maxRetries'
        $Output | Should -Match '5'
    }

    It 'shows an array field as a list rather than as its bare element' {
        # Assigning an if-expression unrolls a one-element array, which made the
        # old value print as 8080 where the field actually holds [8080].
        $Output = pp2 set web ports 9090 -Force *>&1 | Out-String
        $Output | Should -Match '\[9090\]'
        $Output | Should -Match '\[8080\]'
    }

    It 'rejects a value of the wrong type' {
        { pp2 set web shell maybe } | Should -Throw "*expects true or false*"
        { pp2 set web maxRetries lots } | Should -Throw '*expects a number*'
    }

    It 'rejects an unknown field without -Force' {
        { pp2 set web nonsense 1 } | Should -Throw '*Unknown field*'
    }

    It 'sets an unknown field with -Force' {
        pp2 set web customThing hello -Force *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.web.customThing | Should -Be 'hello'
    }

    It 'rejects a value that would invalidate the service' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{ web = @{ command = 'npx' } })
        try {
            { pp2 set web ports '99999' } | Should -Throw '*not a port number*'

            $Config = Get-Content (Join-Path $Home_ 'services.json') -Raw | ConvertFrom-Json
            $Config.services.web.ports | Should -BeNullOrEmpty
        }
        finally { Remove-Pp2TestHome $Home_ }
    }

    It 'reports an unknown service' {
        { pp2 set ghost maxRetries 1 } | Should -Throw '*Unknown service: ghost*'
    }

    It 'requires a value' {
        { pp2 set web maxRetries } | Should -Throw '*requires a value*'
    }
}

Describe 'Removing a service' {
    BeforeEach {
        $TestHome = New-Pp2TestHome -Services ([ordered]@{
                keep = @{ command = 'pwsh' }
                gone = @{ command = 'pwsh' }
            })
    }
    AfterEach { Remove-Pp2TestHome $TestHome }

    It 'drops the service from services.json' {
        pp2 remove gone -Force *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.PSObject.Properties.Name | Should -Not -Contain 'gone'
        $Config.services.PSObject.Properties.Name | Should -Contain 'keep'
    }

    It 'reports an unknown service instead of silently succeeding' {
        { pp2 remove ghost -Force } | Should -Throw '*No services were removed*'
    }

    It 'removes several services from one comma-separated argument' {
        # `pp2 remove a b` cannot work: a positional [string[]] binds one
        # argument, so 'b' would land in $Field and be ignored. The comma form is
        # the spelling that binds, and a stray second argument is rejected below.
        pp2 remove keep,gone -Force *> $null

        $Config = Get-Content (Join-Path $TestHome 'services.json') -Raw | ConvertFrom-Json
        $Config.services.PSObject.Properties.Name | Should -BeNullOrEmpty
    }

    It 'rejects a second name given as a separate argument' {
        # 'gone' binds to $Field; remove takes a comma-separated list instead.
        # Acting on just 'keep' would silently drop half the request.
        { pp2 remove keep gone -Force } | Should -Throw '*comma-separated list*'
    }

    It 'warns when a remaining service still depends on the removed one' {
        $Home_ = New-Pp2TestHome -Services ([ordered]@{
                db  = @{ command = 'pwsh' }
                api = @{ command = 'pwsh'; dependsOn = @('db') }
            })
        try {
            # Warnings raised in module scope reach the caller's warning stream.
            $Output = pp2 remove db -Force 3>&1 | Out-String
            $Output | Should -Match 'still depend'
            $Output | Should -Match 'api'
        }
        finally { Remove-Pp2TestHome $Home_ }
    }
}

Describe 'Showing a service' {
    BeforeEach {
        $TestHome = New-Pp2TestHome -Services ([ordered]@{ web = @{ command = 'npx'; ports = @(8080) } })
    }
    AfterEach { Remove-Pp2TestHome $TestHome }

    It 'prints every field of the definition' {
        # Write-Host writes to the information stream (6), so plain `| Out-String`
        # captures nothing; 6>&1 folds it back in for inspection.
        $Output = pp2 show web 6>&1 | Out-String
        $Output | Should -Match 'command'
        $Output | Should -Match 'npx'
        $Output | Should -Match 'ports'
    }

    It 'emits the definition as JSON with -Format json' {
        $Json = (pp2 show web -Format json | Out-String) | ConvertFrom-Json
        $Json.command | Should -Be 'npx'
        $Json.ports | Should -Be @(8080)
    }

    It 'reports an unknown service' {
        { pp2 show ghost } | Should -Throw '*Unknown service: ghost*'
    }
}
