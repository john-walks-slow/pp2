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

    # The Test phase runs against the live source. Invoke the wrapper so the
    # same script (and the same -Scope, when used) drives unit and integration
    # tests on a developer's machine and on CI.
    $Wrapper = Join-Path $PSScriptRoot 'tests\run-tests.ps1'
    if (-not (Test-Path $Wrapper)) {
        throw "Test wrapper not found: $Wrapper"
    }
    & $Wrapper -Scope All
    if ($LASTEXITCODE -ne 0) { throw "Pester reported failures (exit $LASTEXITCODE)." }

    $Result = Get-ChildItem (Join-Path $OutputDir 'test-results.xml') -EA SilentlyContinue
    Write-Host "  All tests passed." -ForegroundColor Green
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

    $Psd1Path = Join-Path $StagingDir "$ModuleName.psd1"
    if (-not (Test-Path $Psd1Path)) { throw "Build output not found. Run -Build first." }

    # Publish from the staging directory, never from src/. Staging has already
    # had the dev-only files stripped; publishing src/ directly would ship
    # PSScriptAnalyzerSettings.psd1 and services.example.json to consumers.
    #
    # Publish-PSResource (PSResourceGet) is used instead of Publish-Module
    # (PowerShellGet v2): the latter shells out to nuget.exe and parses its
    # stdout with a hardcoded English regex, which breaks on non-English
    # Windows ("Cannot index into a null array"). PSResourceGet packs
    # in-process and is locale-independent.
    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet)) {
        throw "Microsoft.PowerShell.PSResourceGet is required to publish. Install-Module Microsoft.PowerShell.PSResourceGet -Scope CurrentUser"
    }
    Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop

    $Target = Get-PSResourceRepository -Name $Repository -ErrorAction SilentlyContinue
    if (-not $Target) {
        throw "Repository '$Repository' is not registered. Register it with Register-PSResourceRepository, or use -Repository PSGallery."
    }

    # A file-based repository needs no credentials, which is what makes
    # "publish to a folder, then Install-PSResource" a usable install path for
    # people who do not want the public Gallery. Only a remote repository
    # requires a key.
    $IsLocal = $Target.Uri.IsFile
    if (-not $IsLocal -and -not $NuGetApiKey) {
        throw "NuGetApiKey is required to publish to the remote repository '$Repository'."
    }

    # The Gallery rejects a duplicate id+version with HTTP 409 and the version
    # cannot be overwritten. Treat that as "already released" rather than a
    # failure, so re-running a tag build is a no-op instead of a red run.
    # A file repository overwrites in place, so re-publishing there is expected
    # to just work and must not be short-circuited.
    if (-not $IsLocal) {
        $Existing = Find-PSResource -Name $ModuleName -Repository $Repository -Version $Version -ErrorAction SilentlyContinue
        if ($Existing) {
            Write-Host "  $ModuleName v$Version is already published to $Repository; nothing to do." -ForegroundColor Yellow
            return
        }
    }

    $PublishArgs = @{
        Path                  = $StagingDir
        Repository            = $Repository
        SkipDependenciesCheck = $true
    }
    if ($NuGetApiKey) { $PublishArgs.ApiKey = $NuGetApiKey }

    Publish-PSResource @PublishArgs
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
