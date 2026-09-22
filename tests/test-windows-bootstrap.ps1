[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installer = Join-Path $repoRoot 'platforms\windows\install.ps1'
$wslVersionHelper = Join-Path $repoRoot 'platforms\windows\lib\wsl-version.ps1'
$themeHelper = Join-Path $repoRoot 'platforms\windows\set-noctty-theme.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'dotfiles-windows-test-{0}' -f [guid]::NewGuid().ToString('N')
)
$originalLocalAppData = $env:LOCALAPPDATA
$originalUserProfile = $env:USERPROFILE

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Actual,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-WslVersionCase {
    param(
        [string]$Output,
        [AllowNull()]
        [object]$ExpectedVersion,
        [string]$ExpectedStatus
    )

    $version = ConvertFrom-WslVersionOutput -Lines @($Output)
    $actualVersion = if ($null -eq $version) { $null } else { $version.ToString() }
    Assert-Equal -Actual $actualVersion -Expected $ExpectedVersion `
        -Message "Unexpected parsed version for '$Output'."
    Assert-Equal `
        -Actual (Get-WslSupportStatus `
            -InstalledVersion $version `
            -MinimumProvenVersion ([version]'2.7.13')) `
        -Expected $ExpectedStatus `
        -Message "Unexpected support status for '$Output'."
}

