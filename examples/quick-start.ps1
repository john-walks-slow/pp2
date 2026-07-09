<#
.SYNOPSIS
    Quick start example for pp2

.DESCRIPTION
    Demonstrates how to use pp2 to manage a simple HTTP server service.

.NOTES
    Run from the repository root: pwsh examples/quick-start.ps1
#>

# Import the module
Import-Module ./src/pp2/pp2.psd1 -Force

# Show status
pp2 status

# Start all services
pp2 start all

# View logs for a specific service
pp2 logs my-service -Tail 50

# Watch logs in real-time is the default (Ctrl+C to exit)
# pp2 logs my-service

# Stop a service
pp2 stop my-service

# Restart a service
pp2 restart my-service
