@{
    # PowerShell's static analysis floor, held by tests/test-powershell-analysis.ps1
    # on the Windows validation job. Editors that support PSScriptAnalyzer read
    # this file from the repository root, so a rule silenced here is silenced in
    # the editor and in CI at once.
    #
    # Warning and Error, plus ParseError. Information-severity rules are style
    # opinions and would make the gate a formatter, but ParseError is its own
    # severity rather than an Error: leaving it out reports a file PowerShell
    # cannot even parse as clean, which is the one thing this gate exists to
    # make impossible. tests/test-powershell-analysis.ps1 proves it fires.
    Severity = @('Warning', 'Error', 'ParseError')

    # Each exclusion states why the rule does not apply to this repository, in
    # the same spirit as the ShellCheck disables already in the tree. The gate
    # proves these are what silences the findings rather than assuming it, and
    # proves that every other rule still fires.
    ExcludeRules = @(
        # These scripts talk to a person at a console. The installer's step log
        # and the verifier's [PASS]/[FAIL] lines are the output, not a value a
        # caller pipes onward, and both use colour to separate them.
        'PSAvoidUsingWriteHost'

        # Fires on parameters that are read from a scope it does not follow:
        # install.ps1's $ElevatedLogPath (read at the re-invocation entry point,
        # not inside the function that declares it) and the suites' recorder
        # stubs, which accept a cmdlet's full parameter set precisely so the
        # shipped call site binds unchanged and then ignore most of it.
        'PSReviewUnusedParameter'

        # These are script-internal helpers, not published cmdlets. The dry-run
        # contract this repository actually enforces is the -DryRun switch that
        # config/install-options.tsv registers and every installer honours, and
        # tests/test-windows-bootstrap.ps1 executes it; -WhatIf on an internal
        # function would be a second, unheld promise.
        'PSUseShouldProcessForStateChangingFunctions'

        # Get-WebFedoraDistributions returns the distribution list rather than
        # one distribution, and Assert-FailureContains is not a plural at all.
        # Neither is exported to a user's session.
        'PSUseSingularNouns'
    )
}
