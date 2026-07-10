function Get-Pp2Status {
    param(
        [string]$Name = 'all',
        [ValidateSet('table', 'json')]
        [string]$Format = 'table'
    )
    pp2 status $Name -Format $Format
}
