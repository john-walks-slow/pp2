<#
.SYNOPSIS
    pp2 installation script - download, setup, and configure pp2

.DESCRIPTION
    This script handles the full pp2 installation:
    - Downloads pp2 from GitHub
    - Checks and installs prerequisites (PowerShell 7, Windows Terminal, sudo)
    - Sets up pp2 alias in PowerShell profile
    - Supports uninstall

.EXAMPLE
    # Install pp2 (interactive)
    irm https://raw.githubusercontent.com/your-username/services/main/install.ps1 | iex
    
    # Install with auto-prerequisites
    irm https://raw.githubusercontent.com/your-username/services/main/install.ps1 | iex
    # Then in the prompt: -InstallPrerequisites
    
    # Or directly:
    pwsh -c "irm https://raw.githubusercontent.com/your-username/services/main/install.ps1 | iex" -InstallPrerequisites

.PARAMETER InstallPrerequisites
    Automatically install missing prerequisites via winget

.PARAMETER InstallDir
    Installation directory (default: D:\pp2 or $HOME\pp2)

.PARAMETER Force
    Skip confirmation prompts

.PARAMETER Uninstall
    Remove pp2 installation

.PARAMETER RepoUrl
    GitHub repository URL (default: https://github.com/your-username/services)
#>

param(
    [switch]$InstallPrerequisites,
    [string]$InstallDir = '',
    [switch]$Force,
    [switch]$Uninstall,
    [string]$RepoUrl = 'https://github.com/john-walks-slow/pp2'
)

$ErrorActionPreference = 'Stop'
$DefaultInstallDirs = @('D:\pp2', 'C:\Services', "$HOME\pp2")

function Write-Status([string]$Message, [string]$Color = 'White') {
    Write-Host $Message -ForegroundColor $Color
}

function Write-Header([string]$Title) {
    Write-Host "`n=== $Title ===`n" -ForegroundColor Cyan
}

function Test-PowerShell7 {
    $Pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $Pwsh) { return $false }
    
    $Version = $Pwsh.Version
    if ($Version.Major -lt 7) { return $false }
    
    Write-Status "PowerShell $($Version) found at $($Pwsh.Source)" 'Green'
    return $true
}

function Test-WindowsTerminal {
    $WT = Get-Command wt -ErrorAction SilentlyContinue
    if ($WT) {
        Write-Status "Windows Terminal found" 'Green'
        return $true
    }
    Write-Status "Windows Terminal not found (optional)" 'Yellow'
    return $false
}

function Test-Sudo {
    $Sudo = Get-Command sudo -ErrorAction SilentlyContinue
    if ($Sudo) {
        Write-Status "sudo found at $($Sudo.Source)" 'Green'
        return $true
    }
    Write-Status "sudo not found (optional)" 'Yellow'
    return $false
}

function Install-ViaWinget([string]$PackageId, [string]$Name) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Status "winget not available" 'Red'
        return $false
    }
    Write-Status "Installing $Name..." 'Cyan'
    $Result = & winget install $PackageId --accept-source-agreements --accept-package-agreements 2>&1
    return $LASTEXITCODE -eq 0
}

function Get-InstallDir {
    if ($InstallDir) { return $InstallDir }
    
    # Check existing installations
    foreach ($Dir in $DefaultInstallDirs) {
        if (Test-Path (Join-Path $Dir 'pp2.ps1')) {
            Write-Status "Found existing installation at $Dir" 'Yellow'
            return $Dir
        }
    }
    
    # Find available location
    foreach ($Dir in $DefaultInstallDirs) {
        $Parent = Split-Path $Dir -Parent
        if ($Parent -and (Test-Path $Parent)) {
            return $Dir
        }
        if (Test-Path $Dir) {
            return $Dir
        }
    }
    
    return $DefaultInstallDirs[2]  # $HOME\pp2 as fallback
}

