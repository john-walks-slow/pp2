#Requires -Version 7.0
<#
.SYNOPSIS
    Run the pp2 test suite. Wrapper around Invoke-Pester that prints a compact
    summary and exits non-zero on failure (for CI).
#>
param(
    [ValidateSet('Unit', 'Integration', 'All')]
    [string]$Scope = 'All',
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
$TestsRoot = $PSScriptRoot

$Path = switch ($Scope) {
    'Unit' { Join-Path $TestsRoot 'Unit' }
    'Integration' { Join-Path $TestsRoot 'Integration' }
    default { $TestsRoot }
}

$Config = New-PesterConfiguration
$Config.Run.Path = $Path
$Config.Run.PassThru = $true
$Config.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }

$Result = Invoke-Pester -Configuration $Config

Write-Host ''
Write-Host "Passed: $($Result.PassedCount)  Failed: $($Result.FailedCount)  Skipped: $($Result.SkippedCount)" -ForegroundColor $(if ($Result.FailedCount) { 'Red' } else { 'Green' })

foreach ($Failure in $Result.Failed) {
    Write-Host "  FAIL [$($Failure.Describe)] $($Failure.Name)" -ForegroundColor Red
    $Message = ($Failure.ErrorRecord.Exception.Message -replace '\s+', ' ').Trim()
    if ($Message) { Write-Host "       $Message" -ForegroundColor DarkGray }
}

exit $(if ($Result.FailedCount) { 1 } else { 0 })
