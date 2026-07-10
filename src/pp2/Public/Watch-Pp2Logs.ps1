function Watch-Pp2Logs {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    pp2 logs $Name -Watch
}
