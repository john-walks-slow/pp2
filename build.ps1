#Requires -Version 7.0
param(
    [string]$Version = '1.0.0',
    [switch]$Lint,
    [switch]$Test,
    [switch]$Build,
    [switch]$Publish,
    [string]$NuGetApiKey,
    [string]$Repository = 'PSGallery'
)

$ErrorActionPreference = 'Stop'
$ModuleRoot = Join-Path $PSScriptRoot 'src\pp2'
$ModuleName = 'pp2'
$OutputDir = Join-Path $PSScriptRoot 'output'
$StagingDir = Join-Path $OutputDir $ModuleName

# Default: run everything except publish
$RunAll = -not $Lint -and -not $Test -and -not $Build -and -not $Publish

# Resolve dependency
function Resolve-BuildDependency {
    param([string]$Name, [string]$MinimumVersion = '0.0.0')
    $installed = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]$MinimumVersion } |
        Select-Object -First 1
    if (-not $installed) {
        Write-Host "  Installing $Name..." -ForegroundColor Yellow
        Install-Module -Name $Name -Scope CurrentUser -Force -SkipPublisherCheck
    }
}

function Step-Lint {
    Write-Host "[Lint] Running PSScriptAnalyzer..." -ForegroundColor Cyan
    Resolve-BuildDependency -Name PSScriptAnalyzer -MinimumVersion '1.21.0'

    $Analysis = Invoke-ScriptAnalyzer -Path $ModuleRoot -Recurse -Severity Warning -Settings (Join-Path $ModuleRoot 'PSScriptAnalyzerSettings.psd1') -ErrorAction SilentlyContinue
    if ($Analysis) {
        $Errors = $Analysis | Where-Object Severity -eq 'Error'
        $Warnings = $Analysis | Where-Object Severity -eq 'Warning'
        if ($Errors) {
            Write-Host "  Errors: $($Errors.Count)" -ForegroundColor Red
            $Errors | Format-Table -AutoSize
        }
        if ($Warnings) {
            Write-Host "  Warnings: $($Warnings.Count)" -ForegroundColor Yellow
            $Warnings | Format-Table -AutoSize
        }
        if ($Errors) { throw "PSScriptAnalyzer found $($Errors.Count) error(s)." }
    } else {
        Write-Host "  No issues found." -ForegroundColor Green
    }
}

function Step-Test {
    Write-Host "[Test] Running Pester tests..." -ForegroundColor Cyan
    Resolve-BuildDependency -Name Pester -MinimumVersion '5.5.0'

    $TestDir = Join-Path $PSScriptRoot 'tests'
    $Config = New-PesterConfiguration
    $Config.Run.Path = $TestDir
    $Config.Run.PassThru = $true
    $Config.TestResult.Enabled = $true
    $Config.TestResult.OutputPath = Join-Path $OutputDir 'test-results.xml'
    $Config.CodeCoverage.Enabled = $true
    $Config.CodeCoverage.OutputPath = Join-Path $OutputDir 'coverage.xml'
    $Config.CodeCoverage.Path = $ModuleRoot

    $Result = Invoke-Pester -Configuration $Config
    if ($Result.FailedCount -gt 0) { throw "$($Result.FailedCount) test(s) failed." }
    Write-Host "  All $($Result.PassedCount) tests passed." -ForegroundColor Green
}

function Step-Build {
    Write-Host "[Build] Staging module to output/..." -ForegroundColor Cyan

    if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }

    # Copy source to staging, excluding dev-only files
    $ExcludeFiles = @(
        'PSScriptAnalyzerSettings.psd1',
        'services.example.json'
    )
    Get-ChildItem -Path $ModuleRoot -Exclude $ExcludeFiles | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $StagingDir -Recurse -Force
    }

    # Update version in staged manifest
    $Psd1Path = Join-Path $StagingDir "$ModuleName.psd1"
    $Psd1Content = Get-Content $Psd1Path -Raw
    $Psd1Content = $Psd1Content -replace "ModuleVersion\s*=\s*'[\d.]+'", "ModuleVersion = '$Version'"
    Set-Content -Path $Psd1Path -Value $Psd1Content -NoNewline

    # Validate manifest
    $Manifest = Test-ModuleManifest -Path $Psd1Path -ErrorAction Stop
    Write-Host "  Module: $($Manifest.Name) v$($Manifest.Version)" -ForegroundColor Green
    Write-Host "  Author: $($Manifest.Author)" -ForegroundColor Gray
    Write-Host "  Functions: $($Manifest.ExportedFunctions.Count)" -ForegroundColor Gray
}

function Step-Publish {
    Write-Host "[Publish] Publishing to $Repository..." -ForegroundColor Cyan
    if (-not $NuGetApiKey) { throw "NuGetApiKey is required for publishing." }

    $Psd1Path = Join-Path $StagingDir "$ModuleName.psd1"
    if (-not (Test-Path $Psd1Path)) { throw "Build output not found. Run -Build first." }

    Publish-Module -Path $StagingDir -NuGetApiKey $NuGetApiKey -Repository $Repository -Force
    Write-Host "  Published $ModuleName v$Version to $Repository" -ForegroundColor Green
}

# Main
Write-Host "pp2 Build v$Version" -ForegroundColor White
Write-Host ('=' * 40) -ForegroundColor DarkGray

if ($RunAll -or $Lint) { Step-Lint }
if ($RunAll -or $Test) { Step-Test }
if ($RunAll -or $Build) { Step-Build }
if ($Publish) { Step-Publish }

Write-Host ""
Write-Host "Done: $ModuleName v$Version" -ForegroundColor Green
