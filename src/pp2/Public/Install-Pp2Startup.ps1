function Install-Pp2Startup {
    param(
        [string[]]$Name = @('all')
    )
    pp2 startup-install -Name $Name
}