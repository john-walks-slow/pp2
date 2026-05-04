#Requires -Version 7.0
<#
.SYNOPSIS
    Install pp2 module from local nupkg

.DESCRIPTION
    Installs pp2 from the bundled nupkg by extracting it to the PowerShell module path.
    This is a reliable method that works around PowerShellGet repository issues.

.EXAMPLE
    .\install.ps1
    Install pp2 module

.EXAMPLE
    .\install.ps1 -Force
    Force reinstall

.EXAMPLE
    .\install.ps1 -Uninstall
    Remove pp2 module
#>

param(
    [switch]$Uninstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ModuleRoot = $PSScriptRoot
$ModuleName = 'pp2'

function Get-NupkgPath {
    $PublishDir = Join-Path $ModuleRoot "module\$ModuleName\_publish"
    $Nupkg = Get-ChildItem -Path $PublishDir -Filter "$ModuleName.*.nupkg" -ErrorAction SilentlyContinue | 
              Sort-Object LastWriteTime -Descending | 
              Select-Object -First 1
    return $Nupkg
}

function Get-UserModulePath {
    # Find first user-writable path in PSModulePath
    $Paths = [Environment]::GetEnvironmentVariable('PSModulePath') -split ';'
    foreach ($Path in $Paths) {
        # Skip system paths (Program Files, Windows)
        if ($Path -match 'Program Files|Windows|system32') { continue }
        if (Test-Path $Path) {
            # Check if writable
            try {
                $TestFile = Join-Path $Path "write-test.tmp"
                [IO.File]::WriteAllText($TestFile, 'test')
                Remove-Item $TestFile -Force
                return $Path
            } catch { continue }
        }
    }
    # Fallback to Documents
    $DocsPath = Join-Path $HOME 'Documents\PowerShell\Modules'
    if (-not (Test-Path $DocsPath)) {
        New-Item -ItemType Directory -Path $DocsPath -Force | Out-Null
    }
    return $DocsPath
}

function Install-FromNupkg {
    $Nupkg = Get-NupkgPath
    
    if (-not $Nupkg) {
        Write-Host "No nupkg found. Building package..." -ForegroundColor Yellow
        & (Join-Path $ModuleRoot "build.ps1")
        $Nupkg = Get-NupkgPath
        if (-not $Nupkg) {
            throw "Failed to build nupkg"
        }
    }
    
    $Version = $Nupkg.Name -replace "$ModuleName\.(.+)\.nupkg", '$1'
    $ModulePath = Get-UserModulePath
    $TargetPath = Join-Path $ModulePath "$ModuleName\$Version"
    
    Write-Host "Package: $($Nupkg.Name)" -ForegroundColor Cyan
    Write-Host "Target: $TargetPath" -ForegroundColor DarkGray
    
    # Check for existing installation
    $Existing = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue
    if ($Existing -and -not $Force) {
        Write-Host "pp2 ($($Existing.Version)) is already installed" -ForegroundColor Yellow
        Write-Host "Use -Force to reinstall" -ForegroundColor Yellow
        return
    }
    
    # Remove old installation if Force
    if ($Existing -and $Force) {
        Write-Host "Removing old version..." -ForegroundColor Cyan
        Remove-Item -Path $Existing.ModuleBase -Recurse -Force -ErrorAction SilentlyContinue
        # Also remove parent if empty
        $ParentDir = Split-Path $Existing.ModuleBase -Parent
        if ((Get-ChildItem $ParentDir -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $ParentDir -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Extract nupkg (nupkg is just a zip file)
    Write-Host "Installing..." -ForegroundColor Cyan
    
    # Create target directory
    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    
    # Extract nupkg contents (exclude package metadata files)
    $TempExtract = Join-Path $env:TEMP "pp2-extract-$Version"
    if (Test-Path $TempExtract) { Remove-Item $TempExtract -Recurse -Force }
    
    Expand-Archive -Path $Nupkg.FullName -DestinationPath $TempExtract -Force
    
    # Copy module files (exclude nuspec and nupkg)
    Get-ChildItem -Path $TempExtract -Exclude "*.nuspec", "*.nupkg" | 
        Copy-Item -Destination $TargetPath -Recurse -Force
    
    # Cleanup temp
    Remove-Item $TempExtract -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "Successfully installed pp2 $Version" -ForegroundColor Green
    Write-Host "Run 'pp2 help' to get started" -ForegroundColor White
}

function Uninstall-Module {
    $Existing = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue
    if (-not $Existing) {
        Write-Host "pp2 is not installed" -ForegroundColor Yellow
        return
    }
    
    Write-Host "Uninstalling pp2..." -ForegroundColor Cyan
    Remove-Item -Path $Existing.ModuleBase -Recurse -Force
    
    # Remove parent version folder if empty
    $ParentDir = Split-Path $Existing.ModuleBase -Parent
    if ((Get-ChildItem $ParentDir -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $ParentDir -Force -ErrorAction SilentlyContinue
    }
    
    Write-Host "Done" -ForegroundColor Green
}

# Main
Write-Host ""
Write-Host "pp2 Installer" -ForegroundColor White
Write-Host "=============" -ForegroundColor DarkGray

if ($Uninstall) {
    Uninstall-Module
} else {
    Install-FromNupkg
}