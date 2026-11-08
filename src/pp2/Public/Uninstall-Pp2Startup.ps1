function Uninstall-Pp2Startup {
    param(
        [string[]]$Name = @('all')
    )
    pp2 startup-uninstall -Name $Name
}