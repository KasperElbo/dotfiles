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
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Windows PowerShell bootstrap helper tests passed.'
