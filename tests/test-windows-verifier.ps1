[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$verifier = Join-Path $repoRoot 'platforms\windows\verify.ps1'
$topLevelVerifier = Join-Path $repoRoot 'verify.ps1'
$healthyFixture = Join-Path $repoRoot 'tests\fixtures\windows-verifier\healthy.json'
$nocttyFixture = Join-Path $repoRoot 'tests\fixtures\windows-verifier\healthy-noctty.json'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'dotfiles-windows-verifier-{0}' -f [guid]::NewGuid().ToString('N')
)
$powerShell = (Get-Process -Id $PID).Path
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Invoke-Verifier {
    param(
        [string]$Fixture,
        [switch]$TopLevel
    )

    $entryPoint = if ($TopLevel) { $topLevelVerifier } else { $verifier }
    $output = & $powerShell -NoProfile -File $entryPoint -FixturePath $Fixture 2>&1 | Out-String
    return [pscustomobject]@{
        Status = $LASTEXITCODE
        Output = $output
    }
}

function Assert-Success {
    param([object]$Result, [string]$Name)
    if ($Result.Status -ne 0) {
        throw "$Name unexpectedly failed with $($Result.Status): $($Result.Output)"
    }
}

function Assert-FailureContains {
    param([object]$Result, [string]$Expected, [string]$Name)
    if ($Result.Status -eq 0) {
        throw "$Name unexpectedly passed: $($Result.Output)"
    }
    if ($Result.Output -notlike "*$Expected*") {
        throw "$Name did not report '$Expected': $($Result.Output)"
    }
}

function New-CaseFixture {
    param(
        [string]$Name,
        [scriptblock]$Change
    )

    $observation = Get-Content -LiteralPath $nocttyFixture -Raw | ConvertFrom-Json
    & $Change $observation
    $path = Join-Path $testRoot "$Name.json"
    $observation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

try {
    $tokens = $null
    $errors = $null
    foreach ($file in @($verifier, $topLevelVerifier)) {
        [System.Management.Automation.Language.Parser]::ParseFile(
            $file, [ref]$tokens, [ref]$errors
        ) | Out-Null
        if ($errors.Count -gt 0) {
            throw "PowerShell parse failure in ${file}: $($errors -join '; ')"
        }
    }

    Assert-Success -Name 'healthy baseline' `
        -Result (Invoke-Verifier -Fixture $healthyFixture -TopLevel)
    Assert-Success -Name 'Noctty selected and present' `
        -Result (Invoke-Verifier -Fixture $nocttyFixture)

    $case = New-CaseFixture -Name 'selected-missing' -Change {
        param($item)
        $item.Scoop.Package.CommandPath = $null
    }
    Assert-FailureContains -Name 'Noctty selected and missing' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Noctty resolves outside Scoop shims'

    $case = New-CaseFixture -Name 'package-missing' -Change {
        param($item)
        $item.Scoop.Package.Exists = $false
    }
    Assert-FailureContains -Name 'missing Scoop package' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Declared Scoop package is missing: noctty'

    $case = New-CaseFixture -Name 'wrong-command-owner' -Change {
        param($item)
        $item.Scoop.Package.CommandPath = 'C:\Tools\noctty.exe'
    }
    Assert-FailureContains -Name 'wrong command owner' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Noctty resolves outside Scoop shims'

    $case = New-CaseFixture -Name 'broken-config' -Change {
        param($item)
        $item.Configuration.Files[1].BrokenLink = $true
    }
    Assert-FailureContains -Name 'broken managed configuration link' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'shared Ghostty configuration is a broken link'

    $case = New-CaseFixture -Name 'stale-checkout' -Change {
        param($item)
        $item.Configuration.Files[1].StaleLink = $true
        $item.Configuration.Files[1].LinkTarget = 'C:\old-checkout\ghostty\shared.conf'
    }
    Assert-FailureContains -Name 'stale checkout link' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'shared Ghostty configuration points at another checkout'

    $case = New-CaseFixture -Name 'old-wsl' -Change {
        param($item)
        $item.Wsl.InstalledVersion = '2.7.12'
    }
    Assert-FailureContains -Name 'unsupported WSL baseline' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'does not satisfy the >= 2.7.13 baseline'

    $case = New-CaseFixture -Name 'missing-distro' -Change {
        param($item)
        $item.Wsl.DistributionPresent = $false
    }
    Assert-FailureContains -Name 'missing Fedora WSL distribution' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Recorded Fedora WSL distribution is missing: FedoraLinux-44'

    $source = Get-Content -LiteralPath $verifier -Raw
    foreach ($forbidden in @(
        'Invoke-WebRequest',
        'Invoke-RestMethod',
        'Copy-Item',
        'Move-Item',
        'New-Item',
        'Start-Process',
        'wsl.exe --update',
        "'install',"
    )) {
        if ($source.Contains($forbidden)) {
            throw "Read-only verifier contains forbidden mutation primitive: $forbidden"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Windows installed-state verifier fixture tests passed.'
exit 0
