[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installer = Join-Path $repoRoot 'platforms\windows\install.ps1'
$themeHelper = Join-Path $repoRoot 'platforms\windows\set-noctty-theme.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'dotfiles-windows-test-{0}' -f [guid]::NewGuid().ToString('N')
)
$originalLocalAppData = $env:LOCALAPPDATA
$originalUserProfile = $env:USERPROFILE

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Actual,
        [Parameter(Mandatory = $true)]
        [object]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

try {
    foreach ($powershellFile in @($installer, $themeHelper)) {
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
