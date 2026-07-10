function Restart-Pp2Service {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    pp2 restart $Name
}
