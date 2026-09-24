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
$originalScoopRoot = $env:SCOOP

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

    # Builds the part of a Scoop root a case is about, the way Scoop builds it:
    # a bucket is a git checkout with an origin, and a finished package install
    # leaves a manifest, the executable and install.json naming the bucket that
    # supplied it. A fixture that leaves any of those out is a machine in a
    # state the installer has to notice, not a shortcut.
    $newScoopBucket = {
        param([string]$Root, [string]$Name, [AllowNull()][string]$Origin)

        $git = Join-Path (Join-Path (Join-Path $Root 'buckets') $Name) '.git'
        [IO.Directory]::CreateDirectory($git) | Out-Null
        if ($null -ne $Origin) {
            [IO.File]::WriteAllText((Join-Path $git 'config'), @"
[remote "origin"]
	url = $Origin
"@)
        }
    }

    $newScoopPackage = {
        param(
            [string]$Root,
            [string]$Name,
            [string]$Executable,
            [AllowNull()][string]$Bucket
        )

        $current = Join-Path (Join-Path (Join-Path $Root 'apps') $Name) 'current'
        [IO.Directory]::CreateDirectory($current) | Out-Null
        [IO.File]::WriteAllText((Join-Path $current 'manifest.json'), '{ "version": "1.0.0" }')
        [IO.File]::WriteAllText((Join-Path $current $Executable), '')
        if ($null -ne $Bucket) {
            [IO.File]::WriteAllText(
                (Join-Path $current 'install.json'),
                ('{{ "bucket": "{0}" }}' -f $Bucket))
        }
    }

    # Runs the shipped Install-Handy with Scoop, the native command runner and
    # the step log replaced, so bucket selection, idempotency and dry-run
    # honesty are exercised without Scoop, a network or an elevated session.
    # The shared ownership predicate is the real lib\scoop.ps1, not a stub:
    # whether this Scoop root holds the declared bucket and package is the one
    # question install.ps1 and verify.ps1 must never answer differently.
    $runInstallHandy = {
        param(
            [string]$FunctionText,
            [string]$ManifestPath,
            [string[]]$Buckets,
            [bool]$DryRunValue,
            [string]$ProfileRoot,
            [string[]]$ResolvableCommands = @(),
            [string]$ScoopRoot = ''
        )

        $script:handySteps = @()
        $script:handyCommands = @()
        $script:handyBuckets = $Buckets
        $script:handyResolvable = $ResolvableCommands
        $DryRun = $DryRunValue
        $WindowsManifest = Import-PowerShellDataFile $ManifestPath
        $env:USERPROFILE = $ProfileRoot
        $env:SCOOP = $ScoopRoot

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

        function Install-Scoop {
            throw 'Install-Handy bootstrapped Scoop when Scoop was already available.'
        }

        function Get-ScoopBucketList {
            param([string]$Scoop)
            return $script:handyBuckets
        }

        . (Join-Path $PSScriptRoot '..\platforms\windows\lib\scoop.ps1')

        function Resolve-ScoopCommand { return 'C:\fixture\scoop\shims\scoop.ps1' }

        . ([scriptblock]::Create($FunctionText))

        $failure = $null
        try { Install-Handy }
        catch { $failure = $_.Exception.Message }

        [pscustomobject]@{
            Steps = $script:handySteps
            Commands = $script:handyCommands
            Failure = $failure
        }
    }

    $extrasUrl = 'https://github.com/ScoopInstaller/Extras'
    $withoutExtras = @(
        'Name Source Updated Manifests',
        'main https://github.com/ScoopInstaller/Main 2026-01-01 1000'
    )
    $withExtras = $withoutExtras + @(
        "extras $extrasUrl 2026-01-01 2000"
    )
    $emptyProfile = Join-Path $testRoot 'HandyAbsent'
    [IO.Directory]::CreateDirectory($emptyProfile) | Out-Null

    $dryRun = & $runInstallHandy $handyFunctionText $manifestPath $withoutExtras $true $emptyProfile
    Assert-Equal -Actual $dryRun.Failure -Expected $null `
        -Message 'A dry run on a clean machine must not fail.'
    Assert-Equal -Actual $dryRun.Commands.Count -Expected 0 `
        -Message 'A dry run must not run any Scoop command.'
    if ($dryRun.Steps -notcontains "Would add the extras Scoop bucket: $extrasUrl") {
        throw "A dry run did not describe adding the extras bucket: $($dryRun.Steps -join '; ')"
    }
    if ($dryRun.Steps -notcontains
        'Would install extras/handy for the current Windows user') {
        throw "A dry run did not describe installing Handy: $($dryRun.Steps -join '; ')"
    }

    # An already-added bucket is a bucket Scoop lists *and* has on disk at the
    # declared origin. The list alone is not it: reading only the name is the
    # defect this case used to model.
    $bucketPresentProfile = Join-Path $testRoot 'ExtrasPresent'
    & $newScoopBucket (Join-Path $bucketPresentProfile 'scoop') 'extras' $extrasUrl
    $dryRunBucketPresent = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $true $bucketPresentProfile
    Assert-Equal -Actual $dryRunBucketPresent.Failure -Expected $null `
        -Message 'The declared extras bucket was rejected.'
    if ($dryRunBucketPresent.Steps -match 'Would add the extras Scoop bucket') {
        throw 'An already-added extras bucket was described as needing to be added.'
    }

    # Harmless spellings of the same repository are the same repository.
    foreach ($spelling in @("$extrasUrl.git", "$extrasUrl/", 'https://github.com/scoopinstaller/extras')) {
        $spellingProfile = Join-Path $testRoot ('ExtrasSpelling-{0}' -f [guid]::NewGuid().ToString('N'))
        & $newScoopBucket (Join-Path $spellingProfile 'scoop') 'extras' $spelling
        $spelt = & $runInstallHandy $handyFunctionText $manifestPath `
            ($withoutExtras + @("extras $spelling 2026-01-01 2000")) $true $spellingProfile
        Assert-Equal -Actual $spelt.Failure -Expected $null `
            -Message "The extras bucket spelled '$spelling' was rejected."
        if ($spelt.Steps -match 'Would add the extras Scoop bucket') {
            throw "The extras bucket spelled '$spelling' was not recognised as present."
        }
    }

    # Fail closed. Scoop keys buckets by name, so `bucket add extras <url>` on a
    # machine that already has an `extras` reports the existing one as present
    # and installs out of it. A bucket cloned from another repository is not the
    # declared one and this run stops rather than installing from it.
    $substitutedProfile = Join-Path $testRoot 'ExtrasSubstituted'
    $foreignUrl = 'https://github.com/someone-else/Extras'
    & $newScoopBucket (Join-Path $substitutedProfile 'scoop') 'extras' $foreignUrl
    $substituted = & $runInstallHandy $handyFunctionText $manifestPath `
        ($withoutExtras + @("extras $foreignUrl 2026-01-01 2000")) $false $substitutedProfile
    Assert-Equal -Actual $substituted.Commands.Count -Expected 0 `
        -Message 'A substituted extras bucket did not stop the install.'
    if ($substituted.Failure -notlike "*is already present but is not $extrasUrl*") {
        throw "A substituted extras bucket was not reported: $($substituted.Failure)"
    }
    if ($substituted.Failure -notlike "*points at $foreignUrl*") {
        throw "A substituted extras bucket did not name what it points at: $($substituted.Failure)"
    }

    # The table and the checkout disagreeing is the same refusal: whichever of
    # the two is stale, this is not a machine to install from.
    $mismatchProfile = Join-Path $testRoot 'ExtrasMismatch'
    & $newScoopBucket (Join-Path $mismatchProfile 'scoop') 'extras' $extrasUrl
    $mismatch = & $runInstallHandy $handyFunctionText $manifestPath `
        ($withoutExtras + @("extras $foreignUrl 2026-01-01 2000")) $false $mismatchProfile
    Assert-Equal -Actual $mismatch.Commands.Count -Expected 0 `
        -Message 'A bucket table disagreeing with the checkout did not stop the install.'
    if ($mismatch.Failure -notlike "*Scoop lists it as $foreignUrl*") {
        throw ('A stale bucket table was not told from a substituted checkout: ' +
            "$($mismatch.Failure)")
    }

    # A bucket directory with no Git configuration is a bucket whose origin
    # cannot be established, which is not the same as the declared one.
    $originlessProfile = Join-Path $testRoot 'ExtrasOriginless'
    & $newScoopBucket (Join-Path $originlessProfile 'scoop') 'extras' $null
    $originless = & $runInstallHandy $handyFunctionText $manifestPath `
        ($withoutExtras + @("extras $extrasUrl 2026-01-01 2000")) $false $originlessProfile
    Assert-Equal -Actual $originless.Commands.Count -Expected 0 `
        -Message 'A bucket with no Git remote did not stop the install.'
    if ($originless.Failure -notlike '*has no Git remote*') {
        throw "A bucket with no Git remote was not reported: $($originless.Failure)"
    }

    $install = & $runInstallHandy $handyFunctionText $manifestPath `
        $withoutExtras $false $emptyProfile
    if ($install.Commands -notcontains "bucket add extras $extrasUrl") {
        throw "Handy was installed without adding the extras bucket: $($install.Commands -join '; ')"
    }
    if ($install.Commands -notcontains 'install extras/handy') {
        throw "Handy was not installed from the extras bucket: $($install.Commands -join '; ')"
    }

    $rerun = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $false $bucketPresentProfile
    Assert-Equal -Actual $rerun.Commands.Count -Expected 1 `
        -Message 'A rerun re-added the extras bucket.'

    # Idempotency: a Handy that Scoop finished installing out of the declared
    # bucket is left alone.
    $installedProfile = Join-Path $testRoot 'HandyPresent'
    $installedRoot = Join-Path $installedProfile 'scoop'
    & $newScoopBucket $installedRoot 'extras' $extrasUrl
    & $newScoopPackage $installedRoot 'handy' 'handy.exe' 'extras'

    $alreadyInstalled = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $false $installedProfile
    Assert-Equal -Actual $alreadyInstalled.Commands.Count -Expected 0 `
        -Message 'An installed Handy was installed again.'
    if ($alreadyInstalled.Steps -notcontains 'Handy is already installed') {
        throw "An installed Handy was not reported as present: $($alreadyInstalled.Steps -join '; ')"
    }

    # Scoop writes install.json last, so an apps directory holding a manifest
    # and the executable is an install that was started. The old fast path
    # accepted exactly this and skipped the install that would have finished it.
    $partialProfile = Join-Path $testRoot 'HandyPartial'
    $partialRoot = Join-Path $partialProfile 'scoop'
    & $newScoopBucket $partialRoot 'extras' $extrasUrl
    & $newScoopPackage $partialRoot 'handy' 'handy.exe' $null
    $partial = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $false $partialProfile
    if ($partial.Commands -notcontains 'install extras/handy') {
        throw ('A half-finished Handy install was treated as complete: ' +
            "$($partial.Steps -join '; ')")
    }

    # A Handy that came from somebody else's bucket is not extras/handy, and a
    # rerun has to install the declared one rather than report it present.
    $foreignBucketProfile = Join-Path $testRoot 'HandyForeignBucket'
    $foreignBucketRoot = Join-Path $foreignBucketProfile 'scoop'
    & $newScoopBucket $foreignBucketRoot 'extras' $extrasUrl
    & $newScoopPackage $foreignBucketRoot 'handy' 'handy.exe' 'personal'
    $foreignBucket = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $false $foreignBucketProfile
    if ($foreignBucket.Commands -notcontains 'install extras/handy') {
        throw ('A Handy from another bucket was treated as the declared one: ' +
            "$($foreignBucket.Steps -join '; ')")
    }

    # PATH is not an install record. A handy.exe anywhere on PATH used to
    # satisfy the fast path, which is how an unrelated provider suppressed the
    # declared Scoop installation.
    $onPath = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $false $bucketPresentProfile @('handy')
    if ($onPath.Commands -notcontains 'install extras/handy') {
        throw ('A resolvable handy command outside Scoop suppressed the install: ' +
            "$($onPath.Steps -join '; ')")
    }

    # A custom $env:SCOOP root is where a healthy install lives on the machines
    # that set it, and the parent session's PATH says nothing about it.
    $customRoot = Join-Path $testRoot 'CustomScoopRoot'
    & $newScoopBucket $customRoot 'extras' $extrasUrl
    & $newScoopPackage $customRoot 'handy' 'handy.exe' 'extras'
    $custom = & $runInstallHandy $handyFunctionText $manifestPath `
        $withExtras $false $emptyProfile @() $customRoot
    Assert-Equal -Actual $custom.Failure -Expected $null `
        -Message 'A healthy Handy under a custom $env:SCOOP root was rejected.'
    Assert-Equal -Actual $custom.Commands.Count -Expected 0 `
        -Message 'A healthy Handy under a custom $env:SCOOP root was installed again.'

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
        $env:LOCALAPPDATA = $LocalAppData

        # The real parser, not a stub: how many managed blocks the file holds
        # and what is inside one is the same question verify.ps1 asks, and the
        # two may not answer it differently.
        . (Join-Path $PSScriptRoot '..\platforms\windows\lib\noctty-config.ps1')

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

        $failure = $null
        try { Set-NocttyConfiguration -Distribution $Distribution }
        catch { $failure = $_.Exception.Message }

        $configPath = Join-Path $LocalAppData 'noctty\config.ghostty'
        [pscustomobject]@{
            Steps = $script:nocttySteps
            Warnings = $script:nocttyWarnings
            SyncCalls = $script:nocttySyncCalls
            Failure = $failure
            Exists = Test-Path -LiteralPath $configPath
            Content = if (Test-Path -LiteralPath $configPath) {
                [IO.File]::ReadAllText($configPath)
            }
            else { $null }
        }
    }

    Assert-CaseCatchesMutation -Name 'A rerun of the Noctty configuration is a byte-for-byte no-op' `
        -FunctionText $setNocttyText `
        -From 'Remove-NocttyManagedBlocks -Content $content' -To '$content' `
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
        -From 'Test-NocttyUserCommand -Content $userContent' -To '$false' `
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

    Assert-CaseCatchesMutation -Name 'Every managed block converges to one, not just the first' `
        -FunctionText $setNocttyText `
        -From 'Remove-NocttyManagedBlocks -Content $content' `
        -To '[regex]::new(''(?ms)^# BEGIN dotfiles Fedora WSL\r?\n.*?^# END dotfiles Fedora WSL\r?\n?'').Replace($content, '''''', 1)' `
        -Case {
            param([string]$FunctionText)

            # What a machine has after one bootstrap wrote a block and a later
            # one prepended another: two managed blocks, the older naming a
            # distribution that is gone. Removing only the first leaves that
            # one behind, and its command line then reads as the user's, so the
            # installer declines to write the command the run is about and the
            # file ends up naming only the distribution nobody asked for.
            $appData = Join-Path $testRoot ('noctty-dupe-{0}' -f [guid]::NewGuid().ToString('N'))
            $configPath = Join-Path $appData 'noctty\config.ghostty'
            [IO.Directory]::CreateDirectory((Split-Path -Parent $configPath)) | Out-Null
            [IO.File]::WriteAllText($configPath, (@(
                        '# BEGIN dotfiles Fedora WSL'
                        'config-file = "dotfiles/ghostty.conf"'
                        'config-file = "dotfiles/theme.conf"'
                        'command = direct:wsl.exe --distribution FedoraLinux-43'
                        '# END dotfiles Fedora WSL'
                        '# BEGIN dotfiles Fedora WSL'
                        'config-file = "dotfiles/ghostty.conf"'
                        'config-file = "dotfiles/theme.conf"'
                        'command = direct:wsl.exe --distribution FedoraLinux-42'
                        '# END dotfiles Fedora WSL'
                        'window-padding-x = 8'
                    ) -join "`n") + "`n")

            $result = & $runSetNoctty $FunctionText $appData $false 'FedoraLinux-44'
            Assert-Equal -Actual $result.Failure -Expected $null `
                -Message 'Converging duplicate managed blocks failed.'
            $markers = ([regex]::Matches($result.Content, '(?m)^# BEGIN dotfiles Fedora WSL\r?$')).Count
            Assert-Equal -Actual $markers -Expected 1 `
                -Message 'The configuration did not converge to exactly one managed block.'
            if ($result.Content -notmatch 'command = direct:wsl\.exe --distribution FedoraLinux-44') {
                throw "The converged block does not name this run's distribution: $($result.Content)"
            }
            foreach ($stale in @('FedoraLinux-43', 'FedoraLinux-42')) {
                if ($result.Content -match [regex]::Escape($stale)) {
                    throw "A stale distribution survived convergence: $($result.Content)"
                }
            }
            Assert-Equal -Actual $result.Warnings.Count -Expected 0 `
                -Message 'A command inside a stale managed block was mistaken for a user command.'
            if ($result.Content -notmatch '(?m)^window-padding-x = 8\r?$') {
                throw "User-owned content was lost: $($result.Content)"
            }
        }

    # Zero blocks and one block are the other two starting points, and all
    # three have to end at the same file.
    $oneBlockStart = (@(
            '# BEGIN dotfiles Fedora WSL'
            'config-file = "dotfiles/ghostty.conf"'
            'config-file = "dotfiles/theme.conf"'
            'command = direct:wsl.exe --distribution FedoraLinux-43'
            '# END dotfiles Fedora WSL'
            'window-padding-x = 8'
        ) -join "`n") + "`n"
    $convergedContents = @()
    foreach ($start in @(
            @{ Name = 'no managed block'; Existing = "window-padding-x = 8`n" },
            @{ Name = 'one managed block'; Existing = $oneBlockStart }
        )) {
        $appData = Join-Path $testRoot ('noctty-converge-{0}' -f [guid]::NewGuid().ToString('N'))
        $configPath = Join-Path $appData 'noctty\config.ghostty'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $configPath)) | Out-Null
        [IO.File]::WriteAllText($configPath, $start.Existing)

        $converged = & $runSetNoctty $setNocttyText $appData $false 'FedoraLinux-44'
        Assert-Equal -Actual $converged.Failure -Expected $null `
            -Message "Converging a file with $($start.Name) failed."
        Assert-Equal `
            -Actual (([regex]::Matches($converged.Content, '(?m)^# BEGIN dotfiles Fedora WSL\r?$')).Count) `
            -Expected 1 -Message "A file with $($start.Name) did not converge to one block."
        if ($converged.Content -notmatch '(?m)^window-padding-x = 8\r?$') {
            throw "User-owned content was lost converging a file with $($start.Name)."
        }
        $convergedContents += $converged.Content
    }
    Assert-Equal -Actual $convergedContents[0] -Expected $convergedContents[1] `
        -Message 'Files starting with no block and with one block converged differently.'
    Write-Host 'PASS: zero, one and many managed blocks all converge to exactly one'

    # Markers that do not pair up are not a file whose managed region can be
    # identified, so nothing is written rather than something guessed at.
    foreach ($malformed in @(
            @{
                Name = 'an unclosed BEGIN'
                Text = "# BEGIN dotfiles Fedora WSL`nconfig-file = `"dotfiles/ghostty.conf`"`n"
            },
            @{
                Name = 'an END before any BEGIN'
                Text = "# END dotfiles Fedora WSL`nwindow-padding-x = 8`n"
            },
            @{
                Name = 'a nested BEGIN'
                Text = "# BEGIN dotfiles Fedora WSL`n# BEGIN dotfiles Fedora WSL`n# END dotfiles Fedora WSL`n"
            }
        )) {
        $appData = Join-Path $testRoot ('noctty-bad-{0}' -f [guid]::NewGuid().ToString('N'))
        $configPath = Join-Path $appData 'noctty\config.ghostty'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $configPath)) | Out-Null
        [IO.File]::WriteAllText($configPath, $malformed.Text)

        $rejected = & $runSetNoctty $setNocttyText $appData $false 'FedoraLinux-44'
        if (-not $rejected.Failure) {
            throw "$($malformed.Name) was rewritten instead of refused: $($rejected.Content)"
        }
        if ($rejected.Failure -notlike '*nothing was changed*') {
            throw "$($malformed.Name) was refused without saying the file is untouched: $($rejected.Failure)"
        }
        Assert-Equal -Actual $rejected.Content -Expected $malformed.Text `
            -Message "$($malformed.Name) left the file modified."
    }
    Write-Host 'PASS: markers that do not pair up are refused without touching the file'

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
            # happens to read like one; verify.ps1 rejects anything else, and
            # PowerShell reads the non-empty string 'false' as true.
            foreach ($flag in @('WslRequired', 'NocttySelected', 'NocttyConfigurationSelected', 'HandySelected')) {
                if ($raw -notmatch "`"$flag`"\s*:\s*(true|false)") {
                    throw "$flag is not a JSON boolean in the recorded state: $raw"
                }
            }

            # The reader the verifier uses, asked of what the writer just
            # wrote. This is the one assertion that fails if either side moves
            # without the other: a state install.ps1 records has to be one
            # verify.ps1 accepts, unchanged.
            . (Join-Path $PSScriptRoot '..\platforms\windows\lib\selection-state.ps1')
            $read = Read-WindowsSelectionState -Json $raw `
                -SupportedSchemaVersion ([int]$windowsManifest.SchemaVersion)
            Assert-Equal -Actual $read.Valid -Expected $true `
                -Message "The verifier rejected a state install.ps1 wrote: $($read.Error)"
            Assert-Equal -Actual $read.HandySelected -Expected $true `
                -Message 'The verifier read a selected Handy as unselected.'
            Assert-Equal -Actual $read.FedoraDistribution -Expected 'FedoraLinux-44' `
                -Message 'The verifier read back the wrong distribution.'

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
                $env:SCOOP = $ProfileRoot

                # The shared ownership predicate, not a stub: whether this
                # machine already has noctty/noctty is the same question
                # verify.ps1 asks, and a dry run answers it before it previews.
                . (Join-Path $PSScriptRoot '..\platforms\windows\lib\scoop.ps1')

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

    # The Scoop installer is a staged third-party script, and on Windows it is
    # the only one (#504). It runs with the allowlisted environment only: a
    # token or API key in this session must not reach it, and this session must
    # have every variable back afterwards, including after a failing installer.
    if ((Get-InstallerFunctionText -Name 'Install-Scoop') -notmatch
        'Invoke-MinimalEnvironmentCommand -FilePath ''powershell\.exe''') {
        throw 'Install-Scoop must run the Scoop installer through Invoke-MinimalEnvironmentCommand.'
    }
    $minimalEnvironmentText = Get-InstallerFunctionText -Name @(
        'Invoke-NativeCommand',
        'Get-InstallerEnvironmentName',
        'Invoke-MinimalEnvironmentCommand'
    )
    Assert-CaseCatchesMutation -Name 'A staged installer inherits no token or API key' `
        -FunctionText $minimalEnvironmentText `
        -From "[Environment]::SetEnvironmentVariable(`$name, `$null, 'Process')" `
        -To '$null = $name' `
        -Case {
            param([string]$FunctionText)

            & {
                param([string]$Text, [string]$Shell)

                . ([scriptblock]::Create($Text))
                $env:GITHUB_TOKEN = 'fixture-value-not-a-credential'
                $env:ANTHROPIC_API_KEY = 'fixture-value-not-an-api-key'
                try {
                    # The child exits 3 when it sees either variable and 4 when
                    # it has lost PATH, which Invoke-NativeCommand turns into a
                    # throw; 0 means it saw exactly the minimal environment.
                    Invoke-MinimalEnvironmentCommand -FilePath $Shell -Arguments @(
                        '-NoProfile', '-Command',
                        'if ($env:GITHUB_TOKEN -or $env:ANTHROPIC_API_KEY) { exit 3 }; if (-not $env:PATH) { exit 4 }; exit 0'
                    )
                    if ($env:GITHUB_TOKEN -ne 'fixture-value-not-a-credential') {
                        throw 'The caller lost its own GITHUB_TOKEN after the installer ran.'
                    }

                    $failed = $false
                    try {
                        Invoke-MinimalEnvironmentCommand -FilePath $Shell -Arguments @(
                            '-NoProfile', '-Command', 'exit 9'
                        )
                    }
                    catch { $failed = $true }
                    if (-not $failed) { throw 'A failing installer was reported as a success.' }
                    if ($env:ANTHROPIC_API_KEY -ne 'fixture-value-not-an-api-key') {
                        throw 'A failing installer left the caller without its own variables.'
                    }
                }
                finally {
                    Remove-Item Env:GITHUB_TOKEN, Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
                    # The deliberately failing child leaves its status in
                    # $LASTEXITCODE, and the Actions pwsh step exits with it.
                    $global:LASTEXITCODE = 0
                }
            } $FunctionText ((Get-Process -Id $PID).Path)
        }

    # Scoop's installer is fetched at the pinned commit and refused unless its
    # SHA-256 is the pinned one, before anything runs it (#504). The case pins
    # the digest of the content it serves as "reviewed", then serves other
    # bytes and requires a refusal that runs nothing and leaves nothing behind.
    Assert-CaseCatchesMutation -Name 'A Scoop installer that differs from its pin is never run' `
        -FunctionText (Get-InstallerFunctionText -Name 'Install-Scoop') `
        -From 'if ($actualDigest -ne $ScoopInstallerSha256) {' `
        -To 'if ($false) {' `
        -Case {
            param([string]$FunctionText)

            & {
                param([string]$Text)

                function Write-Step { param([string]$Message) }
                function Resolve-ScoopCommand { return 'C:\fixture\scoop\shims\scoop.ps1' }
                function Invoke-WebRequest {
                    param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile, [int]$TimeoutSec)
                    $script:scoopRequested += @($Uri)
                    $script:scoopStaged = $OutFile
                    [IO.File]::WriteAllText($OutFile, $script:scoopServed)
                }
                function Invoke-MinimalEnvironmentCommand {
                    param([string]$FilePath, [string[]]$Arguments)
                    $script:scoopRuns += @($Arguments[-1])
                }

                $DryRun = $false
                $ScoopInstallerCommit = '1e2f334083d609986d8c8bc9e31ae8e87c39fab4'
                $reviewed = "Write-Output 'reviewed'`n"
                $reviewedPath = Join-Path ([IO.Path]::GetTempPath()) ('scoop-pin-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
                [IO.File]::WriteAllText($reviewedPath, $reviewed)
                $ScoopInstallerSha256 = (Get-FileHash -LiteralPath $reviewedPath -Algorithm SHA256).Hash.ToLowerInvariant()
                Remove-Item -LiteralPath $reviewedPath -Force

                . ([scriptblock]::Create($Text))

                $script:scoopRequested = @()
                $script:scoopRuns = @()
                $script:scoopServed = $reviewed
                Install-Scoop | Out-Null
                if ($script:scoopRequested -notcontains
                    "https://raw.githubusercontent.com/ScoopInstaller/Install/$ScoopInstallerCommit/install.ps1") {
                    throw "Scoop's installer was not fetched at the pinned commit: $($script:scoopRequested -join ', ')"
                }
                if ($script:scoopRuns.Count -ne 1) {
                    throw 'The pinned Scoop installer was not run.'
                }

                $script:scoopRuns = @()
                $script:scoopServed = "Write-Output 'tampered'`n"
                $failure = $null
                try { Install-Scoop | Out-Null }
                catch { $failure = $_.Exception.Message }
                if ($failure -notmatch 'SHA-256 mismatch for the Scoop installer') {
                    throw "A Scoop installer that differs from its pin was not refused: $failure"
                }
                if ($script:scoopRuns.Count -ne 0) {
                    throw 'A Scoop installer that differs from its pin was run.'
                }
                if (Test-Path -LiteralPath $script:scoopStaged) {
                    throw 'A refused Scoop installer was left on disk.'
                }
            } $FunctionText
        }
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:USERPROFILE = $originalUserProfile
    $env:SCOOP = $originalScoopRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Windows PowerShell bootstrap helper tests passed.'
