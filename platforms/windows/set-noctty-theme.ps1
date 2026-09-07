[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('latte', 'frappe', 'macchiato', 'mocha')]
    [string]$Flavor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configDirectory = Join-Path $env:LOCALAPPDATA 'noctty\dotfiles'
$themeConfig = Join-Path $configDirectory 'theme.conf'
$content = "theme = catppuccin-$Flavor.conf`r`n"

[IO.Directory]::CreateDirectory($configDirectory) | Out-Null
$temporaryConfig = Join-Path $configDirectory (
    'theme-{0}.tmp' -f [guid]::NewGuid().ToString('N')
)
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)

try {
    [IO.File]::WriteAllText($temporaryConfig, $content, $utf8WithoutBom)
    if (Test-Path -LiteralPath $themeConfig) {
        # Windows PowerShell does not accept a null backup path for
        # File.Replace. Delete the old managed file before moving the new
        # one; user-authored settings are not touched because this file is
        # owned by the dotfiles bridge.
        [IO.File]::Delete($themeConfig)
        [IO.File]::Move($temporaryConfig, $themeConfig)
    }
    else {
        [IO.File]::Move($temporaryConfig, $themeConfig)
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryConfig) {
        Remove-Item -LiteralPath $temporaryConfig -Force
    }
}

Write-Host "Noctty: selected Catppuccin $Flavor."
Write-Host 'Noctty: press Ctrl+Shift+, to reload, or restart Noctty.'
