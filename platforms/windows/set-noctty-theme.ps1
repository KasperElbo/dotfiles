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
        [IO.File]::Replace($temporaryConfig, $themeConfig, $null)
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

$nocttyCandidates = @(
    (Join-Path $env:USERPROFILE 'scoop\apps\noctty\current\noctty.exe'),
    (Join-Path $env:USERPROFILE 'scoop\shims\noctty.ps1'),
    (Join-Path $env:USERPROFILE 'scoop\shims\noctty.cmd')
)
$noctty = $nocttyCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1

if (-not $noctty) {
    Write-Host 'Noctty: the new theme will apply on its next launch.'
    exit 0
}

& $noctty '+perform-action' '--timeout=1000' 'reload_config' 2>$null
switch ($LASTEXITCODE) {
    0 {
        Write-Host 'Noctty: reloaded the running instance.'
    }
    2 {
        Write-Host 'Noctty: the new theme will apply on its next launch.'
    }
    default {
        Write-Warning 'Noctty could not reload automatically; press Ctrl+Shift+, in Noctty.'
    }
}