function Download-Pp2([string]$TargetDir) {
    Write-Status "Downloading pp2 from $RepoUrl..." 'Cyan'
    
    # Check git
    $Git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $Git) {
        Write-Status "git not found, downloading zip..." 'Yellow'
        
        $ZipUrl = "$RepoUrl/archive/refs/heads/main.zip"
        $ZipPath = Join-Path $env:TEMP 'pp2.zip'
        
        Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath
        Expand-Archive -Path $ZipPath -DestinationPath $TargetDir -Force
        Remove-Item $ZipPath
        
        # Move from pp2-main to target
        $Extracted = Join-Path $TargetDir 'pp2-main'
        if (Test-Path $Extracted) {
            Get-ChildItem $Extracted | Move-Item -Destination $TargetDir -Force
            Remove-Item $Extracted -Force -Recurse
        }
    }
    else {
        Write-Status "Cloning via git..." 'Cyan'
        & git clone $RepoUrl $TargetDir --depth 1
    }
    
    Write-Status "Downloaded to $TargetDir" 'Green'
}

function Setup-Alias([string]$Pp2Path) {
    $ProfilePath = $PROFILE
    $AliasLine = "Set-Alias pp2 '$Pp2Path'"
    
    if (-not (Test-Path $ProfilePath)) {
        Write-Status "Creating PowerShell profile..." 'Cyan'
        New-Item -Path $ProfilePath -ItemType File -Force | Out-Null
    }
    
    $ProfileContent = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
    
    # Remove old pp2 alias if exists
    if ($ProfileContent -match 'Set-Alias pp2') {
        Write-Status "Removing old pp2 alias..." 'Cyan'
        $ProfileContent = $ProfileContent -replace "Set-Alias pp2 '[^']*'\s*", ''
        Set-Content -Path $ProfilePath -Value $ProfileContent.TrimEnd() -NoNewline
    }
    
    Add-Content -Path $ProfilePath -Value "`n$AliasLine"
    Write-Status "Added pp2 alias to profile" 'Green'
    
    # Add uninstall function
    $UninstallFunc = @'
function pp2-uninstall {
    $Pp2Alias = Get-Command pp2 -ErrorAction SilentlyContinue
    if (-not $Pp2Alias) { Write-Host "pp2 not found" -ForegroundColor Red; return }
    
    $Pp2Path = $Pp2Alias.Definition
    $InstallDir = Split-Path $Pp2Path -Parent
    
    Write-Host "Uninstalling pp2 from $InstallDir..." -ForegroundColor Cyan
    
    # Remove alias from profile
    $ProfileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    $ProfileContent = $ProfileContent -replace "Set-Alias pp2 '[^']*'\s*", ''
    $ProfileContent = $ProfileContent -replace "function pp2-uninstall \{[^}]*\}\s*", ''
    Set-Content -Path $PROFILE -Value $ProfileContent.TrimEnd() -NoNewline
    
    # Remove installation directory
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host "pp2 uninstalled. Restart your terminal." -ForegroundColor Green
}
'@
    
    if (-not ($ProfileContent -match 'function pp2-uninstall')) {
        Add-Content -Path $ProfilePath -Value $UninstallFunc
        Write-Status "Added pp2-uninstall function to profile" 'Green'
    }
}

function Uninstall-Pp2 {
    $Pp2Alias = Get-Command pp2 -ErrorAction SilentlyContinue
    if (-not $Pp2Alias) {
        Write-Status "pp2 not found in PATH" 'Red'
        return
    }
    
    $Pp2Path = $Pp2Alias.Definition
    $InstallDir = Split-Path $Pp2Path -Parent
    
    Write-Header "Uninstalling pp2"
    Write-Status "Installation directory: $InstallDir" 'White'
    
    if (-not $Force) {
        $Confirm = Read-Host "Remove pp2 installation? [y/N]"
        if ($Confirm -ne 'y' -and $Confirm -ne 'Y') {
            Write-Status "Cancelled" 'Yellow'
            return
        }
    }
    
    # Remove alias from profile
    $ProfilePath = $PROFILE
    if (Test-Path $ProfilePath) {
        $Content = Get-Content $ProfilePath -Raw
        $Content = $Content -replace "Set-Alias pp2 '[^']*'\s*", ''
        $Content = $Content -replace "function pp2-uninstall \{[^}]*\}\s*", ''
        Set-Content -Path $ProfilePath -Value $Content.TrimEnd() -NoNewline
        Write-Status "Removed pp2 from profile" 'Green'
    }
    
    # Remove installation directory
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Write-Status "Removed $InstallDir" 'Green'
    }
    
    Write-Status "`npp2 uninstalled. Restart your terminal." 'Green'
}

