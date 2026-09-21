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
    $elevatedPhase = $installerAst.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-ElevatedPhase'
        },
        $true
    )
    if (-not $elevatedPhase) {
        throw 'install.ps1 no longer defines Invoke-ElevatedPhase.'
    }

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
        $declined = & $runElevatedPhase $elevatedPhase.Extent.Text $shape

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
    $declinedInstall = & $runElevatedPhase $elevatedPhase.Extent.Text $declinedShapes[0] `
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
    $transient = & $runElevatedPhase $elevatedPhase.Extent.Text {
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

    $functionDefinitions = @{}
    foreach ($definition in $installerAst.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        },
        $true
    )) {
        $functionDefinitions[$definition.Name] = $definition.Extent.Text
    }

    $handyFunctionNames = @(
        'Test-ScoopPackageInstalled',
        'Add-ScoopBucket',
        'Install-ScoopPackage',
        'Install-Handy'
    )
    foreach ($handyFunctionName in $handyFunctionNames) {
        if (-not $functionDefinitions.ContainsKey($handyFunctionName)) {
            throw "install.ps1 no longer defines ${handyFunctionName}."
        }
    }
    $handyFunctionText = (
        $handyFunctionNames | ForEach-Object { $functionDefinitions[$_] }
    ) -join "`n"

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
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Windows PowerShell bootstrap helper tests passed.'
