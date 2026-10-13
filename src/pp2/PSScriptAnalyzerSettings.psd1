@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions',
        # The watchdog's helpers (Invoke-ServiceRestart, Clear-RestartChildren,
        # Remove-ExitedChildren) are internal and read better with their current
        # names. Event-handler and callback signatures must also match the
        # framework's parameter list, so an unused parameter is unavoidable.
        'PSUseSingularNouns',
        'PSReviewUnusedParameter'
    )
}
