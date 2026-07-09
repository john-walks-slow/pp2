#Requires -Version 7.0
<#
.SYNOPSIS
    Build and optionally publish pp2 module

.DESCRIPTION
    Validates the module with PSScriptAnalyzer, tests module manifest,
    and optionally publishes to PowerShell Gallery.

.EXAMPLE
    .\build.ps1
    Build and validate the module

.EXAMPLE
    .\build.ps1 -Publish -NuGetApiKey $env:NUGET_API_KEY
    Build and publish to PowerShell Gallery

.EXAMPLE
    .\build.ps1 -Version 1.1.0 -Publish -NuGetApiKey $env:NUGET_API_KEY
    Build with specific version and publish
#>

param(
    [string]$Version = '1.0.0',
    [switch]$Publish,
    [string]$NuGetApiKey,
    [string]$Repository = 'PSGallery'
)

$ErrorActionPreference = 'Stop'
$ModuleRoot = Join-Path $PSScriptRoot 'src\pp2'
$ModuleName = 'pp2'

Write-Host "Building $ModuleName v$Version" -ForegroundColor Cyan
Write-Host ('=' * 50) -ForegroundColor DarkGray

# 1. Update version in psd1
Write-Host "[1/4] Updating version in manifest..." -ForegroundColor Cyan
$Psd1Path = Join-Path $ModuleRoot "$ModuleName.psd1"
$Psd1Content = Get-Content $Psd1Path -Raw
$Psd1Content = $Psd1Content -replace "ModuleVersion\s*=\s*'[\d.]+'", "ModuleVersion = '$Version'"
Set-Content -Path $Psd1Path -Value $Psd1Content -NoNewline

# 2. Run PSScriptAnalyzer
Write-Host "[2/4] Running PSScriptAnalyzer..." -ForegroundColor Cyan
$Analysis = Invoke-ScriptAnalyzer -Path $ModuleRoot -Recurse -Severity Warning -ErrorAction SilentlyContinue
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
    if ($Errors) {
        throw "PSScriptAnalyzer found $($Errors.Count) error(s). Fix before publishing."
    }
} else {
    Write-Host "  No issues found." -ForegroundColor Green
}

# 3. Test module manifest
Write-Host "[3/4] Validating module manifest..." -ForegroundColor Cyan
$Manifest = Test-ModuleManifest -Path $Psd1Path -ErrorAction Stop
Write-Host "  Module: $($Manifest.Name) v$($Manifest.Version)" -ForegroundColor Green
Write-Host "  Author: $($Manifest.Author)" -ForegroundColor Gray
Write-Host "  Functions: $($Manifest.ExportedFunctions.Count)" -ForegroundColor Gray

# 4. Publish
if ($Publish) {
    Write-Host "[4/4] Publishing to $Repository..." -ForegroundColor Cyan

    if (-not $NuGetApiKey) {
        throw "NuGetApiKey is required for publishing."
    }

    Publish-Module -Path $ModuleRoot `
        -NuGetApiKey $NuGetApiKey `
        -Repository $Repository `
        -Force

    Write-Host "  Published successfully!" -ForegroundColor Green
} else {
    Write-Host "[4/4] Skipped (use -Publish to publish)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Build complete: $ModuleName v$Version" -ForegroundColor Green
