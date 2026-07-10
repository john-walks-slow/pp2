function Stop-Pp2Service {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    pp2 stop $Name
}
