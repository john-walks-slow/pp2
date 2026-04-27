# <#
# .SYNOPSIS
#     pp2 - PowerShell Process Manager CLI Entry Point
#
# .DESCRIPTION
#     Thin wrapper that imports the pp2 module and executes the pp2 command.
#     Use `pp2 help` to see all available commands.
# #>
 
$ErrorActionPreference = 'Stop'
 
Try {
    # Import the module from the same directory
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'module\pp2\pp2.psd1') -Force
    
    # Call the pp2 function with all arguments
    pp2 @args
}
Catch {
    $ErrorMessage = $_.Exception.Message
    
    if ($ErrorMessage -like "*services.json*") {
        Write-Host "Error: services.json not found" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please create services.json in pp2 home." -ForegroundColor Yellow
        Write-Host "Default pp2 home: $HOME\.pp2" -ForegroundColor Yellow
    }
    else {
        Write-Error "Failed to initialize pp2: $_"
    }
    exit 1
}
