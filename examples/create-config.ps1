<#
.SYNOPSIS
    Create a sample pp2 configuration

.DESCRIPTION
    Generates a services.json file with example service definitions.
    Save the output to $HOME/.pp2/services.json and customize.

.EXAMPLE
    pwsh examples/create-config.ps1 > $HOME/.pp2/services.json
#>

@'
{
  "settings": {
    "watchdogInterval": 60,
    "portCheckTimeout": 200,
    "startupVerifyWait": 2500,
    "shutdownTimeout": 5000
  },
  "services": {
    "http-server": {
      "displayName": "Simple HTTP Server",
      "description": "A basic HTTP file server",
      "workingDirectory": "C:/projects/my-site",
      "command": "npx",
      "arguments": ["-y", "http-server"],
      "shell": true,
      "ports": [8080],
      "autoRestart": true,
      "maxRetries": 3
    },
    "api": {
      "displayName": "API Backend",
      "description": "Backend API service",
      "command": "node",
      "arguments": ["server.js"],
      "shell": false,
      "ports": [3000],
      "autoRestart": true,
      "dependsOn": ["database"]
    },
    "database": {
      "displayName": "Local Database",
      "description": "Development database",
      "command": "pg_ctl",
      "arguments": ["start"],
      "shell": false,
      "ports": [5432],
      "autoRestart": false
    }
  }
}
'@