try {
    foreach ($powershellFile in @($installer, $wslVersionHelper, $themeHelper)) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $powershellFile,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null

        if ($errors.Count -gt 0) {
            throw "PowerShell parse failure in ${powershellFile}: $($errors -join '; ')"
        }
    }

    . $wslVersionHelper
    Assert-WslVersionCase -Output 'WSL version: 2.7.13' `
        -ExpectedVersion '2.7.13' -ExpectedStatus Proven
    Assert-WslVersionCase -Output 'WSL version: 2.7.14.0' `
        -ExpectedVersion '2.7.14.0' -ExpectedStatus Proven
    Assert-WslVersionCase -Output 'WSL version: 2.8.0.0' `
        -ExpectedVersion '2.8.0.0' -ExpectedStatus Proven
    Assert-WslVersionCase -Output 'WSL version: 3.0.0.0' `
        -ExpectedVersion '3.0.0.0' -ExpectedStatus Proven
    Assert-WslVersionCase -Output 'WSL version: 2.7.12.0' `
        -ExpectedVersion '2.7.12.0' -ExpectedStatus Older
    Assert-WslVersionCase -Output 'unrecognized output' `
        -ExpectedVersion $null -ExpectedStatus Unknown
    Assert-WslVersionCase `
        -Output "WSL-Version: 2.7.13.0`0" `
        -ExpectedVersion '2.7.13.0' -ExpectedStatus Proven

    $componentOnlyOutput = @(
        'unrecognized WSL package line',
        'Kernel version: 6.6.87.2'
    )
    $componentOnlyVersion = ConvertFrom-WslVersionOutput -Lines $componentOnlyOutput
    Assert-Equal -Actual $componentOnlyVersion -Expected $null `
        -Message 'A later component version was mistaken for the WSL package version.'

    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalAppData'
    $env:USERPROFILE = Join-Path $testRoot 'UserProfile'
    [IO.Directory]::CreateDirectory($env:LOCALAPPDATA) | Out-Null
    [IO.Directory]::CreateDirectory($env:USERPROFILE) | Out-Null

    & $themeHelper -Flavor latte | Out-Null
    $themeConfig = Join-Path $env:LOCALAPPDATA 'noctty\dotfiles\theme.conf'
    Assert-Equal -Actual ([IO.File]::ReadAllText($themeConfig)) `
        -Expected "theme = catppuccin-latte.conf`r`n" `
        -Message 'Fresh Noctty theme configuration was incorrect.'

    & $themeHelper -Flavor mocha | Out-Null
    Assert-Equal -Actual ([IO.File]::ReadAllText($themeConfig)) `
        -Expected "theme = catppuccin-mocha.conf`r`n" `
        -Message 'Existing Noctty theme configuration was not replaced.'

    $temporaryFiles = @(Get-ChildItem `
        -LiteralPath (Split-Path -Parent $themeConfig) `
        -Filter 'theme-*.tmp')
    Assert-Equal -Actual $temporaryFiles.Count -Expected 0 `
        -Message 'Noctty theme update left temporary files.'

    $bytes = [IO.File]::ReadAllBytes($themeConfig)
    $hasUtf8Bom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Assert-Equal -Actual $hasUtf8Bom -Expected $false `
        -Message 'Noctty theme configuration contains a UTF-8 BOM.'

    if (Select-String -LiteralPath $themeHelper -SimpleMatch '+perform-action' -Quiet) {
        throw 'Noctty theme helper must not invoke interactive CLI automation.'
    }

    # Declining the UAC prompt is a decision, not the transient ShellExecute
    # launch quirk the retry loop exists for. Invoke-ElevatedPhase is lifted
    # out of install.ps1 by its own parse tree, so these cases exercise the
    # shipped code without running the installer's main body or elevating
    # anything.
    $installerTokens = $null
    $installerErrors = $null
    $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $installer,
        [ref]$installerTokens,
        [ref]$installerErrors
    )
    $installerFunctions = @{}
    foreach ($definition in $installerAst.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        },
        $true
    )) {
        $installerFunctions[$definition.Name] = $definition.Extent.Text
    }

    # One lift for the whole suite: the shipped text of the named functions,
    # joined so functions that call each other can be dot-sourced together. A
    # function that is renamed or removed is named here rather than quietly
    # leaving its cases untested.
    function Get-InstallerFunctionText {
        param([Parameter(Mandatory = $true)][string[]]$Name)

        $missing = @($Name | Where-Object { -not $installerFunctions.ContainsKey($_) })
        if ($missing.Count -gt 0) {
            throw "install.ps1 no longer defines: $($missing -join ', ')"
        }

        return (($Name | ForEach-Object { $installerFunctions[$_] }) -join "`n")
    }

    # Each case below is run twice: against the shipped function text, where it
    # must pass, and against text with a plausible defect written into it,
    # where it must fail. A case that passes both ways asserts nothing, which
    # is the failure mode a test suite cannot report about itself.
    function Assert-CaseCatchesMutation {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)][string]$FunctionText,
            [Parameter(Mandatory = $true)][scriptblock]$Case,
            [Parameter(Mandatory = $true)][string]$From,
            [Parameter(Mandatory = $true)][string]$To
        )

        & $Case $FunctionText

        if (-not $FunctionText.Contains($From)) {
            throw "$Name cannot be mutated: install.ps1 no longer contains '$From'."
        }

        $caught = $false
        try {
            & $Case $FunctionText.Replace($From, $To)
        }
        catch {
            $caught = $true
        }
        if (-not $caught) {
            throw "$Name passed against a mutated function body, so it proves nothing."
        }

        Write-Host "PASS: $Name, and the case fails when the function is mutated"
    }

    $elevatedPhaseText = Get-InstallerFunctionText -Name 'Invoke-ElevatedPhase'

    # Runs the real function with Start-Process, Start-Sleep and Write-Warning
    # replaced, and reports what it did. $Behaviour receives the attempt number
    # and either throws or returns a stand-in process.
    $runElevatedPhase = {
        param(
            [string]$FunctionText,
            [scriptblock]$Behaviour,
            [string]$ManualEquivalent = 'wsl --update --web-download'
        )

        $script:elevationAttempts = 0
        $script:elevationSleeps = 0
        $script:elevationWarnings = @()
        $script:elevationBehaviour = $Behaviour

        function Start-Process {
            param(
                [string]$FilePath,
                [string[]]$ArgumentList,
                [string]$Verb,
                [switch]$Wait,
                [switch]$PassThru
            )

            $script:elevationAttempts++
            & $script:elevationBehaviour $script:elevationAttempts
        }

        function Start-Sleep {
            param([int]$Seconds)
            $script:elevationSleeps++
        }

        function Write-Warning {
            param([string]$Message)
            $script:elevationWarnings += $Message
        }

        . ([scriptblock]::Create($FunctionText))

        $failure = $null
        try {
            Invoke-ElevatedPhase `
                -PhaseSwitch '-ElevatedWslUpdateOnly' `
                -FailureDescription 'The elevated WSL update' `
                -ManualEquivalent $ManualEquivalent | Out-Null
        }
        catch {
            $failure = $_
        }

        [pscustomobject]@{
            Failure = $failure
            Attempts = $script:elevationAttempts
            Sleeps = $script:elevationSleeps
            Warnings = $script:elevationWarnings
        }
    }

    # Start-Process -Verb RunAs never hands the caller the ERROR_CANCELLED
    # Win32Exception it raised internally: it catches that and re-throws an
    # InvalidOperationException quoting the message. Cover both that wrapped
    # shape and the one where the original exception survives as the inner one.
    $declinedShapes = @(
        {
            param($attempt)
            throw [InvalidOperationException]::new(
                'This command cannot be run due to the error: ' +
                [System.ComponentModel.Win32Exception]::new(1223).Message)
        },
        {
            param($attempt)
            throw [InvalidOperationException]::new(
                'This command cannot be run.',
                [System.ComponentModel.Win32Exception]::new(1223))
        }
    )

    foreach ($shape in $declinedShapes) {
        $declined = & $runElevatedPhase $elevatedPhaseText $shape

        if (-not $declined.Failure) {
            throw 'A declined UAC prompt did not stop the elevated phase.'
        }
        Assert-Equal -Actual $declined.Attempts -Expected 1 `
            -Message 'A declined UAC prompt was prompted for again.'
        Assert-Equal -Actual $declined.Sleeps -Expected 0 `
            -Message 'A declined UAC prompt slept before retrying.'
        Assert-Equal -Actual $declined.Warnings.Count -Expected 0 `
            -Message 'A declined UAC prompt was reported as a failed attempt.'
        if ($declined.Failure.Exception.Message -notmatch 'approval was declined') {
            throw ("A declined UAC prompt must say approval was declined, got: " +
                $declined.Failure.Exception.Message)
        }
        if (-not $declined.Failure.Exception.Message.Contains('wsl --update --web-download')) {
            throw ("The declined message must name this phase's own manual command, got: " +
                $declined.Failure.Exception.Message)
        }
    }

    # The other call site has a different manual equivalent, and a hint naming
    # the wrong one is the defect this covers: installing a distribution is not
    # a substitute for updating WSL.
    $declinedInstall = & $runElevatedPhase $elevatedPhaseText $declinedShapes[0] `
        'wsl --install FedoraLinux-42'
    if (-not $declinedInstall.Failure) {
        throw 'A declined UAC prompt did not stop the elevated installation phase.'
    }
    if (-not $declinedInstall.Failure.Exception.Message.Contains('wsl --install FedoraLinux-42')) {
        throw ("The declined message must name the installation phase's own command, got: " +
            $declinedInstall.Failure.Exception.Message)
    }
    if ($declinedInstall.Failure.Exception.Message.Contains('wsl --update')) {
        throw 'The installation phase reported the update phase''s manual command.'
    }

    # The transient quirk the retry exists for still gets its three attempts.
    $transient = & $runElevatedPhase $elevatedPhaseText {
        param($attempt)
        if ($attempt -lt 3) {
            throw [InvalidOperationException]::new(
                'the system cannot find all the information required')
        }
        [pscustomobject]@{ ExitCode = 0 }
    }

    if ($transient.Failure) {
        throw ("A transient launch failure was not retried to success: " +
            $transient.Failure.Exception.Message)
    }
    Assert-Equal -Actual $transient.Attempts -Expected 3 `
        -Message 'A transient launch failure did not use every attempt.'
    Assert-Equal -Actual $transient.Sleeps -Expected 2 `
        -Message 'A transient launch failure did not back off between attempts.'
    Assert-Equal -Actual $transient.Warnings.Count -Expected 2 `
        -Message 'A transient launch failure did not warn about each retry.'

    # Voice dictation on Windows is Handy, and it is a Scoop package like
    # everything else the bootstrap installs. The manifest is the single
    # source of truth for its bucket and package names, so assert the
    # manifest rather than a string inside the script.
    $manifestPath = Join-Path $repoRoot 'platforms\windows\manifest.psd1'
    $windowsManifest = Import-PowerShellDataFile $manifestPath
    Assert-Equal -Actual $windowsManifest.Scoop.ExtrasBucket.Name -Expected 'extras' `
        -Message 'Handy must come from Scoop''s official extras bucket.'
    Assert-Equal -Actual $windowsManifest.Scoop.ExtrasBucket.Url `
        -Expected 'https://github.com/ScoopInstaller/Extras' `
        -Message 'The extras bucket must be the official ScoopInstaller one.'
    Assert-Equal -Actual $windowsManifest.Scoop.HandyPackage.QualifiedName `
        -Expected 'extras/handy' `
        -Message 'Handy must be installed as a bucket-qualified Scoop package.'
    Assert-Equal -Actual $windowsManifest.Scoop.HandyPackage.Executable `
        -Expected 'handy.exe' -Message 'Unexpected Handy executable name.'

    # Handy being a Scoop package is what keeps the whole Windows bootstrap on
    # one package manager; nothing here may reach for another.
    if ((Get-Content -LiteralPath $installer -Raw) -match '(?i)winget') {
        throw 'The Windows bootstrap must install every application through Scoop.'
    }

    $handyFunctionText = Get-InstallerFunctionText -Name @(
        'Test-ScoopPackageInstalled',
        'Add-ScoopBucket',
        'Install-ScoopPackage',
        'Install-Handy'
    )

    # Runs the shipped Install-Handy with Scoop, the native command runner and
    # the step log replaced, so bucket selection, idempotency and dry-run
    # honesty are exercised without Scoop, a network or an elevated session.
    $runInstallHandy = {
        param(
            [string]$FunctionText,
            [string]$ManifestPath,
            [string[]]$Buckets,
            [bool]$DryRunValue,
            [string]$ProfileRoot,
            [string[]]$ResolvableCommands = @()
        )

        $script:handySteps = @()
        $script:handyCommands = @()
        $script:handyBuckets = $Buckets
        $script:handyResolvable = $ResolvableCommands
        $DryRun = $DryRunValue
        $WindowsManifest = Import-PowerShellDataFile $ManifestPath
        $env:USERPROFILE = $ProfileRoot

        function Write-Step {
            param([string]$Message)
            $script:handySteps += $Message
        }

        function Invoke-NativeCommand {
            param([string]$FilePath, [string[]]$Arguments = @())
            $script:handyCommands += ($Arguments -join ' ')
        }

        function Get-Command {
            param([string]$Name, $ErrorAction)
            if ($script:handyResolvable -contains $Name) {
                return [pscustomobject]@{ Source = "C:\fixture\scoop\shims\$Name.exe" }
            }
            return $null
        }

        function Resolve-ScoopCommand { return 'C:\fixture\scoop\shims\scoop.ps1' }

        function Install-Scoop {
            throw 'Install-Handy bootstrapped Scoop when Scoop was already available.'
        }

        function Get-ScoopBucketList {
            param([string]$Scoop)
            return $script:handyBuckets
        }

        . ([scriptblock]::Create($FunctionText))

        Install-Handy

        [pscustomobject]@{
            Steps = $script:handySteps
            Commands = $script:handyCommands
        }
    }

    $withoutExtras = @(
        'Name Source Updated Manifests',
        'main https://github.com/ScoopInstaller/Main 2026-01-01 1000'
    )
    $withExtras = $withoutExtras + @(
        'extras https://github.com/ScoopInstaller/Extras 2026-01-01 2000'
    )
    $emptyProfile = Join-Path $testRoot 'HandyAbsent'
    [IO.Directory]::CreateDirectory($emptyProfile) | Out-Null

    $dryRun = & $runInstallHandy $handyFunctionText $manifestPath $withoutExtras $true $emptyProfile
    Assert-Equal -Actual $dryRun.Commands.Count -Expected 0 `
        -Message 'A dry run must not run any Scoop command.'
    if ($dryRun.Steps -notcontains
        'Would add the extras Scoop bucket: https://github.com/ScoopInstaller/Extras') {
        throw "A dry run did not describe adding the extras bucket: $($dryRun.Steps -join '; ')"
    }
    if ($dryRun.Steps -notcontains
        'Would install extras/handy for the current Windows user') {
        throw "A dry run did not describe installing Handy: $($dryRun.Steps -join '; ')"
    }

    $dryRunBucketPresent = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $true $emptyProfile
    if ($dryRunBucketPresent.Steps -match 'Would add the extras Scoop bucket') {
        throw 'An already-added extras bucket was described as needing to be added.'
    }

    $install = & $runInstallHandy $handyFunctionText $manifestPath `
        $withoutExtras $false $emptyProfile
    if ($install.Commands -notcontains
        'bucket add extras https://github.com/ScoopInstaller/Extras') {
        throw "Handy was installed without adding the extras bucket: $($install.Commands -join '; ')"
    }
    if ($install.Commands -notcontains 'install extras/handy') {
        throw "Handy was not installed from the extras bucket: $($install.Commands -join '; ')"
    }

    $rerun = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $false $emptyProfile
    Assert-Equal -Actual $rerun.Commands.Count -Expected 1 `
        -Message 'A rerun re-added the extras bucket.'

    # Idempotency: an installed Handy is left alone, whether it is found
    # through its Scoop shim or under Scoop's apps directory.
    $installedProfile = Join-Path $testRoot 'HandyPresent'
    $installedDirectory = Join-Path $installedProfile 'scoop\apps\handy\current'
    [IO.Directory]::CreateDirectory($installedDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $installedDirectory 'handy.exe'), '')

    $alreadyInstalled = & $runInstallHandy $handyFunctionText $manifestPath `
        $withoutExtras $false $installedProfile
    Assert-Equal -Actual $alreadyInstalled.Commands.Count -Expected 0 `
        -Message 'An installed Handy was installed again.'
    if ($alreadyInstalled.Steps -notcontains 'Handy is already installed') {
        throw "An installed Handy was not reported as present: $($alreadyInstalled.Steps -join '; ')"
    }

    $onPath = & $runInstallHandy $handyFunctionText $manifestPath `
        $withoutExtras $false $emptyProfile @('handy')
    Assert-Equal -Actual $onPath.Commands.Count -Expected 0 `
        -Message 'A resolvable handy command was installed again.'

    # -----------------------------------------------------------------------
    # The rest of install.ps1's decision and mutation logic. Everything below
    # runs the shipped function bodies through Get-InstallerFunctionText and
    # is held to Assert-CaseCatchesMutation, so no case can quietly stop
    # testing the thing it names.
    # -----------------------------------------------------------------------

    # Resolve-FedoraDistribution decides which distribution the whole run is
    # about, and it is the one function whose $null return reaches an
    # administrator prompt.
    $resolveDistributionText = Get-InstallerFunctionText -Name 'Resolve-FedoraDistribution'
    $runResolveDistribution = {
        param(
            [string]$FunctionText,
            [string[]]$Installed = @(),
            [string[]]$Online = @(),
            [string[]]$Web = @(),
            [string]$Requested = '',
            [bool]$AllowUnavailable = $false
        )

        $script:resolveInstalled = $Installed
        $script:resolveOnline = $Online
        $script:resolveWeb = $Web
        $script:resolveWebCalls = 0

        function Get-WslList {
            param([switch]$Online)
            if ($Online) { return $script:resolveOnline }
            return $script:resolveInstalled
        }

        function Get-WebFedoraDistributions {
            $script:resolveWebCalls++
            return $script:resolveWeb
        }

        . ([scriptblock]::Create($FunctionText))

        $arguments = @{}
        if ($Requested) { $arguments['RequestedDistribution'] = $Requested }
        if ($AllowUnavailable) { $arguments['AllowUnavailable'] = $true }

        $result = $null
        $failure = $null
        try {
            $result = Resolve-FedoraDistribution @arguments
        }
        catch {
            $failure = $_
        }

        [pscustomobject]@{
            Result = $result
            Failure = $failure
            WebCalls = $script:resolveWebCalls
        }
    }

    # Auto-selection takes the newest release, by the trailing number rather
    # than by string order, and an unnumbered FedoraLinux never outranks one.
    Assert-CaseCatchesMutation -Name 'Auto-selection takes the newest FedoraLinux' `
        -FunctionText $resolveDistributionText `
        -From 'Descending = $true' -To 'Descending = $false' `
        -Case {
            param([string]$FunctionText)

            $newest = & $runResolveDistribution $FunctionText @() `
                @('FedoraLinux-9', 'FedoraLinux', 'FedoraLinux-44', 'FedoraLinux-42') @() '' $false
            if ($newest.Failure) { throw "Auto-selection failed: $($newest.Failure.Exception.Message)" }
            Assert-Equal -Actual $newest.Result -Expected 'FedoraLinux-44' `
                -Message 'Auto-selection did not take the newest FedoraLinux release.'
        }

    # An empty Store catalogue is a stale one, so the web catalogue answers
    # instead; this is the path -AllowUnavailable exists for.
    Assert-CaseCatchesMutation -Name 'An empty Store catalogue falls back to the web catalogue' `
        -FunctionText $resolveDistributionText `
        -From '$candidates = @(Get-WebFedoraDistributions)' -To '$candidates = @()' `
        -Case {
            param([string]$FunctionText)

            $fromWeb = & $runResolveDistribution $FunctionText @() @() `
                @('FedoraLinux-43', 'FedoraLinux-44') '' $true
            if ($fromWeb.Failure) { throw "The web fallback failed: $($fromWeb.Failure.Exception.Message)" }
            Assert-Equal -Actual $fromWeb.Result -Expected 'FedoraLinux-44' `
                -Message 'The web catalogue fallback did not select a distribution.'
            Assert-Equal -Actual $fromWeb.WebCalls -Expected 1 `
                -Message 'The web catalogue was not consulted exactly once.'
        }

    # With nothing anywhere, auto-selection keeps its two answers: $null under
    # -AllowUnavailable, so the caller can update WSL and ask again, and a
    # throw without it.
    $emptyAuto = & $runResolveDistribution $resolveDistributionText @() @() @() '' $true
    if ($emptyAuto.Failure) {
        throw "Auto-selection threw under -AllowUnavailable: $($emptyAuto.Failure.Exception.Message)"
    }
    Assert-Equal -Actual $emptyAuto.Result -Expected $null `
        -Message 'Auto-selection did not return $null for an empty catalogue.'

    $emptyAutoStrict = & $runResolveDistribution $resolveDistributionText @() @() @() '' $false
    if (-not $emptyAutoStrict.Failure) {
        throw 'Auto-selection returned a distribution from empty catalogues.'
    }
    Write-Host 'PASS: an empty catalogue returns $null only when the caller allows it'

    # An installed name is taken at its word without a network call at all.
    Assert-CaseCatchesMutation -Name 'An installed distribution is accepted without the web catalogue' `
        -FunctionText $resolveDistributionText `
        -From 'if (($installed -notcontains $RequestedDistribution) -and' `
        -To 'if (($installed -contains $RequestedDistribution) -and' `
        -Case {
            param([string]$FunctionText)

            $installed = & $runResolveDistribution $FunctionText @('FedoraLinux-44') @() @() `
                'FedoraLinux-44' $true
            if ($installed.Failure) { throw "An installed name was rejected: $($installed.Failure.Exception.Message)" }
            Assert-Equal -Actual $installed.Result -Expected 'FedoraLinux-44' `
                -Message 'An installed distribution was not accepted.'
            Assert-Equal -Actual $installed.WebCalls -Expected 0 `
                -Message 'An installed distribution still read the web catalogue.'
        }

    # PS-07. A name the user typed is not the stale-catalogue case, so
    # -AllowUnavailable must not soften it into a $null the main body answers
    # with an administrator prompt and a real `wsl --update`. The name is
    # wrong now and it will still be wrong after the update.
    Assert-CaseCatchesMutation -Name 'A mistyped distribution name is refused before any elevation' `
        -FunctionText $resolveDistributionText `
        -From "throw `"Fedora distribution '`$RequestedDistribution' is neither installed" `
        -To "return `$null; throw `"Fedora distribution '`$RequestedDistribution' is neither installed" `
        -Case {
            param([string]$FunctionText)

            foreach ($allowUnavailable in @($true, $false)) {
                $typo = & $runResolveDistribution $FunctionText @('FedoraLinux-44') `
                    @('FedoraLinux-44') @('FedoraLinux-44') 'FedoraLinux-4l' $allowUnavailable
                if (-not $typo.Failure) {
                    throw ('A mistyped distribution name returned ' +
                        "'$($typo.Result)' instead of failing (-AllowUnavailable: $allowUnavailable).")
                }
                if ($typo.Failure.Exception.Message -notmatch 'FedoraLinux-4l') {
                    throw ('The refusal must name the distribution that was asked for, got: ' +
                        $typo.Failure.Exception.Message)
                }
            }
        }

    # Copy-FileIfChanged is the primitive behind every file the Noctty
    # synchronisation writes; rerunning an install must not rewrite a file
    # whose contents already match.
    $copyFileText = Get-InstallerFunctionText -Name 'Copy-FileIfChanged'
    Assert-CaseCatchesMutation -Name 'Copy-FileIfChanged rewrites only what changed' `
        -FunctionText $copyFileText `
        -From '.Hash -eq' -To '.Hash -ne' `
        -Case {
            param([string]$FunctionText)

            $copyRoot = Join-Path $testRoot ('copy-{0}' -f [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($copyRoot) | Out-Null
            $source = Join-Path $copyRoot 'source.conf'
            $destination = Join-Path $copyRoot 'destination.conf'
            [IO.File]::WriteAllText($source, "theme = one`r`n")

            & {
                param([string]$Text, [string]$From, [string]$To)
                . ([scriptblock]::Create($Text))

                Copy-FileIfChanged -Source $From -Destination $To
                if (-not (Test-Path -LiteralPath $To)) {
                    throw 'Copy-FileIfChanged did not create a missing destination.'
                }

                # An identical destination is left alone, which is what a
                # rerun depends on. Timestamps are the only observable
                # difference between "left alone" and "rewritten identically".
                $stamp = [datetime]'2001-02-03T04:05:06Z'
                [IO.File]::SetLastWriteTimeUtc($To, $stamp)
                Copy-FileIfChanged -Source $From -Destination $To
                if ([IO.File]::GetLastWriteTimeUtc($To) -ne $stamp) {
                    throw 'Copy-FileIfChanged rewrote a destination that already matched.'
                }

                [IO.File]::WriteAllText($From, "theme = two`r`n")
                Copy-FileIfChanged -Source $From -Destination $To
                if ([IO.File]::ReadAllText($To) -ne "theme = two`r`n") {
                    throw 'Copy-FileIfChanged did not replace a destination whose contents differed.'
                }
            } $FunctionText $source $destination
        }

    # Sync-NocttyGhosttyConfig deploys the tracked Ghostty configuration into
    # Noctty's own directory. It runs against the real tracked files, so a
    # theme removed from the repository shows up here.
    $syncNocttyText = Get-InstallerFunctionText -Name @(
        'Copy-FileIfChanged',
        'Sync-NocttyGhosttyConfig'
    )
    $runSyncNoctty = {
        param(
            [string]$FunctionText,
            [string]$ConfigDirectory,
            [bool]$DryRunValue,
            [string]$RepositoryRoot,
            [string]$ThemeHelper
        )

        $script:syncSteps = @()
        $DryRun = $DryRunValue
        $GhosttyConfig = Join-Path $RepositoryRoot 'ghostty\.config\ghostty\shared.conf'
        $GhosttyThemes = Join-Path $RepositoryRoot 'ghostty\.config\ghostty\themes'
        $NocttyThemeHelper = $ThemeHelper

        function Write-Step {
            param([string]$Message)
            $script:syncSteps += $Message
        }

        . ([scriptblock]::Create($FunctionText))

        Sync-NocttyGhosttyConfig -ConfigDirectory $ConfigDirectory

        return $script:syncSteps
    }

    $trackedThemeCount = @(Get-ChildItem `
        -LiteralPath (Join-Path $repoRoot 'ghostty\.config\ghostty\themes') `
        -Filter '*.conf' -File).Count

    Assert-CaseCatchesMutation -Name 'A dry-run Noctty synchronisation writes nothing' `
        -FunctionText $syncNocttyText `
        -From 'if ($DryRun) {' -To 'if ($false) {' `
        -Case {
            param([string]$FunctionText)

            $dryRoot = Join-Path $testRoot ('sync-dry-{0}' -f [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($dryRoot) | Out-Null
            $steps = & $runSyncNoctty $FunctionText $dryRoot $true $repoRoot $themeHelper

            $written = @(Get-ChildItem -LiteralPath $dryRoot -Recurse -Force)
            if ($written.Count -ne 0) {
                throw "A dry run wrote $($written.Count) path(s) under the Noctty configuration directory."
            }
            if ($steps -notcontains "Would install the WSL theme bridge at $(Join-Path (Join-Path $dryRoot 'dotfiles') 'set-theme.ps1')") {
                throw "A dry run did not describe installing the theme bridge: $($steps -join '; ')"
            }
        }

    Assert-CaseCatchesMutation -Name 'A real Noctty synchronisation deploys every tracked theme' `
        -FunctionText $syncNocttyText `
        -From 'foreach ($sourceTheme in $sourceThemes) {' -To 'foreach ($sourceTheme in @()) {' `
        -Case {
            param([string]$FunctionText)

            $syncRoot = Join-Path $testRoot ('sync-{0}' -f [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($syncRoot) | Out-Null
            & $runSyncNoctty $FunctionText $syncRoot $false $repoRoot $themeHelper | Out-Null

            foreach ($expected in @('dotfiles\ghostty.conf', 'dotfiles\set-theme.ps1', 'dotfiles\theme.conf')) {
                if (-not (Test-Path -LiteralPath (Join-Path $syncRoot $expected) -PathType Leaf)) {
                    throw "The Noctty synchronisation did not deploy $expected."
                }
            }

            $deployedThemes = @(Get-ChildItem `
                -LiteralPath (Join-Path $syncRoot 'themes') -Filter '*.conf' -File)
            Assert-Equal -Actual $deployedThemes.Count -Expected $trackedThemeCount `
                -Message 'The Noctty synchronisation deployed the wrong number of themes.'

            # The initial theme.conf takes the default the tracked shared
            # configuration declares, rather than inventing one.
            $defaultTheme = Get-Content `
                -LiteralPath (Join-Path $repoRoot 'ghostty\.config\ghostty\shared.conf') |
                Where-Object { $_ -match '^\s*theme\s*=' } |
                Select-Object -First 1
            Assert-Equal `
                -Actual ([IO.File]::ReadAllText((Join-Path $syncRoot 'dotfiles\theme.conf'))) `
                -Expected "$defaultTheme`r`n" `
                -Message 'The deployed Noctty theme configuration did not match the tracked default.'
        }

    # Set-NocttyConfiguration owns one block in a file the user also owns.
    $setNocttyText = Get-InstallerFunctionText -Name 'Set-NocttyConfiguration'
    $runSetNoctty = {
        param(
            [string]$FunctionText,
            [string]$LocalAppData,
            [bool]$DryRunValue,
            [string]$Distribution
        )

        $script:nocttySteps = @()
        $script:nocttyWarnings = @()
        $script:nocttySyncCalls = 0
        $DryRun = $DryRunValue
        $ManagedBlockStart = '# BEGIN dotfiles Fedora WSL'
        $ManagedBlockEnd = '# END dotfiles Fedora WSL'
        $env:LOCALAPPDATA = $LocalAppData

        function Write-Step {
            param([string]$Message)
            $script:nocttySteps += $Message
        }

        function Write-Warning {
            param([string]$Message)
            $script:nocttyWarnings += $Message
        }

        function Sync-NocttyGhosttyConfig {
            param([string]$ConfigDirectory)
            $script:nocttySyncCalls++
        }

        . ([scriptblock]::Create($FunctionText))

        Set-NocttyConfiguration -Distribution $Distribution

        $configPath = Join-Path $LocalAppData 'noctty\config.ghostty'
        [pscustomobject]@{
            Steps = $script:nocttySteps
            Warnings = $script:nocttyWarnings
            SyncCalls = $script:nocttySyncCalls
            Exists = Test-Path -LiteralPath $configPath
            Content = if (Test-Path -LiteralPath $configPath) {
                [IO.File]::ReadAllText($configPath)
            }
            else { $null }
        }
    }

    Assert-CaseCatchesMutation -Name 'A rerun of the Noctty configuration is a byte-for-byte no-op' `
        -FunctionText $setNocttyText `
        -From '$managedRegex.Replace($content, '''', 1)' -To '$content' `
        -Case {
            param([string]$FunctionText)

            $appData = Join-Path $testRoot ('noctty-{0}' -f [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($appData) | Out-Null

            $first = & $runSetNoctty $FunctionText $appData $false 'FedoraLinux-44'
            if (-not $first.Exists) { throw 'Set-NocttyConfiguration wrote no configuration file.' }
            if ($first.Content -notmatch 'command = direct:wsl\.exe --distribution FedoraLinux-44') {
                throw "The managed block did not set the Fedora WSL command: $($first.Content)"
            }

            $second = & $runSetNoctty $FunctionText $appData $false 'FedoraLinux-44'
            Assert-Equal -Actual $second.Content -Expected $first.Content `
                -Message 'Rerunning Set-NocttyConfiguration changed the configuration file.'
        }

    Assert-CaseCatchesMutation -Name 'A user-managed command keeps control of Noctty' `
        -FunctionText $setNocttyText `
        -From "'(?m)^\s*command\s*='" -To "'(?m)^\s*command-that-cannot-appear\s*='" `
        -Case {
            param([string]$FunctionText)

            $appData = Join-Path $testRoot ('noctty-user-{0}' -f [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($appData) | Out-Null
            $configPath = Join-Path $appData 'noctty\config.ghostty'
            [IO.Directory]::CreateDirectory((Split-Path -Parent $configPath)) | Out-Null
            $userContent = "font-size = 13`r`ncommand = direct:wsl.exe --distribution MyOwnDistro`r`n"
            [IO.File]::WriteAllText($configPath, $userContent)

            $result = & $runSetNoctty $FunctionText $appData $false 'FedoraLinux-44'
            if ($result.Content -match 'command = direct:wsl\.exe --distribution FedoraLinux-44') {
                throw "The managed block overrode a user-managed command: $($result.Content)"
            }
            if ($result.Content -notmatch 'Fedora WSL command omitted') {
                throw "The managed block did not say why it omitted the command: $($result.Content)"
            }
            if (-not $result.Content.EndsWith($userContent)) {
                throw "User-owned content was not preserved byte-for-byte: $($result.Content)"
            }
            if ($result.Warnings.Count -ne 1) {
                throw "Leaving a user command in control must warn exactly once, got $($result.Warnings.Count)."
            }
        }

    Assert-CaseCatchesMutation -Name 'A dry-run Noctty configuration writes nothing and still previews the sync' `
        -FunctionText $setNocttyText `
        -From 'if ($DryRun) {' -To 'if ($false) {' `
        -Case {
            param([string]$FunctionText)

            $appData = Join-Path $testRoot ('noctty-dry-{0}' -f [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($appData) | Out-Null

            $result = & $runSetNoctty $FunctionText $appData $true 'FedoraLinux-44'
            if ($result.Exists) { throw 'A dry run wrote the Noctty configuration file.' }
            Assert-Equal -Actual $result.SyncCalls -Expected 1 `
                -Message 'A dry run did not preview the Ghostty synchronisation.'
        }

    # Write-WindowsSelectionState writes the file verify.ps1 later reads. Its
    # selection flags have to be JSON booleans, which is the property the
    # verifier's schema validation depends on.
    $writeStateText = Get-InstallerFunctionText -Name 'Write-WindowsSelectionState'
    $runWriteState = {
        param(
            [string]$FunctionText,
            [string]$StatePath,
            [string]$ManifestPath,
            [string]$Distribution,
            [bool]$SkipNocttyValue,
            [bool]$SkipNocttyConfigurationValue,
            [bool]$HandyValue
        )

        $SelectionStatePath = $StatePath
        $WindowsManifest = Import-PowerShellDataFile $ManifestPath
        $SkipNoctty = [switch]$SkipNocttyValue
        $SkipNocttyConfiguration = [switch]$SkipNocttyConfigurationValue
        $Handy = [switch]$HandyValue

        . ([scriptblock]::Create($FunctionText))

        Write-WindowsSelectionState -Distribution $Distribution

        return [IO.File]::ReadAllText($StatePath)
    }

    Assert-CaseCatchesMutation -Name 'The recorded Windows selection is JSON the verifier can read' `
        -FunctionText $writeStateText `
        -From 'WslRequired = $true' -To "WslRequired = 'true'" `
        -Case {
            param([string]$FunctionText)

            $stateRoot = Join-Path $testRoot ('state-{0}' -f [guid]::NewGuid().ToString('N'))
            $statePath = Join-Path $stateRoot 'windows-selection.json'
            $raw = & $runWriteState $FunctionText $statePath `
                (Join-Path $repoRoot 'platforms\windows\manifest.psd1') 'FedoraLinux-44' $false $false $true

            # Every selection flag is a JSON boolean rather than a string that
            # happens to read like one; verify.ps1 casts these, and PowerShell
            # reads the non-empty string 'false' as true.
            foreach ($flag in @('WslRequired', 'NocttySelected', 'NocttyConfigurationSelected', 'HandySelected')) {
                if ($raw -notmatch "`"$flag`"\s*:\s*(true|false)") {
                    throw "$flag is not a JSON boolean in the recorded state: $raw"
                }
            }

            $state = $raw | ConvertFrom-Json
            Assert-Equal -Actual $state.FedoraDistribution -Expected 'FedoraLinux-44' `
                -Message 'The recorded state named the wrong distribution.'
            Assert-Equal -Actual $state.SchemaVersion -Expected $windowsManifest.SchemaVersion `
                -Message 'The recorded state used the wrong schema version.'
            Assert-Equal -Actual $state.HandySelected -Expected $true `
                -Message 'A selected Handy was not recorded.'
            Assert-Equal -Actual $state.NocttySelected -Expected $true `
                -Message 'A selected Noctty was not recorded.'

            # The write is atomic through a temporary file, which must not be
            # left behind next to the state it replaced.
            $leftovers = @(Get-ChildItem -LiteralPath $stateRoot -Filter 'windows-selection-*.tmp')
            Assert-Equal -Actual $leftovers.Count -Expected 0 `
                -Message 'Recording the Windows selection left a temporary file behind.'
        }

    Assert-CaseCatchesMutation -Name 'The skipped components are recorded as skipped' `
        -FunctionText $writeStateText `
        -From 'NocttySelected = -not $SkipNoctty.IsPresent' -To 'NocttySelected = $true' `
        -Case {
            param([string]$FunctionText)

            $statePath = Join-Path $testRoot (
                'state-skip-{0}\windows-selection.json' -f [guid]::NewGuid().ToString('N'))
            $state = (& $runWriteState $FunctionText $statePath `
                (Join-Path $repoRoot 'platforms\windows\manifest.psd1') 'FedoraLinux-44' $true $true $false) |
                ConvertFrom-Json

            Assert-Equal -Actual $state.NocttySelected -Expected $false `
                -Message 'A skipped Noctty was recorded as selected.'
            Assert-Equal -Actual $state.NocttyConfigurationSelected -Expected $false `
                -Message 'A skipped Noctty configuration was recorded as selected.'
            Assert-Equal -Actual $state.HandySelected -Expected $false `
                -Message 'An unselected Handy was recorded as selected.'
        }

    # The two elevated phases are the only places this installer asks for
    # administrator rights, and a dry run must reach neither.
    $elevatedDryRunText = Get-InstallerFunctionText -Name @(
        'Invoke-ElevatedWslUpdate',
        'Invoke-ElevatedWslInstall'
    )
    Assert-CaseCatchesMutation -Name 'A dry run never asks for administrator rights' `
        -FunctionText $elevatedDryRunText `
        -From 'if ($DryRun) {' -To 'if ($false) {' `
        -Case {
            param([string]$FunctionText)

            $steps = & {
                param([string]$Text)

                $script:elevatedSteps = @()
                $DryRun = $true

                function Write-Step {
                    param([string]$Message)
                    $script:elevatedSteps += $Message
                }

                function Invoke-ElevatedPhase {
                    throw 'A dry run requested administrator approval.'
                }

                . ([scriptblock]::Create($Text))

                Invoke-ElevatedWslUpdate
                Invoke-ElevatedWslInstall -Distribution 'FedoraLinux-44'

                return $script:elevatedSteps
            } $FunctionText

            if ($steps -notcontains 'Would request administrator approval to update WSL') {
                throw "A dry-run WSL update did not describe itself: $($steps -join '; ')"
            }
            if ($steps -notcontains 'Would request administrator approval for WSL 2 and FedoraLinux-44') {
                throw "A dry-run WSL installation did not describe itself: $($steps -join '; ')"
            }
        }

    # Install-Noctty is Install-Handy's twin, and its dry run is the one a
    # user sees first: Scoop is absent, so there is no bucket list to read.
    $installNocttyText = Get-InstallerFunctionText -Name @(
        'Test-ScoopPackageInstalled',
        'Add-ScoopBucket',
        'Install-ScoopPackage',
        'Install-Scoop',
        'Install-Noctty'
    )
    Assert-CaseCatchesMutation -Name 'A dry run previews Noctty without a Scoop to ask' `
        -FunctionText $installNocttyText `
        -From 'if ($DryRun -and -not $scoop) {' -To 'if ($false) {' `
        -Case {
            param([string]$FunctionText)

            $steps = & {
                param([string]$Text, [string]$ManifestPath, [string]$ProfileRoot)

                $script:nocttyInstallSteps = @()
                $DryRun = $true
                $WindowsManifest = Import-PowerShellDataFile $ManifestPath
                $NocttyBucketUrl = $WindowsManifest.Scoop.NocttyBucket.Url
                $env:USERPROFILE = $ProfileRoot

                function Write-Step {
                    param([string]$Message)
                    $script:nocttyInstallSteps += $Message
                }

                function Get-Command {
                    param([string]$Name, $ErrorAction)
                    return $null
                }

                function Resolve-ScoopCommand { return $null }

                function Get-ScoopBucketList {
                    param([string]$Scoop)
                    throw 'A dry run without Scoop tried to list Scoop buckets.'
                }

                function Invoke-NativeCommand {
                    param([string]$FilePath, [string[]]$Arguments = @())
                    throw 'A dry run ran a command.'
                }

                . ([scriptblock]::Create($Text))

                Install-Noctty

                return $script:nocttyInstallSteps
            } $FunctionText (Join-Path $repoRoot 'platforms\windows\manifest.psd1') `
                (Join-Path $testRoot ('noctty-absent-{0}' -f [guid]::NewGuid().ToString('N')))

            if ($steps -notcontains 'Would install Scoop for the current Windows user') {
                throw "A dry run without Scoop did not describe installing it: $($steps -join '; ')"
            }
            if (-not ($steps -match 'Would install .+ for the current Windows user')) {
                throw "A dry run did not describe installing Noctty: $($steps -join '; ')"
            }
        }
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Windows PowerShell bootstrap helper tests passed.'
