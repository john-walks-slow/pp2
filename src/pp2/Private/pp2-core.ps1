Set-StrictMode -Version Latest

function Get-Pp2Root {
  <#
  .SYNOPSIS
    Resolve the pp2 state root at call time.

  .DESCRIPTION
    Read per invocation instead of at import time so that changing PP2_HOME
    takes effect without re-importing the module.
  #>
  if ($env:PP2_HOME) { return $env:PP2_HOME }
  return (Join-Path $HOME '.pp2')
}

function Initialize-Pp2Context {
  param([Parameter(Mandatory = $true)][string]$ScriptRoot)

  $script:Root = $ScriptRoot
  $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
  $script:ConfigPath = Join-Path $script:Root 'services.json'
  $script:RunDir = Join-Path $script:Root 'run'
  $script:LogDir = Join-Path $script:Root 'logs'
  $script:TaskName = 'pp2 Startup'
  $script:ConfigLoaded = $false
  $script:Config = $null

  New-Item -ItemType Directory -Force -Path $script:RunDir, $script:LogDir | Out-Null
}

function Read-Pp2Config {
  <#
  .SYNOPSIS
    Load and normalize services.json into $script:Config.

  .DESCRIPTION
    Creates a default config when absent, rejects malformed JSON with an
    actionable message, and guarantees the 'settings'/'services' sections
    exist as PSCustomObject so property access is safe under StrictMode.
  #>
  $Path = $script:ConfigPath

  if (-not (Test-Path $Path)) {
    Set-Content -Path $Path -Value '{"settings":{},"services":{}}' -Encoding UTF8
  }

  $Raw = Get-Content $Path -Raw -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($Raw)) { $Raw = '{"settings":{},"services":{}}' }

  try {
    $script:Config = $Raw | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw "Invalid JSON in '$Path': $($_.Exception.Message)"
  }

  if ($null -eq $script:Config) { $script:Config = [PSCustomObject]@{} }

  foreach ($Section in @('settings', 'services')) {
    $Value = $script:Config.PSObject.Properties[$Section]
    if ($Value -and $Value.Value -is [PSCustomObject]) { continue }
    $script:Config | Add-Member -MemberType NoteProperty -Name $Section -Value ([PSCustomObject]@{}) -Force
  }

  $script:ConfigLoaded = $true
}

function Initialize-Pp2Config {
  if (-not $script:ConfigLoaded) { Read-Pp2Config }
}

function Get-Setting([string]$Name, $Default) {
  Initialize-Pp2Config
  $Settings = $script:Config.settings
  $Property = $Settings.PSObject.Properties[$Name]
  if ($Property) { return $Property.Value }
  return $Default
}

function Test-EnabledService([string]$ServiceName) {
  $Service = Get-ServiceConfig $ServiceName
  return (Get-ServiceProperty $Service 'enable' $true) -eq $true
}

function Get-ServiceNames([string[]]$Name = @('all')) {
  Initialize-Pp2Config
  $ServicesObj = $script:Config.services

  $RequestedNames = @($Name | Where-Object { $_ -ne 'all' })
  if ($RequestedNames.Count -eq 0) {
    if ($null -eq $ServicesObj) { return @() }
    $Props = $ServicesObj.PSObject.Properties
    if ($null -eq $Props) { return @() }
    $PropCount = @($Props).Count
    if ($PropCount -eq 0) { return @() }
    return @($Props.Name | Where-Object { Test-EnabledService $_ })
  }
  
  foreach ($ServiceName in $RequestedNames) {
    if ($null -eq $ServicesObj -or $null -eq $ServicesObj.PSObject.Properties[$ServiceName]) { 
      throw "Unknown service: $ServiceName" 
    }
    if (-not (Test-EnabledService $ServiceName)) {
      throw "Service is disabled: $ServiceName"
    }
  }
  return $RequestedNames
}

function Get-ServiceConfig([string]$ServiceName) {
  Initialize-Pp2Config
  $Property = $script:Config.services.PSObject.Properties[$ServiceName]
  if (-not $Property) { throw "Unknown service: $ServiceName" }
  return $Property.Value
}

function Get-ServiceProperty($Service, [string]$PropertyName, $Default = $null) {
  if ($null -eq $Service) { return $Default }
  $Property = $Service.PSObject.Properties[$PropertyName]
  if ($Property) { return $Property.Value }
  return $Default
}

function Save-Pp2Config {
  <#
  .SYNOPSIS
    Write $script:Config back to services.json.

  .DESCRIPTION
    Writes through a temporary file and then moves it into place, so an
    interrupted save leaves the previous config intact rather than a truncated
    one. The move is atomic on the same volume, which the temp file guarantees.

    -Depth is passed explicitly and generously: ConvertTo-Json defaults to 2,
    which silently truncates a nested object such as env or settings into the
    string "System.Collections.Specialized.OrderedDictionary" and would corrupt
    the user's config on the first edit.

    NoNewline keeps the trailing newline off, matching how the file is written
    on creation; Set-Content -Encoding UTF8 is BOM-less on PowerShell 7, which
    is what a hand-edited services.json looks like.
  #>
  $Json = $script:Config | ConvertTo-Json -Depth 32
  $Temp = "$($script:ConfigPath).tmp"
  Set-Content -Path $Temp -Value $Json -Encoding UTF8 -NoNewline
  Move-Item -Path $Temp -Destination $script:ConfigPath -Force
}

function Test-ServiceDefinition {
  <#
  .SYNOPSIS
    Validate a service definition before it is written to disk.

  .DESCRIPTION
    Editing the config persists whatever it is given, so a typo that pp2 start
    would have caught on the next run would instead sit in services.json until
    then. Catch it at the point of the edit, where the user still has the
    command in front of them.

    Every problem is collected and returned rather than thrown on the first, so
    one call tells the user everything that is wrong. dependsOn is checked
    against the services currently in the config, which is what the edit will
    leave behind in every case but a rename.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)]$Service
  )

  $Errors = @()

  if (-not (Get-ServiceProperty $Service 'command')) {
    $Errors += "'command' is required"
  }

  if ((Get-ServiceProperty $Service 'ephemeral' $false) -eq $true -and
      -not (Get-ServiceProperty $Service 'shutdownCommand')) {
    $Errors += "'shutdownCommand' is required when 'ephemeral' is true"
  }

  foreach ($Port in @(Get-ServiceProperty $Service 'ports' @()) | Where-Object { $_ }) {
    $Parsed = 0
    if (-not [int]::TryParse([string]$Port, [ref]$Parsed) -or $Parsed -lt 1 -or $Parsed -gt 65535) {
      $Errors += "'ports' entry '$Port' is not a port number (1-65535)"
    }
  }

  # .Name belongs on each property object, not on the collection: under
  # StrictMode a PSMemberInfoCollection has no Name member and reading it throws.
  $KnownName = @($script:Config.services.PSObject.Properties | ForEach-Object { $_.Name })

  foreach ($Dependency in @(Get-ServiceProperty $Service 'dependsOn' @()) | Where-Object { $_ }) {
    if ($Dependency -eq $Name) { $Errors += "'dependsOn' cannot reference the service itself"; continue }
    if ($Dependency -notin $KnownName) { $Errors += "'dependsOn' references unknown service '$Dependency'" }
  }

  return $Errors
}

function Assert-ServiceName {
  <#
  .SYNOPSIS
    Reject a service name that pp2 cannot represent on disk.

  .DESCRIPTION
    A service name becomes a filename in run/ and logs/ (<name>.pid,
    <name>.out.log), and the watchdog rebuilds its restart command by quoting
    the name into a PowerShell string literal. Restricting the character set
    keeps both of those safe without escaping gymnastics.
  #>
  param([Parameter(Mandatory)][string]$Name)

  if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "Invalid service name '$Name': use letters, digits, dot, underscore or dash, starting with a letter or digit."
  }
}

