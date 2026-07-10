#Requires -Version 7.0
param(
    [switch]$Uninstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ModuleName = 'pp2'
$SourcePath = Join-Path $PSScriptRoot 'src\pp2'

function Get-UserModulePath {
    $Paths = [Environment]::GetEnvironmentVariable('PSModulePath') -split [IO.Path]::PathSeparator
    foreach ($Path in $Paths) {
        if ($Path -match 'Program Files|Windows|system32') { continue }
        if (Test-Path $Path) {
            try {
                $TestFile = Join-Path $Path "write-test.tmp"
                [IO.File]::WriteAllText($TestFile, 'test')
                Remove-Item $TestFile -Force
                return $Path
            } catch { continue }
        }
    }
    $DocsPath = Join-Path $HOME 'Documents\PowerShell\Modules'
    if (-not (Test-Path $DocsPath)) {
        New-Item -ItemType Directory -Path $DocsPath -Force | Out-Null
    }
    return $DocsPath
}

function Install-ModuleLocally {
    $ModulePath = Get-UserModulePath
    $TargetPath = Join-Path $ModulePath $ModuleName

    Write-Host "Source: $SourcePath" -ForegroundColor DarkGray
    Write-Host "Target: $TargetPath" -ForegroundColor DarkGray

    $Existing = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue
    if ($Existing -and -not $Force) {
        Write-Host "pp2 ($($Existing.Version)) is already installed" -ForegroundColor Yellow
        Write-Host "Use -Force to reinstall" -ForegroundColor Yellow
        return
    }

    if ($Existing -and $Force) {
        Write-Host "Removing old version..." -ForegroundColor Cyan
        Remove-Item -Path $Existing.ModuleBase -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Installing..." -ForegroundColor Cyan
    if (Test-Path $TargetPath) {
        Remove-Item $TargetPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null

    # Copy source, excluding dev-only files
    $ExcludeFiles = @(
        'PSScriptAnalyzerSettings.psd1',
        'services.example.json'
    )
    Get-ChildItem -Path $SourcePath -Exclude $ExcludeFiles | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $TargetPath -Recurse -Force
    }

    $Installed = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue
    if ($Installed) {
        Write-Host ""
        Write-Host "Successfully installed pp2 $($Installed.Version)" -ForegroundColor Green
        Write-Host "Run 'Import-Module pp2' then 'pp2 help' to get started" -ForegroundColor White
    } else {
        throw "Installation verification failed"
    }
}

function Uninstall-Module {
    $Existing = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue
    if (-not $Existing) {
        Write-Host "pp2 is not installed" -ForegroundColor Yellow
        return
    }

    Write-Host "Uninstalling pp2..." -ForegroundColor Cyan
    Remove-Item -Path $Existing.ModuleBase -Recurse -Force
    $ParentDir = Split-Path $Existing.ModuleBase -Parent
    if ((Get-ChildItem $ParentDir -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $ParentDir -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Done" -ForegroundColor Green
}

Write-Host ""
Write-Host "pp2 Installer" -ForegroundColor White
Write-Host "=============" -ForegroundColor DarkGray

if ($Uninstall) {
    Uninstall-Module
} else {
    Install-ModuleLocally
}
