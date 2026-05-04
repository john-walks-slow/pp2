#Requires -Version 7.0
<#
.SYNOPSIS
    Build pp2 nupkg package

.DESCRIPTION
    Creates a properly structured nupkg for the pp2 module as a zip file.
    This method works around PowerShellGet Publish-Module issues.
#>

param(
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
$ModuleRoot = $PSScriptRoot
$ModuleName = 'pp2'

$PublishDir = Join-Path $ModuleRoot "module\$ModuleName\_publish"

Write-Host "Building pp2 nupkg v$Version" -ForegroundColor Cyan

# Ensure publish directory exists
if (-not (Test-Path $PublishDir)) {
    New-Item -ItemType Directory -Path $PublishDir -Force | Out-Null
}

# Clean old nupkg
Get-ChildItem $PublishDir -Filter "$ModuleName.*.nupkg" | Remove-Item -Force

# Create temp staging directory
$StageDir = Join-Path $env:TEMP "pp2-stage-$Version"
if (Test-Path $StageDir) { Remove-Item $StageDir -Recurse -Force }
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

# Copy module files (exclude dev directories and nuspec files)
$SourceDir = Join-Path $ModuleRoot "module\$ModuleName"
$ExcludeDirs = @('_publish', '_stage', 'logs', 'run', 'nuspec.xml', 'pp2.nuspec')

Get-ChildItem -Path $SourceDir -Exclude $ExcludeDirs | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $StageDir -Recurse -Force
}

# Update version in psd1
$Psd1Path = Join-Path $StageDir "$ModuleName.psd1"
$Psd1Content = Get-Content $Psd1Path -Raw
$Psd1Content = $Psd1Content -replace "ModuleVersion\s*=\s*'[\d.]+'", "ModuleVersion = '$Version'"
Set-Content -Path $Psd1Path -Value $Psd1Content -NoNewline

# Create nupkg (just a zip with .nupkg extension)
$NupkgPath = Join-Path $PublishDir "$ModuleName.$Version.nupkg"

# Use Compress-Archive to create zip, then rename to nupkg
$TempZip = Join-Path $env:TEMP "pp2-temp.zip"
Compress-Archive -Path "$StageDir\*" -DestinationPath $TempZip -Force
Move-Item $TempZip $NupkgPath -Force

# Cleanup staging
Remove-Item $StageDir -Recurse -Force -ErrorAction SilentlyContinue

# Verify
$Nupkg = Get-Item $NupkgPath
Write-Host "Created: $($Nupkg.Name)" -ForegroundColor Green
Write-Host "Size: $([math]::Round($Nupkg.Length / 1KB, 2)) KB" -ForegroundColor White

Write-Host "Done" -ForegroundColor Green