function Get-ServiceFieldType {
  <#
  .SYNOPSIS
    The JSON type a service field is expected to hold.

  .DESCRIPTION
    `pp2 set` takes its value from the command line, where everything is a
    string. Without this the first edit would turn a numeric port into "3000"
    and a boolean into "true", and the config would hold strings where the rest
    of pp2 compares against $true or casts to [int].

    An unknown field is typed as 'any' rather than rejected: pp2 ignores
    fields it does not know, and refusing to set one would block forward
    compatibility with a hand-written config.
  #>
  param([Parameter(Mandatory)][string]$FieldName)

  switch ($FieldName) {
    'arguments' { return 'array' }
    'ports' { return 'intarray' }
    'dependsOn' { return 'stringarray' }
    'shutdownArguments' { return 'array' }
    'env' { return 'object' }
    'shell' { return 'bool' }
    'ephemeral' { return 'bool' }
    'autoRestart' { return 'bool' }
    'elevated' { return 'bool' }
    'inheritEnv' { return 'bool' }
    'enable' { return 'bool' }
    'maxRetries' { return 'int' }
    'command' { return 'string' }
    'displayName' { return 'string' }
    'description' { return 'string' }
    'workingDirectory' { return 'string' }
    'shutdownCommand' { return 'string' }
    'legacyProcessName' { return 'string' }
    default { return 'any' }
  }
}

