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
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Windows PowerShell bootstrap helper tests passed.'
