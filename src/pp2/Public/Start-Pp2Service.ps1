function Start-Pp2Service {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [switch]$Force
    )
    pp2 start $Name -Force:$Force
}