function Install-Pp2 {
    Write-Header "pp2 Installer"
    
    # Check PowerShell 7+
    Write-Status "Checking prerequisites..." 'White'
    
    if (-not (Test-PowerShell7)) {
        Write-Status "PowerShell 7+ is REQUIRED" 'Red'
        
        if ($InstallPrerequisites) {
            if (Install-ViaWinget 'Microsoft.PowerShell' 'PowerShell 7') {
                Write-Status "PowerShell 7 installed. Please restart this script in pwsh." 'Green'
                Write-Status "Run: pwsh -c 'irm $RepoUrl/raw/main/install.ps1 | iex'" 'Cyan'
                exit 0
            }
        }
        
        Write-Status "Install PowerShell 7: winget install Microsoft.PowerShell" 'Yellow'
        Write-Status "Then run this script again in pwsh" 'Yellow'
        exit 1
    }
    
    # Check optional prerequisites
    $HasWT = Test-WindowsTerminal
    $HasSudo = Test-Sudo
    
    if (-not $HasWT -and $InstallPrerequisites) {
        Install-ViaWinget 'Microsoft.WindowsTerminal' 'Windows Terminal'
    }
    
    if (-not $HasSudo -and $InstallPrerequisites) {
        Install-ViaWinget 'gerardog.gsudo' 'sudo for Windows'
    }
    
    # Determine install directory
    $TargetDir = Get-InstallDir
    Write-Status "`nInstallation directory: $TargetDir" 'White'
    
    # Check if already installed
    $Pp2Path = Join-Path $TargetDir 'pp2.ps1'
    if (Test-Path $Pp2Path) {
        Write-Status "pp2 already installed at $TargetDir" 'Yellow'
        
        if (-not $Force) {
            $Action = Read-Host "Update/reinstall? [U/r/q] (U=update, r=reinstall, q=quit)"
            if ($Action -eq 'q' -or $Action -eq '') {
                Write-Status "Cancelled" 'Yellow'
                exit 0
            }
            
            if ($Action -eq 'r') {
                Remove-Item $TargetDir -Recurse -Force
                Download-Pp2 $TargetDir
            }
            elseif ($Action -eq 'U') {
                Write-Status "Updating..." 'Cyan'
                & git -C $TargetDir pull 2>&1
            }
        }
        else {
            & git -C $TargetDir pull 2>&1
        }
    }
    else {
        if (-not $Force) {
            $Confirm = Read-Host "Download pp2 to $TargetDir? [Y/n]"
            if ($Confirm -eq 'n' -or $Confirm -eq 'N') {
                Write-Status "Cancelled" 'Yellow'
                exit 0
            }
        }
        Download-Pp2 $TargetDir
    }
    
    # Setup alias
    Write-Header "Configuration"
    Setup-Alias (Join-Path $TargetDir 'pp2.ps1')
    
    # Done
    Write-Header "Installation Complete"
    Write-Status "Restart your PowerShell terminal to use pp2" 'Cyan'
    Write-Status "Commands:" 'White'
    Write-Status "  pp2 help       - Show help" 'White'
    Write-Status "  pp2 status     - Show service status" 'White'
    Write-Status "  pp2-uninstall  - Remove pp2" 'White'
}

# Main entry
if ($Uninstall) {
    Uninstall-Pp2
}
else {
    Install-Pp2
}