function ConvertTo-FieldValue {
  <#
  .SYNOPSIS
    Coerce a command-line value into the JSON type a service field expects.

  .DESCRIPTION
    Arrays accept either a JSON array or a comma-separated list, because
    `pp2 set web ports 3000,3001` is what a PowerShell user types while
    `pp2 set web arguments '["-y","http-server"]'` is what survives quoting.
  #>
  param(
    [Parameter(Mandatory)][string]$FieldName,
    [AllowNull()]$Value
  )

  $Type = Get-ServiceFieldType $FieldName
  # A plain assignment, not an if-expression: the latter unrolls a one-element
  # array, so passing @('a') through here would arrive as the string 'a'.
  $Raw = $Value
  if ($Value -is [string]) { $Raw = $Value.Trim() }

  switch ($Type) {
    'bool' {
      if ($Raw -is [bool]) { return $Raw }
      $Text = ([string]$Raw).ToLowerInvariant()
      if ($Text -in @('true', '$true', '1', 'yes', 'on')) { return $true }
      if ($Text -in @('false', '$false', '0', 'no', 'off')) { return $false }
      throw "'$FieldName' expects true or false, got '$Value'"
    }
    'int' {
      $Parsed = 0
      if (-not [int]::TryParse([string]$Raw, [ref]$Parsed)) { throw "'$FieldName' expects a number, got '$Value'" }
      return $Parsed
    }
    'intarray' {
      $Items = if ($Raw -is [string] -and $Raw.TrimStart().StartsWith('[')) {
        try { @($Raw | ConvertFrom-Json) } catch { throw "'$FieldName' is not a valid JSON array: $($_.Exception.Message)" }
      }
      else { @($Raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }

      # The leading comma is load-bearing: returning the array directly unrolls
      # a single element, and `pp2 set web ports 8080` would write 8080 rather
      # than [8080] -- a scalar where every other writer puts an array.
      return , @($Items | ForEach-Object {
          $Parsed = 0
          if (-not [int]::TryParse([string]$_, [ref]$Parsed)) { throw "'$FieldName' expects port numbers, got '$_'" }
          $Parsed
        })
    }
    'stringarray' {
      if ($Raw -is [string] -and $Raw.TrimStart().StartsWith('[')) {
        try { return , @($Raw | ConvertFrom-Json) } catch { throw "'$FieldName' is not a valid JSON array: $($_.Exception.Message)" }
      }
      return , @($Raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    'array' {
      if ($Raw -is [string] -and $Raw.TrimStart().StartsWith('[')) {
        try { return , @($Raw | ConvertFrom-Json) } catch { throw "'$FieldName' is not a valid JSON array: $($_.Exception.Message)" }
      }
      return , @($Raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    'object' {
      if ($Raw -is [hashtable]) { return $Raw }
      try { return ($Raw | ConvertFrom-Json -ErrorAction Stop) }
      catch { throw "'$FieldName' expects a JSON object, e.g. '{`"PORT`":3000}', got '$Value'" }
    }
    'string' { return [string]$Raw }
    default {
      # Unknown field: take the JSON reading when it parses, so a hand-added
      # array or object field stays structured instead of becoming a string.
      try { return ($Raw | ConvertFrom-Json -ErrorAction Stop) }
      catch { return $Raw }
    }
  }
}

function Test-ServiceRunning([string]$ServiceName) {
  if ($script:Config.services.PSObject.Properties[$ServiceName]) {
    if (Get-RecordedProcess $ServiceName) { return $true }
  }
  # A service removed from the config no longer has a name to look up, but its
  # PID file is still on disk; treat that as running so the caller warns.
  return (Test-Path (Get-PidPath $ServiceName))
}

function Assert-SafeToEdit([string]$ServiceName, [bool]$Force, [string]$Operation) {
  <#
  .SYNOPSIS
    Refuse to rewrite the definition of a running service without confirmation.

  .DESCRIPTION
    Editing a running service's config does not change the process that is
    already up: the launch script resolved command/arguments/env when it
    started. Saying so is more useful than silently accepting an edit that
    appears to do nothing until the next restart.
  #>
  if ($Force -or -not (Test-ServiceRunning $ServiceName)) { return }

  Write-Host "WARNING: $ServiceName is running; $Operation only changes the stored config."
  Write-Host "         The running process keeps its current settings until you restart it."
  if ((Read-Host 'Continue? [y/N]') -ne 'y') { throw "Cancelled: $ServiceName is running (pass -Force to skip this prompt)" }
}

function Invoke-RestartIfRequested {
  <#
  .SYNOPSIS
    Restart the given services, but only when the user asked for it.

  .DESCRIPTION
    Relying on the switch's default rather than its value means a caller that
    never bound -Restart cannot enable it by passing anything non-empty.
  #>
  param([string[]]$ServiceName, [switch]$Restart)

  if (-not $Restart.IsPresent -or -not $ServiceName) { return }
  foreach ($Name in $ServiceName) {
    if (Get-RecordedProcess $Name) { Stop-Many @($Name) }
  }
  Start-WatchdogIfNeeded @($ServiceName)
  Start-Many @($ServiceName) $true
}

function Add-ServiceConfig {
  param(
    [Parameter(Mandatory)][string]$ServiceName,
    [Parameter(Mandatory)][hashtable]$Field,
    [bool]$Force,
    [bool]$Restart = $false
  )

  Initialize-Pp2Config

  $Existing = $script:Config.services.PSObject.Properties[$ServiceName]
  if ($Existing -and -not $Force) {
    throw "Service '$ServiceName' already exists (pass -Force to overwrite it)"
  }
  if ($Existing) { Assert-SafeToEdit $ServiceName $Force 'overwriting it' }

  # Built as a PSCustomObject, not left as the caller's hashtable: every reader
  # in pp2 goes through Get-ServiceProperty, which walks PSObject.Properties
  # and finds nothing on a hashtable.
  $NewService = [pscustomobject]$Field
  foreach ($Key in $Field.Keys) {
    $Value = $Field[$Key]
    if ($Value -is [hashtable] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
      $NewService.($Key) = [pscustomobject]$Value
    }
  }

  # @() is load-bearing: Test-ServiceDefinition returns a scalar when there is
  # exactly one problem, and .Count on a string throws under StrictMode.
  $Errors = @(Test-ServiceDefinition $ServiceName $NewService)
  if ($Errors.Count -gt 0) { throw "Invalid service '$ServiceName': $($Errors -join '; ')" }

  $script:Config.services | Add-Member -MemberType NoteProperty -Name $ServiceName `
    -Value $NewService -Force
  Save-Pp2Config

  $Action = if ($Existing) { 'updated' } else { 'added' }
  Write-Host "$Action service $ServiceName"
  Invoke-RestartIfRequested @($ServiceName) -Restart:$Restart
}

function Set-ServiceConfigField {
  param(
    [Parameter(Mandatory)][string]$ServiceName,
    [Parameter(Mandatory)][string]$FieldName,
    [Parameter(Mandatory)][AllowNull()]$Value,
    [bool]$Force,
    [bool]$Restart = $false
  )

  Initialize-Pp2Config
  $Service = Get-ServiceConfig $ServiceName

  $FieldType = Get-ServiceFieldType $FieldName
  if ($FieldType -eq 'any' -and -not $Force) {
    throw "Unknown field '$FieldName' for service '$ServiceName' (pass -Force to set it anyway)"
  }

  $Coerced = ConvertTo-FieldValue $FieldName $Value

  Assert-SafeToEdit $ServiceName $Force "$FieldName changed"

  $Current = $Service.PSObject.Properties[$FieldName]
  # Assigning an if-expression unrolls a one-element array, so `ports = @(8080)`
  # would come back as the scalar 8080 and print as such. Reading through a
  # plain assignment keeps the shape.
  $OldValue = $null
  if ($Current) { $OldValue = $Current.Value }

  # Copy the definition as a PSCustomObject so the validator can read it the
  # same way it reads a service from the config.
  $Pending = [pscustomobject]@{}
  foreach ($Property in $Service.PSObject.Properties) {
    $Pending | Add-Member -MemberType NoteProperty -Name $Property.Name -Value $Property.Value
  }
  $Pending | Add-Member -MemberType NoteProperty -Name $FieldName -Value $Coerced -Force

  $Errors = @(Test-ServiceDefinition $ServiceName $Pending)
  if ($Errors.Count -gt 0) { throw "Invalid value for '$FieldName': $($Errors -join '; ')" }

  $Service | Add-Member -MemberType NoteProperty -Name $FieldName -Value $Coerced -Force
  Save-Pp2Config

  # Rendered through ConvertTo-Json rather than string interpolation so an
  # array field shows as [9090] instead of the PowerShell-default "9090".
  $Old = if ($null -eq $OldValue) { '(not set)' } else { ConvertTo-Json -InputObject $OldValue -Compress -Depth 32 }
  $New = ConvertTo-Json -InputObject $Coerced -Compress -Depth 32
  Write-Host "set $ServiceName.$FieldName = $New (was $Old)"
  Invoke-RestartIfRequested @($ServiceName) -Restart:$Restart
}

function Remove-ServiceConfig {
  param(
    [Parameter(Mandatory)][string[]]$ServiceName,
    [switch]$Purge,
    [bool]$Force,
    [bool]$Restart = $false
  )

  Initialize-Pp2Config

  $ToRemove = @()
  foreach ($Name in $ServiceName) {
    if (-not $script:Config.services.PSObject.Properties[$Name]) {
      Write-Warning "Unknown service: $Name (skipped)"
      continue
    }
    $ToRemove += $Name
  }
  if ($ToRemove.Count -eq 0) { throw 'No services were removed' }

  $Running = @($ToRemove | Where-Object { Get-RecordedProcess $_ })
  if ($Running.Count -gt 0 -and -not $Force) {
    Write-Host "WARNING: these services are running and will be stopped: $($Running -join ', ')"
    if ((Read-Host 'Continue? [y/N]') -ne 'y') { throw 'Cancelled (pass -Force to skip this prompt)' }
  }
  foreach ($Name in $Running) { Stop-Many @($Name) }

  # Stop the services a removed one depends on? No: dependencies are a start
  # ordering, not ownership. Only the named services go.
  foreach ($Name in $ToRemove) {
    $script:Config.services.PSObject.Properties.Remove($Name) | Out-Null
    if ($Purge) {
      Remove-ServiceState $Name
      Remove-Item (Get-OutLog $Name), (Get-ErrLog $Name) -ErrorAction SilentlyContinue
    }
  }
  Save-Pp2Config

  # Dependents of a removed service can no longer start; point at them now
  # rather than letting `pp2 start` fail later with a bare "Unknown service".
  $Orphans = @()
  foreach ($Property in $script:Config.services.PSObject.Properties) {
    $DependsOn = @(Get-ServiceProperty $Property.Value 'dependsOn' @()) | Where-Object { $_ }
    foreach ($Name in $ToRemove) {
      if ($Name -in $DependsOn) { $Orphans += "$($Property.Name) -> $Name" }
    }
  }
  if ($Orphans.Count -gt 0) {
    Write-Warning "these services still depend on what was removed: $($Orphans -join ', ')"
  }

  Write-Host "removed service(s): $($ToRemove -join ', ')$(if ($Purge) { ' (state and logs purged)' })"
}

function Open-ConfigFile {
  <#
  .SYNOPSIS
    Open the services.json config file in default editor
  #>
  $Editor = $env:EDITOR
  if (-not $Editor) {
    $Editor = (Get-Command code, code.cmd, notepad.exe -ErrorAction SilentlyContinue).Source |
      Select-Object -First 1
  }
  
  if (-not $Editor) {
    Write-Host "No editor found. Set EDITOR env var or install VS Code."
    Write-Host "Config path: $script:ConfigPath"
    return
  }

  Write-Host "Opening config: $script:ConfigPath"
  & $Editor $script:ConfigPath
}

function Test-IsElevated {
  $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
  return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PwshPath {
  $Pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
  if ($Pwsh) { return $Pwsh }
  $Pwsh = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
  if ($Pwsh) { return $Pwsh }
  throw "PowerShell executable not found. Ensure PowerShell 7+ is installed."
}

function Get-StatePath([string]$ServiceName, [string]$Kind) { Join-Path $RunDir "$ServiceName.$Kind" }
function Get-PidPath([string]$ServiceName) { Get-StatePath $ServiceName 'pid' }
function Get-ElevatedPath([string]$ServiceName) { Get-StatePath $ServiceName 'elevated' }
function Get-RetryPath([string]$ServiceName) { Get-StatePath $ServiceName 'retry' }
function Get-HealthyPath([string]$ServiceName) { Get-StatePath $ServiceName 'healthy' }
function Get-OutLog([string]$ServiceName) { Join-Path $LogDir "$ServiceName.out.log" }
function Get-ErrLog([string]$ServiceName) { Join-Path $LogDir "$ServiceName.err.log" }

function Remove-ServiceState([string]$ServiceName) {
  'pid', 'elevated', 'retry', 'healthy' | ForEach-Object {
    Remove-Item (Get-StatePath $ServiceName $_) -ErrorAction SilentlyContinue
  }
}

function Get-RecordedProcess([string]$ServiceName) {
  $PidPath = Get-PidPath $ServiceName
  if (-not (Test-Path $PidPath)) { return $null }

  $PidContent = (Get-Content $PidPath -Raw).Trim()
  
  # Handle ephemeral services (launcher pattern)
  if ($PidContent -eq 'ephemeral') {
    return 'ephemeral'
  }

  $RecordedPid = 0
  if (-not [int]::TryParse($PidContent, [ref]$RecordedPid)) {
    Remove-ServiceState $ServiceName
    return $null
  }

  return Get-Process -Id $RecordedPid -ErrorAction SilentlyContinue
}

function Format-Duration([TimeSpan]$Duration) {
  # Parentheses matter: without them the cast binds to the whole argument
  # array, and "{0}m {1}s" -f [int]$A, [int]$B rounds both values together.
  $Days = [int]$Duration.Days
  $Hours = [int]$Duration.Hours
  $Minutes = [int]$Duration.Minutes
  $Seconds = [int]$Duration.Seconds
  $TotalHours = [int][Math]::Floor($Duration.TotalHours)
  $TotalMinutes = [int][Math]::Floor($Duration.TotalMinutes)

  if ($Duration.TotalDays -ge 1) { return "${Days}d ${Hours}h" }
  if ($Duration.TotalHours -ge 1) { return "${TotalHours}h ${Minutes}m" }
  return "${TotalMinutes}m ${Seconds}s"
}

function Get-ServiceUptime([string]$ServiceName, $Process) {
  $PidPath = Get-PidPath $ServiceName
  if (-not $Process -or -not (Test-Path $PidPath)) { return '-' }
  return Format-Duration ((Get-Date) - (Get-Item $PidPath).LastWriteTime)
}

function Reset-RetryState([string]$ServiceName) {
  Remove-Item (Get-RetryPath $ServiceName) -ErrorAction SilentlyContinue
}

function Get-LaunchLogLength([string]$ServiceName) {
  $Path = Get-OutLog $ServiceName
  if (-not (Test-Path $Path)) { return 0 }
  return (Get-Item $Path).Length
}

function Wait-ServiceStartup {
  <#
  .SYNOPSIS
    Decide whether a just-launched service is actually up.

  .DESCRIPTION
    The tracked PID is the launch script, which has to boot PowerShell before
    running anything, so on a cold start nothing observable happens for several
    seconds. A fixed wait either reports success for a service that dies
    immediately, or slows every healthy start.

    Wait for the launch script's banner (it appends the command it is about to
    run) and then poll for the child to either still be running or to have
    crashed. A service that runs the command and stays up will keep its
    process alive past the polling deadline; one that errors out (mistyped
    binary, bad arguments) will return to "process not found" within a second
    or two. The timeout caps the worst case, so a healthy but slow service
    falls through to "running" rather than hanging the user.

    Returns $true when the process exited (start failed).
  #>
  param([string]$ServiceName, [int]$ProcessId)

  $TimeoutMs = [int](Get-Setting 'startupVerifyWait' 20000)
  $StartLog = Get-LaunchLogLength $ServiceName
  $Deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  $BannerSeen = $false
  $SettleDeadline = $null

  while ($true) {
    $Alive = [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    $HasBanner = (Get-LaunchLogLength $ServiceName) -gt $StartLog

    if (-not $Alive) { return $true }
    if ($HasBanner -and -not $BannerSeen) {
      # The launch script has finished booting and is running the user's
      # command. Give it a brief moment to crash (e.g. bad binary) before
      # declaring the service healthy.
      $BannerSeen = $true
      $SettleDeadline = (Get-Date).AddMilliseconds(3000)
    }
    if ($BannerSeen -and (Get-Date) -ge $SettleDeadline) { return $false }
    if ((Get-Date) -ge $Deadline) { return $false }

    Start-Sleep -Milliseconds 100
  }
}

function Test-ServiceStability([string]$ServiceName) {
  <#
  .SYNOPSIS
    Track how long the watchdog has observed a service alive.

  .DESCRIPTION
    Returns $true once the service has been seen alive continuously for at
    least healthCheckGrace seconds, which is the signal that its crash history
    can be forgotten. The timer is anchored on the first healthy observation
    rather than the PID file timestamp: a launched process may still be
    starting up (or have silently died) while its PID file already looks old.
  #>
  $HealthyPath = Get-HealthyPath $ServiceName
  $Grace = [int](Get-Setting 'healthCheckGrace' 30)
  $Now = [DateTime]::UtcNow

  if (-not (Test-Path $HealthyPath)) {
    Set-Content -Path $HealthyPath -Value $Now.ToString('o') -NoNewline
    return $false
  }

  $Since = [DateTime]::Parse(
    (Get-Content $HealthyPath -Raw).Trim(),
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind)
  return ($Now - $Since).TotalSeconds -ge $Grace
}

function Clear-ServiceStability([string]$ServiceName) {
  Remove-Item (Get-HealthyPath $ServiceName) -ErrorAction SilentlyContinue
}

function Test-Port([int]$Port, [int]$TimeoutMs) {
  if (-not $TimeoutMs) { $TimeoutMs = [int](Get-Setting 'portCheckTimeout' 200) }
  $Client = [System.Net.Sockets.TcpClient]::new()
  try {
    $ConnectTask = $Client.ConnectAsync('127.0.0.1', $Port)
    if ($ConnectTask.Wait($TimeoutMs)) { return $Client.Connected }
    return $false
  }
  finally { $Client.Dispose() }
}

function Get-ProcessByPort([int]$Port) {
  if (-not $IsWindows) { return $null }
  $Conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($Conn) { return [int]$Conn.OwningProcess }
  return $null
}

function Get-ProcessStats([System.Diagnostics.Process]$Process) {
  if (-not $Process) { return @{ CPU = '-'; Memory = '-' } }
  try {
    return @{
      CPU = "$($Process.CPU.ToString('F1')) s"
      Memory = "$([math]::Round($Process.WorkingSet64 / 1MB, 1).ToString('F1')) MB"
    }
  }
  catch { return @{ CPU = '-'; Memory = '-' } }
}

function Invoke-ElevatedPwsh([string]$Command) {
  $SudoPath = (Get-Command sudo.exe -ErrorAction SilentlyContinue).Source
  if (-not $SudoPath) { throw 'sudo not available' }

  $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
  & $SudoPath pwsh -NoProfile -EncodedCommand $Encoded 2>&1 | Out-Null
}

function ConvertTo-PwshLiteral([string]$Value) {
  return "'$($Value -replace "'", "''")'"
}

function Stop-ProcessTree([int]$ProcessId, [switch]$Elevated) {
  if ($Elevated -and -not (Test-IsElevated)) {
    Invoke-ElevatedPwsh "taskkill.exe /PID $ProcessId /T /F | Out-Null"
    return
  }

  & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
}

function Invoke-ShutdownCommand([string]$ServiceName, [pscustomobject]$Service, [bool]$IsElevated) {
  $ShutdownCommand = Get-ServiceProperty $Service 'shutdownCommand'
  if (-not $ShutdownCommand) { return }

  $Command = [string]$ShutdownCommand
  $Arguments = @(Get-ServiceProperty $Service 'shutdownArguments' @()) | Where-Object { $_ }

  if ($IsElevated -and -not (Test-IsElevated)) {
    $LiteralArgs = ($Arguments | ForEach-Object { ConvertTo-PwshLiteral ([string]$_) }) -join ', '
    Invoke-ElevatedPwsh "& $(ConvertTo-PwshLiteral $Command) @($LiteralArgs) | Out-Null"
    return
  }

  & $Command @Arguments 2>&1 | Out-Null
}

function Test-Dependencies([string]$ServiceName) {
  $Service = Get-ServiceConfig $ServiceName
  foreach ($Dep in @(Get-ServiceProperty $Service 'dependsOn' @()) | Where-Object { $_ }) {
    if (-not (Get-RecordedProcess $Dep)) {
      Write-Host "dependency $Dep not running, cannot start $ServiceName"
      return $false
    }

    foreach ($Port in @(Get-ServiceProperty (Get-ServiceConfig $Dep) 'ports' @()) | Where-Object { $_ }) {
      if (-not (Test-Port $Port)) {
        Write-Host "dependency $Dep port $Port not ready"
        return $false
      }
    }
  }
  return $true
}

function Get-DependencyLayers([string[]]$ServiceNames, [switch]$Reverse) {
  <#
  .SYNOPSIS
    Group services into dependency layers for parallel execution
    
  .DESCRIPTION
    Returns array of layers (each layer is array of service names).
    For start: layer 0 = no dependencies, layer 1 = depends on layer 0, etc.
    For stop: reverse order (dependents first, then dependencies)
    
  .PARAMETER Reverse
    If true, returns layers in reverse order (for stop: dependents first)
  #>
  $ServiceNames = @($ServiceNames)  # Ensure array
  $IsReverse = $Reverse.IsPresent
  if ($ServiceNames.Count -eq 0) { return @() }
  # Comma keeps the single service wrapped in its layer; without it the caller
  # receives a bare string and indexing yields characters, not services.
  if ($ServiceNames.Count -eq 1) { return , @($ServiceNames) }

  $DependsOn = @{}  # Service -> its dependencies
  $DependentsOf = @{}  # Service -> services that depend on it
  
  # Initialize maps
  foreach ($ServiceName in $ServiceNames) {
    $DependsOn[$ServiceName] = @()
    $DependentsOf[$ServiceName] = @()
  }
  
  # Build dependency graph
  foreach ($ServiceName in $ServiceNames) {
    $Service = Get-ServiceConfig $ServiceName
    foreach ($Dep in @(Get-ServiceProperty $Service 'dependsOn' @()) | Where-Object { $_ }) {
      if ($Dep -in $ServiceNames) {
        $DependsOn[$ServiceName] += $Dep
        $DependentsOf[$Dep] += $ServiceName
      }
    }
  }

  # Build layers by repeatedly taking every service whose prerequisites are
  # already placed. Each pass peels off at least one service, so independent
  # services land in the same layer rather than one per pass.
  $Layers = @()
  $Remaining = @($ServiceNames)

  while ($Remaining.Count -gt 0) {
    $Layer = @()
    foreach ($ServiceName in @($Remaining)) {
      if ($IsReverse) {
        $Unresolved = @(@($DependentsOf[$ServiceName]) | Where-Object { $_ -in $Remaining })
      } else {
        $Unresolved = @(@($DependsOn[$ServiceName]) | Where-Object { $_ -in $Remaining })
      }
      if ($Unresolved.Count -eq 0) { $Layer += $ServiceName }
    }

    if ($Layer.Count -eq 0) {
      Write-Warning "Circular dependency detected among: $($Remaining -join ', ')"
      $Layers += , @($Remaining)
      break
    }

    # The comma is load-bearing: it appends the layer as a single element.
    # Without it the layer is flattened into $Layers and every caller loses the
    # grouping, turning parallel start/stop into one service at a time.
    $Layers += , $Layer
    $Remaining = @($Remaining | Where-Object { $_ -notin $Layer })
  }

  # Same reason one level up: returning $Layers directly would unroll a
  # single-layer result into a flat list of service names.
  return , $Layers
}

function Get-StopOrder([string[]]$ServiceNames) {
  # Legacy function - returns flat array for compatibility
  $Layers = Get-DependencyLayers $ServiceNames -Reverse
  return $Layers | ForEach-Object { $_ }  # Flatten
}

function Stop-One([string]$ServiceName) {
  $Service = Get-ServiceConfig $ServiceName
  $ProcessOrEphemeral = Get-RecordedProcess $ServiceName
  
  # Handle ephemeral services
  if ($ProcessOrEphemeral -eq 'ephemeral') {
    if (-not (Get-ServiceProperty $Service 'shutdownCommand')) {
      Write-Host "ERROR: ephemeral service $ServiceName requires shutdownCommand"
      return
    }
    
    Write-Host "stopping $ServiceName (ephemeral)..."
    $IsElevated = Test-Path (Get-ElevatedPath $ServiceName)
    Invoke-ShutdownCommand $ServiceName $Service $IsElevated
    Remove-ServiceState $ServiceName
    Write-Host "stopped $ServiceName"
    return
  }
  
  # Handle normal services
  $Process = $ProcessOrEphemeral
  if (-not $Process) {
    Remove-ServiceState $ServiceName
    Write-Host "$ServiceName already stopped"
    return
  }

  Write-Host "stopping $ServiceName..."
  $IsElevated = Test-Path (Get-ElevatedPath $ServiceName)

  if (Get-ServiceProperty $Service 'shutdownCommand') {
    Write-Host "executing shutdown command for $ServiceName..."
    Invoke-ShutdownCommand $ServiceName $Service $IsElevated
    $ShutdownWait = [int](Get-Setting 'shutdownWaitDelay' 2000)
    Start-Sleep -Milliseconds $ShutdownWait
    $ShutdownTimeout = [int](Get-Setting 'shutdownTimeout' 5000)
    $Process.WaitForExit($ShutdownTimeout)
  }

  if (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue) {
    Stop-ProcessTree $Process.Id -Elevated:$IsElevated
  }

  Remove-ServiceState $ServiceName
  Write-Host "stopped $ServiceName"
}

function Test-ThreadJobAvailable {
  <#
  .SYNOPSIS
    Whether Start-ThreadJob can be used for parallel start/stop.

  .DESCRIPTION
    ThreadJob is an optimisation, not a requirement: without it, services in
    the same dependency layer start and stop one after another instead of
    concurrently. It ships with PowerShell itself, under the name
    Microsoft.PowerShell.ThreadJob as of 7.6 and ThreadJob before that, so
    this is normally true.

    The module deliberately does not declare ThreadJob in RequiredModules:
    on PowerShell 7.6+ the bundled copy collides with a per-user install of
    the same module, and Install-Module refuses with "commands are already
    available on this system... use -AllowClobber". Requiring it would make
    the documented install command fail for every new user.
  #>
  if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) { return $true }
  foreach ($Name in @('Microsoft.PowerShell.ThreadJob', 'ThreadJob')) {
    if (Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue) {
      try { Import-Module $Name -ErrorAction Stop; return [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) }
      catch { continue }
    }
  }
  return $false
}

function Invoke-ServiceBatch {
  <#
  .SYNOPSIS
    Run one action over several services, in parallel when ThreadJob is present.

  .DESCRIPTION
    Serialises a module-internal command so it can run in a fresh thread: the
    worker needs the module root, state root and config path, because a new
    ThreadJob runspace starts with none of this module's script-scope state.

    Return values of the invoked command are discarded: Start-One reports
    success as a Boolean, which would otherwise surface as stray "True" lines
    in `pp2 start all`. Failures are already reported by the command itself.
  #>
  param(
    [Parameter(Mandatory)][string[]]$ServiceName,
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][hashtable]$Argument
  )

  if ($ServiceName.Count -le 1 -or -not (Test-ThreadJobAvailable)) {
    foreach ($Name in $ServiceName) { & $Command $Name @Argument | Out-Null }
    return
  }

  $ModuleRoot = $script:ModuleRoot
  $Root = $script:Root
  $ConfigPath = $script:ConfigPath

  $Jobs = $ServiceName | ForEach-Object {
    Start-ThreadJob -ScriptBlock {
      param($ServiceName, $Command, $Argument, $ModuleRoot, $Root, $ConfigPath)
      $script:ModuleRoot = $ModuleRoot
      $script:Root = $Root
      $script:ConfigPath = $ConfigPath
      $script:RunDir = Join-Path $Root 'run'
      $script:LogDir = Join-Path $Root 'logs'
      . (Join-Path $ModuleRoot 'Private\pp2-core.ps1')
      Read-Pp2Config
      # Suppress the worker's return value: Start-One reports success as a
      # Boolean, which would otherwise arrive as stray "True" output.
      & $Command $ServiceName @Argument | Out-Null
    } -ArgumentList $_, $Command, $Argument, $ModuleRoot, $Root, $ConfigPath
  }
  $Jobs | Wait-Job | Receive-Job | Out-Null
  $Jobs | Remove-Job
}

function Stop-Many([string[]]$ServiceNames) {
  $ServiceNames = @($ServiceNames)  # Ensure array
  $Layers = Get-DependencyLayers $ServiceNames -Reverse
  foreach ($Layer in $Layers) {
    Invoke-ServiceBatch -ServiceName @($Layer) -Command 'Stop-One' -Argument @{}
  }
}

function Stop-Watchdog {
  $WatchPidPath = Join-Path $RunDir 'watchdog.pid'
  if (-not (Test-Path $WatchPidPath)) {
    Write-Host 'watchdog not running'
    return
  }

  $WatchPid = [int](Get-Content $WatchPidPath -Raw)
  $WatchProcess = Get-Process -Id $WatchPid -ErrorAction SilentlyContinue
  if ($WatchProcess) { & taskkill.exe /PID $WatchPid /F 2>&1 | Out-Null }
  Remove-Item $WatchPidPath -ErrorAction SilentlyContinue
  Write-Host "stopped watchdog pid=$WatchPid"
}

function Start-WatchdogProcess([int]$Interval, [switch]$ReplaceExisting) {
  if (-not $Interval) { $Interval = [int](Get-Setting 'watchdogInterval' 60) }
  $WatchPidPath = Join-Path $RunDir 'watchdog.pid'
  $TempPidPath = Join-Path $RunDir 'watchdog.pid.new'

  if (-not $ReplaceExisting -and (Test-Path $WatchPidPath)) {
    $WatchPid = [int](Get-Content $WatchPidPath -Raw)
    if (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue) {
      Write-Host "watchdog already running pid=$WatchPid"
      return
    }
    Remove-Item $WatchPidPath -ErrorAction SilentlyContinue
  }

  $Process = Start-Process -FilePath (Get-PwshPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ModuleRoot 'lib/pp2-watchdog.ps1'), '-Interval', $Interval, '-Root', $Root, '-ConfigPath', $script:ConfigPath) -WindowStyle Hidden -PassThru
  Set-Content -Path $TempPidPath -Value $Process.Id -NoNewline
  Start-Sleep -Milliseconds 500

  if (-not (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)) {
    Remove-Item $TempPidPath -ErrorAction SilentlyContinue
    Write-Host 'WARNING: watchdog failed to start'
    return
  }

  if ($ReplaceExisting -and (Test-Path $WatchPidPath)) {
    $OldPid = [int](Get-Content $WatchPidPath -Raw)
    if (Get-Process -Id $OldPid -ErrorAction SilentlyContinue) {
      & taskkill.exe /PID $OldPid /F 2>&1 | Out-Null
      Write-Host "restarted watchdog (old=$OldPid -> new=$($Process.Id))"
    }
  }
  else {
    Write-Host "started watchdog pid=$($Process.Id)"
  }

  Move-Item -Path $TempPidPath -Destination $WatchPidPath -Force
}

function Start-WatchdogIfNeeded([string[]]$Name = @('all')) {
  $NeedsWatchdog = $null -ne (Get-ServiceNames $Name |
    Where-Object { Get-ServiceProperty (Get-ServiceConfig $_) 'autoRestart' $false } |
    Select-Object -First 1)
  if ($NeedsWatchdog) { Start-WatchdogProcess -ReplaceExisting }
}

function Stop-LegacyOwners([string]$ServiceName, [bool]$Force) {
  $Service = Get-ServiceConfig $ServiceName
  $Tracked = Get-RecordedProcess $ServiceName
  $OwnerPids = @{}

  foreach ($Port in @(Get-ServiceProperty $Service 'ports' @()) | Where-Object { $_ }) {
    foreach ($Connection in Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
      $OwnerPids[[int]$Connection.OwningProcess] = "port $Port"
    }
  }

  $LegacyProcessName = Get-ServiceProperty $Service 'legacyProcessName'
  if ($LegacyProcessName) {
    Get-Process -Name $LegacyProcessName -ErrorAction SilentlyContinue | ForEach-Object {
      $OwnerPids[[int]$_.Id] = "process $LegacyProcessName"
    }
  }

  foreach ($OwnerPid in $OwnerPids.Keys) {
    if ($Tracked -and $Tracked.Id -eq $OwnerPid) { continue }
    $OwnerProcess = Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue
    if (-not $OwnerProcess) { continue }

    if (-not $Force) {
      Write-Host "WARNING: $($OwnerPids[$OwnerPid]) occupied by $($OwnerProcess.ProcessName) (pid=$OwnerPid)"
      if ((Read-Host 'Kill it? [y/N]') -ne 'y') { continue }
    }

    Write-Host "stopping legacy owner for $ServiceName pid=$OwnerPid"
    Stop-ProcessTree $OwnerPid
  }
}

function Start-One([string]$ServiceName, [bool]$Force, [bool]$NoRetryReset = $false) {
  $ProcessOrEphemeral = Get-RecordedProcess $ServiceName
  if ($ProcessOrEphemeral) {
    Write-Host "$ServiceName already running"
    return $true
  }
  if (-not (Test-Dependencies $ServiceName)) { return $false }

  $Service = Get-ServiceConfig $ServiceName
  $IsEphemeral = (Get-ServiceProperty $Service 'ephemeral' $false) -eq $true
  
  # Validate ephemeral service configuration
  if ($IsEphemeral -and -not (Get-ServiceProperty $Service 'shutdownCommand')) {
    Write-Host "ERROR: ephemeral service $ServiceName requires shutdownCommand"
    return $false
  }
  
  $RequiresElevated = (Get-ServiceProperty $Service 'elevated' $false) -eq $true
  $CurrentlyElevated = Test-IsElevated
  if ($RequiresElevated -and -not $CurrentlyElevated) { Write-Host "WARNING: $ServiceName requires elevated privileges" }

  Stop-LegacyOwners $ServiceName $Force

  $StartArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ModuleRoot 'lib/pp2-run-service.ps1'), '-Name', $ServiceName, '-Root', $Root)
  $OutLog = Get-OutLog $ServiceName
  $ErrLog = Get-ErrLog $ServiceName
  $ActualPid = $null

  if ($RequiresElevated -and -not $CurrentlyElevated) {
    Write-Host "starting $ServiceName with elevated privileges..."
    $TempPidFile = Join-Path $RunDir "$ServiceName.pid.tmp"
    $ScriptPath = Join-Path $RunDir "$ServiceName.start.ps1"
    $LiteralArgs = ($StartArgs | ForEach-Object { ConvertTo-PwshLiteral ([string]$_) }) -join ', '
    @"
`$Process = Start-Process -FilePath $(ConvertTo-PwshLiteral (Get-PwshPath)) -ArgumentList @($LiteralArgs) -WindowStyle Hidden -RedirectStandardOutput $(ConvertTo-PwshLiteral $OutLog) -RedirectStandardError $(ConvertTo-PwshLiteral $ErrLog) -PassThru
Set-Content -Path $(ConvertTo-PwshLiteral $TempPidFile) -Value `$Process.Id -NoNewline
"@ | Set-Content -Path $ScriptPath -Encoding UTF8

    try { Invoke-ElevatedPwsh "& $(ConvertTo-PwshLiteral $ScriptPath)" }
    finally { Remove-Item $ScriptPath -ErrorAction SilentlyContinue }

    for ($i = 0; $i -lt 5; $i++) {
      Start-Sleep -Seconds 1
      if (Test-Path $TempPidFile) {
        $ActualPid = [int](Get-Content $TempPidFile -Raw)
        Remove-Item $TempPidFile -ErrorAction SilentlyContinue
        break
      }
    }

    if (-not $ActualPid) {
      $Ports = @(Get-ServiceProperty $Service 'ports' @()) | Where-Object { $_ }
      if ($Ports.Count -gt 0) { $ActualPid = Get-ProcessByPort $Ports[0] }
    }

    if ($ActualPid) { Set-Content -Path (Get-ElevatedPath $ServiceName) -Value 'true' -NoNewline }
  }
  else {
    $Process = Start-Process -FilePath (Get-PwshPath) -ArgumentList $StartArgs -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -PassThru
    $ActualPid = $Process.Id
    if ($CurrentlyElevated) { Set-Content -Path (Get-ElevatedPath $ServiceName) -Value 'true' -NoNewline }
  }

  if (-not $ActualPid) {
    Write-Host "ERROR: Failed to start $ServiceName (PID tracking failed)"
    return $false
  }

  # Ephemeral services: write 'ephemeral' marker instead of PID
  if ($IsEphemeral) {
    Set-Content -Path (Get-PidPath $ServiceName) -Value 'ephemeral' -NoNewline
    if (-not $NoRetryReset) { Remove-Item (Get-RetryPath $ServiceName) -ErrorAction SilentlyContinue }
    Write-Host "started $ServiceName (ephemeral mode)"
    return $true
  }

  # Normal services: write PID and verify the process actually stays alive.
  Set-Content -Path (Get-PidPath $ServiceName) -Value $ActualPid -NoNewline
  # The retry counter is deliberately preserved on watchdog-driven restarts
  # (NoRetryReset) so that maxRetries can actually be reached.
  if (-not $NoRetryReset) { Remove-Item (Get-RetryPath $ServiceName) -ErrorAction SilentlyContinue }
  $ExitedEarly = Wait-ServiceStartup $ServiceName $ActualPid

  if ($ExitedEarly) {
    Write-Host "WARNING: $ServiceName process (pid=$ActualPid) exited immediately"
    Remove-ServiceState $ServiceName
    return $false
  }

  Write-Host "started $ServiceName pid=$ActualPid"
  return $true
}

function Start-Many([string[]]$ServiceNames, [bool]$Force, [bool]$NoRetryReset = $false) {
  $ServiceNames = @($ServiceNames)  # Ensure array
  $Layers = Get-DependencyLayers $ServiceNames
  foreach ($Layer in $Layers) {
    Invoke-ServiceBatch -ServiceName @($Layer) -Command 'Start-One' `
      -Argument @{ Force = $Force; NoRetryReset = $NoRetryReset }
  }
}

function Set-DefaultDisplayProperty {
  <#
  .SYNOPSIS
    Give a status row a default table view without breaking the pipeline.

  .DESCRIPTION
    Piping to Format-Table inside the function would emit formatting records,
    so `pp2 status | Where-Object ...` and `ConvertTo-Json` would see objects
    that no longer carry the service properties. Declaring a display property
    set instead keeps the objects intact and still renders as a table.
  #>
  param(
    [Parameter(Mandatory)][psobject]$InputObject,
    [Parameter(Mandatory)][string[]]$Property
  )
  $Set = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', $Property)
  $InputObject | Add-Member -MemberType MemberSet -Name PSStandardMembers `
    -Value ([System.Management.Automation.PSMemberInfo[]]@($Set)) -Force
  return $InputObject
}

function Show-ServiceConfig {
  <#
  .SYNOPSIS
    Print one service definition as an aligned field/value table.

  .DESCRIPTION
    ConvertTo-Json is the exact representation and is what -Format json
    returns, but for reading a single definition the JSON punctuation gets in
    the way. Values are rendered compactly so a nested env or arguments list
    stays on one line.
  #>
  param(
    [Parameter(Mandatory)][string]$ServiceName,
    [Parameter(Mandatory)]$Service
  )

  $Properties = @($Service.PSObject.Properties)
  if ($Properties.Count -eq 0) { Write-Host "$ServiceName has no fields"; return }

  $Width = ($Properties.Name | Measure-Object -Property Length -Maximum).Maximum
  foreach ($Property in $Properties) {
    $Value = $Property.Value
    # -InputObject, not a pipe: piping an array enumerates it, so a one-element
    # list would render as its bare element instead of [8080].
    $Text = if ($null -eq $Value) { '' }
    elseif ($Value -is [string]) { $Value }
    else { ConvertTo-Json -InputObject $Value -Compress -Depth 32 }
    Write-Host ("  {0,-$Width}  {1}" -f $Property.Name, $Text)
  }
}

function Show-Status([string[]]$Name = @('all'), [string]$Format = 'table') {
  $Rows = foreach ($ServiceName in Get-ServiceNames $Name) {
    $Service = Get-ServiceConfig $ServiceName
    $ProcessOrEphemeral = Get-RecordedProcess $ServiceName
    $IsEphemeral = $ProcessOrEphemeral -eq 'ephemeral'
    $Process = if ($IsEphemeral) { $null } else { $ProcessOrEphemeral }

    $Ports = @(Get-ServiceProperty $Service 'ports' @())
    $PortStatus = if ($Ports.Count -eq 0) { '-' } else { ($Ports | ForEach-Object { "$($_):$(if (Test-Port $_) { 'open' } else { 'closed' })" }) -join ', ' }
    $Stats = if ($IsEphemeral) { @{ CPU = '-'; Memory = '-' } } else { Get-ProcessStats $Process }

    # Uptime is derived from when pp2 recorded the PID, not the OS process
    # start time, so that PID reuse cannot produce a bogus duration.
    $Uptime = if ($IsEphemeral) { '-' } else { Get-ServiceUptime $ServiceName $Process }

    # Get retry count
    $RetryPath = Get-RetryPath $ServiceName
    $Retries = if (Test-Path $RetryPath) { [int](Get-Content $RetryPath -Raw) } else { 0 }
    $MaxRetries = [int](Get-ServiceProperty $Service 'maxRetries' 3)
    $RetryStatus = if ($Retries -gt 0) { "$Retries/$MaxRetries" } else { '-' }

    Set-DefaultDisplayProperty ([pscustomobject]@{
        Name = $ServiceName
        Status = if ($IsEphemeral) { 'Running (ephemeral)' } elseif ($Process) { 'Running' } else { 'Stopped' }
        Pid = if ($IsEphemeral) { '-' } elseif ($Process) { $Process.Id } else { '' }
        Uptime = $Uptime
        CPU = $Stats.CPU
        Memory = $Stats.Memory
        Ports = $PortStatus
        Retries = $RetryStatus
        AutoRestart = if (Get-ServiceProperty $Service 'autoRestart' $false) { 'yes' } else { 'no' }
        Description = Get-ServiceProperty $Service 'description' ''
      }) -Property @('Name', 'Status', 'Pid', 'Uptime', 'CPU', 'Memory', 'Ports', 'Retries', 'AutoRestart', 'Description')
  }

  if ($Format -eq 'json') { $Rows | ConvertTo-Json -Depth 2 }
  else { $Rows }
}

function Watch-Status([string[]]$Name, [string]$Format, [int]$Interval) {
  while ($true) {
    Clear-Host
    Write-Host "$(Get-Date -Format 'HH:mm:ss') Service Status (Ctrl+C to exit)"
    Show-Status $Name $Format
    Start-Sleep -Seconds $Interval
  }
}

function Show-Logs([string]$ServiceName, [int]$Tail, [bool]$WatchMode) {
  $WatchLogsPath = Join-Path $script:ModuleRoot 'lib/pp2-watch-logs.ps1'
  if ($WatchMode) { & $WatchLogsPath -ServiceName $ServiceName -LogDir $script:LogDir -Tail $Tail -Watch }
  else { & $WatchLogsPath -ServiceName $ServiceName -LogDir $script:LogDir -Tail $Tail }
}

function Show-Monit([string[]]$Name, [int]$Cols, [switch]$Interactive) {
  $ServicesToMonitor = Get-ServiceNames $Name
  if ($ServicesToMonitor.Count -eq 0) { Write-Host 'No services to monitor'; return }

  # Interactive service selection (only when no Name arg specified)
  if ($Interactive) {
    $allServices = $ServicesToMonitor
    if ($allServices.Count -eq 1) {
      Write-Host "Only one service available: $($allServices[0])"
    } else {
      $idx = 0
      $allServices | ForEach-Object { Write-Host "  [$($idx+1)] $_"; $idx++ }
      Write-Host ''
      $Selection = Read-Host "Select services (comma-separated numbers, or * for all)"
      if ($Selection -eq '*' -or [string]::IsNullOrWhiteSpace($Selection)) { $ServicesToMonitor = $allServices }
      else {
        $parsed = @()
        $invalid = @()
        foreach ($token in ($Selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })) {
          $num = 0
          if ([int]::TryParse($token, [ref]$num)) {
            if ($num -ge 1 -and $num -le $allServices.Count) { $parsed += $allServices[$num - 1] }
            else { $invalid += $token }
          } else { $invalid += $token }
        }
        if ($invalid.Count -gt 0) { Write-Host "Ignored invalid input: $($invalid -join ', ')" -ForegroundColor Yellow }
        $ServicesToMonitor = $parsed
        if ($ServicesToMonitor.Count -eq 0) { Write-Host 'No services selected'; return }
      }
    }
  }

  Show-MonitDashboard -Services $ServicesToMonitor -Cols $Cols
}

function Show-MonitDashboard {
  param(
    [Parameter(Mandatory)][string[]]$Services,
    [int]$Cols = 3
  )

  $LogDir = $script:LogDir
  $ServiceCount = $Services.Count
  $MaxCols = [Math]::Max(1, [Math]::Min($Cols, $ServiceCount))

  # Ctrl+C handler.
  #
  # Subscribed through the add_/remove_ accessors rather than the `+=` operator.
  # CancelKeyPress is a .NET event, and under Set-StrictMode -Version Latest
  # (set at the top of this file) PowerShell refuses to read an event as if it
  # were a property, so plain `[Console]::CancelKeyPress += $h` throws
  # PropertyNotFoundException. Calling the accessor is a method invocation and
  # is unaffected by strict mode.
  $script:monitExit = $false
  # $EventSource is part of the delegate signature and carries no information here.
  $cancelHandler = [ConsoleCancelEventHandler]{ param($EventSource, $CancelArgs) $CancelArgs.Cancel = $true; $script:monitExit = $true }
  [Console]::add_CancelKeyPress($cancelHandler)

  # Per-service state: file positions + circular buffer
  $state = @{}
  foreach ($svc in $Services) {
    $state[$svc] = @{
      outPos = 0; errPos = 0
      lines = [System.Collections.Generic.List[string]]::new()
      colors = [System.Collections.Generic.List[ConsoleColor]]::new()
    }
  }

  $origVis = try { [Console]::CursorVisible } catch { $true }
  $origBg = [Console]::BackgroundColor

  # The dashboard paints by absolute cursor positioning, which needs a real
  # console. With output redirected (| Out-File, a CI job, a scheduled task)
  # every SetCursorPosition throws, so say so once instead of dying mid-draw.
  $cursorUsable = $true
  try { [Console]::SetCursorPosition(0, 0) } catch { $cursorUsable = $false }

  try {
    if (-not $cursorUsable) {
      Write-Host "pp2 monit needs an interactive console; output is redirected." -ForegroundColor Yellow
      Write-Host "Run it directly in a terminal window." -ForegroundColor Yellow
      return
    }

    # Console cursor control is unavailable when the host has no console; the
    # dashboard still works, just without hiding the cursor.
    try { [Console]::CursorVisible = $false } catch { Write-Debug "monit: cannot hide cursor: $_" }
    Clear-Host

    while (-not $script:monitExit) {
      $w = [Console]::WindowWidth
      $h = [Console]::WindowHeight
      $rows = [Math]::Ceiling($ServiceCount / $MaxCols)
      $cellW = [Math]::Max(10, [Math]::Floor($w / $MaxCols))
      $cellH = [Math]::Max(2, [Math]::Floor(($h - 1) / $rows))
      $contentH = $cellH - 1

      # Read new log content for each service
      foreach ($svc in $Services) {
        $s = $state[$svc]

        foreach ($stream in @(
          @{ path = Join-Path $LogDir "$svc.out.log"; posRef = 'outPos'; color = [ConsoleColor]::Green },
          @{ path = Join-Path $LogDir "$svc.err.log"; posRef = 'errPos'; color = [ConsoleColor]::Yellow }
        )) {
          try {
            $fs = [System.IO.FileStream]::new($stream.path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $len = $fs.Length
            $pos = $s[$stream.posRef]
            if ($len -gt $pos) {
              $null = $fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
              $reader = [System.IO.StreamReader]::new($fs)
              while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                $s.lines.Add($line)
                $s.colors.Add($stream.color)
              }
              $s[$stream.posRef] = $fs.Position
              $reader.Close()
            } elseif ($len -lt $pos) {
              $s[$stream.posRef] = 0
              $fs.Close()
            } else {
              $fs.Close()
            }
          } catch {
            # A log file that does not exist yet is normal for a service that
            # has never produced output; anything else is worth surfacing.
            if ($_.Exception -isnot [System.IO.FileNotFoundException]) {
              Write-Debug "monit read $($stream.path): $_"
            }
          }
        }

        # Trim buffer to avoid unbounded growth
        if ($s.lines.Count -gt 1000) {
          $s.lines.RemoveRange(0, $s.lines.Count - 1000)
          $s.colors.RemoveRange(0, $s.colors.Count - 1000)
        }
      }

      # Draw grid (iterate full rows×cols to clean unused cells)
      for ($ri = 0; $ri -lt $rows; $ri++) {
        for ($ci = 0; $ci -lt $MaxCols; $ci++) {
          $i = $ri * $MaxCols + $ci
          $svc = if ($i -lt $ServiceCount) { $Services[$i] } else { $null }
          $x = $ci * $cellW
          $y = $ri * $cellH

          # Header
          [Console]::SetCursorPosition($x, $y)
          if ($svc) {
            $header = " $svc "
            $header = $header.PadRight($cellW - 1, '─')
            if ($header.Length -gt $cellW) { $header = $header.Substring(0, $cellW) }
            [Console]::ForegroundColor = 'Cyan'
            [Console]::BackgroundColor = 'DarkBlue'
          } else {
            $header = ''.PadRight($cellW)
            [Console]::ForegroundColor = 'DarkGray'
            [Console]::BackgroundColor = $origBg
          }
          [Console]::Write($header)
          [Console]::BackgroundColor = $origBg

          # Content
          $s = if ($svc) { $state[$svc] } else { $null }
          $bufCount = if ($s) { $s.lines.Count } else { 0 }
          $startIdx = [Math]::Max(0, $bufCount - $contentH)

          for ($li = 0; $li -lt $contentH; $li++) {
            [Console]::SetCursorPosition($x, $y + 1 + $li)
            $bi = $startIdx + $li
            if ($s -and $bi -lt $bufCount) {
              $text = $s.lines[$bi]
              if ($text.Length -gt $cellW) { $text = $text.Substring(0, $cellW - 1) + '…' }
              [Console]::ForegroundColor = $s.colors[$bi]
              [Console]::Write($text.PadRight($cellW))
            } else {
              [Console]::Write(''.PadRight($cellW))
            }
          }
        }
      }

      # Status bar
      [Console]::SetCursorPosition(0, $h - 1)
      [Console]::ForegroundColor = 'DarkGray'
      $status = " pp2-monit | $ServiceCount services | Ctrl+C to exit ".PadRight($w, '─')
      if ($status.Length -gt $w) { $status = $status.Substring(0, $w) }
      [Console]::Write($status)

      Start-Sleep -Milliseconds 200
    }
  }
  finally {
    [Console]::remove_CancelKeyPress($cancelHandler)
    try { [Console]::CursorVisible = $origVis } catch { Write-Debug "monit: cannot restore cursor: $_" }
    try { [Console]::ResetColor() } catch { Write-Debug "monit: cannot reset color: $_" }
    Write-Host "pp2-monit: exited" -ForegroundColor DarkGray
    if ($cursorUsable) {
      Start-Sleep -Milliseconds 200
      Clear-Host
    }
  }
}

function Show-WatchdogStatus {
  $WatchPidPath = Join-Path $RunDir 'watchdog.pid'
  if (-not (Test-Path $WatchPidPath)) { Write-Host 'watchdog not running'; return }

  $WatchPid = [int](Get-Content $WatchPidPath -Raw)
  if (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue) { Write-Host "watchdog running pid=$WatchPid" }
  else { Write-Host 'watchdog not running (stale PID file)' }
}

function Install-StartupTask([string]$ModuleManifestPath, [string]$StateRoot, [string]$ConfigPath) {
  $ConfigArg = if ($ConfigPath) { " -Config $(ConvertTo-PwshLiteral $ConfigPath)" } else { '' }
  $Command = "& { `$env:PP2_HOME = $(ConvertTo-PwshLiteral $StateRoot); Import-Module -Name $(ConvertTo-PwshLiteral $ModuleManifestPath) -Force; pp2 start all$ConfigArg }"
  $ActionDef = New-ScheduledTaskAction -Execute (Get-PwshPath) -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$Command`""
  $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $ActionDef -Trigger $Trigger -Principal $Principal -Force | Out-Null
  Write-Host "installed startup task: $TaskName"
}

function Uninstall-StartupTask {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "uninstalled startup task: $TaskName"
}
