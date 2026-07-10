function Get-Pp2Logs {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [int]$Tail = 80
    )
    pp2 logs $Name -Tail $Tail
}
