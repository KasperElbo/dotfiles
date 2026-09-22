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
    Assert-Success -Name 'Noctty and Handy selected and present' `
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

    # Dictation (Handy) is optional and Scoop-owned. Unselected absence is
    # clean, selection is verified exactly like Noctty, and neither selection
    # depends on the other.
    $case = New-CaseFixture -Name 'handy-unselected' -Change {
        param($item)
        $item.State.HandySelected = $false
        $item.Scoop.ExtrasBucket.Exists = $false
        $item.Scoop.HandyPackage.Exists = $false
        $item.Scoop.HandyPackage.CommandPath = $null
    }
    Assert-Success -Name 'Handy unselected and absent' `
        -Result (Invoke-Verifier -Fixture $case)

    $case = New-CaseFixture -Name 'handy-only' -Change {
        param($item)
        $item.State.NocttySelected = $false
        $item.State.NocttyConfigurationSelected = $false
        $item.Configuration.Files = @()
    }
    Assert-Success -Name 'Handy selected without Noctty' `
        -Result (Invoke-Verifier -Fixture $case)

    $case = New-CaseFixture -Name 'handy-package-missing' -Change {
        param($item)
        $item.Scoop.HandyPackage.Exists = $false
    }
    Assert-FailureContains -Name 'missing Handy package' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Declared Scoop package is missing: handy'

    $case = New-CaseFixture -Name 'extras-bucket-missing' -Change {
        param($item)
        $item.Scoop.ExtrasBucket.Exists = $false
    }
    Assert-FailureContains -Name 'missing Scoop extras bucket' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Declared Scoop bucket is missing: extras'

    # A Handy installed by any other provider resolves outside Scoop's shims,
    # which is how duplicate or non-Scoop ownership is caught.
    $case = New-CaseFixture -Name 'handy-outside-scoop' -Change {
        param($item)
        $item.Scoop.HandyPackage.CommandPath = 'C:\Program Files\Handy\handy.exe'
    }
    Assert-FailureContains -Name 'Handy owned outside Scoop' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Handy resolves outside Scoop shims'

    # The managed block, read as one structure. Each of these passed the four
    # independent global regex matches this replaced, because every line the
    # verifier looked for did occur somewhere in the file.
    $case = New-CaseFixture -Name 'duplicate-managed-block' -Change {
        param($item)
        $item.Configuration.ManagedBlock.Count = 2
        $item.Configuration.ManagedBlock.Body = $null
    }
    Assert-FailureContains -Name 'two managed blocks' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'has 2 repository-managed blocks'

    $case = New-CaseFixture -Name 'no-managed-block' -Change {
        param($item)
        $item.Configuration.ManagedBlock.Count = 0
        $item.Configuration.ManagedBlock.Body = $null
    }
    Assert-FailureContains -Name 'no managed block' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'has no repository-managed block'

    $case = New-CaseFixture -Name 'malformed-markers' -Change {
        param($item)
        $item.Configuration.ManagedBlock.MarkerError = 'a BEGIN marker is never closed by an END marker'
        $item.Configuration.ManagedBlock.Body = $null
    }
    Assert-FailureContains -Name 'markers that do not pair up' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'malformed managed block: a BEGIN marker is never closed'

    $case = New-CaseFixture -Name 'stale-distribution' -Change {
        param($item)
        $item.Configuration.ManagedBlock.Body =
        $item.Configuration.ManagedBlock.Body.Replace('FedoraLinux-44', 'FedoraLinux-42')
    }
    Assert-FailureContains -Name 'a block naming another distribution' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'managed block is not what this checkout writes for FedoraLinux-44'

    # A required line moved out of the block is exactly what a presence-only
    # check cannot see: the line is still in the file, just not where this
    # repository puts it.
    $case = New-CaseFixture -Name 'split-required-line' -Change {
        param($item)
        $item.Configuration.ManagedBlock.Body =
        $item.Configuration.ManagedBlock.Body.Replace(
            "config-file = `"dotfiles/theme.conf`"`n", '')
    }
    Assert-FailureContains -Name 'a required line outside the block' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'managed block is not what this checkout writes'

    $case = New-CaseFixture -Name 'extra-line-in-block' -Change {
        param($item)
        $item.Configuration.ManagedBlock.Body =
        $item.Configuration.ManagedBlock.Body + "window-padding-x = 99`n"
    }
    Assert-FailureContains -Name 'a line this checkout does not write' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'managed block is not what this checkout writes'

    # A user command outside the block is the documented third state, and the
    # block this checkout writes for it is a different one.
    $case = New-CaseFixture -Name 'user-command-honoured' -Change {
        param($item)
        $item.Configuration.ManagedBlock.UserCommand = $true
        $item.Configuration.ManagedBlock.Body =
        $item.Configuration.ManagedBlock.Body.Replace(
            'command = direct:wsl.exe --distribution FedoraLinux-44',
            '# Fedora WSL command omitted: a user-managed command exists below.')
    }
    Assert-Success -Name 'a user-managed command in control' `
        -Result (Invoke-Verifier -Fixture $case)

    $case = New-CaseFixture -Name 'user-command-overridden' -Change {
        param($item)
        $item.Configuration.ManagedBlock.UserCommand = $true
    }
    Assert-FailureContains -Name 'a user command the block overrode' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'managed block is not what this checkout writes'

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

    # Scoop resolution must not depend on PATH. The Scoop installer runs in a
    # child PowerShell and a package shim reaches PATH through the registry, so
    # the session that ran a completely successful install still cannot see
    # scoop, noctty or handy through Get-Command. Without the shims fallback the
    # verifier reported three healthy things as missing, two of them with an
    # empty path, and exited 1.
    . (Join-Path $repoRoot 'platforms\windows\lib\scoop.ps1')

    $shimProfile = Join-Path $testRoot 'ShimProfile'
    $shimDirectory = Join-Path $shimProfile 'scoop\shims'
    [IO.Directory]::CreateDirectory($shimDirectory) | Out-Null
    foreach ($shim in @('scoop.ps1', 'scoop.cmd', 'noctty.exe', 'handy.exe')) {
        [IO.File]::WriteAllText((Join-Path $shimDirectory $shim), '')
    }

    $originalUserProfile = $env:USERPROFILE
    $originalScoop = $env:SCOOP
    $originalPath = $env:PATH
    try {
        $env:USERPROFILE = $shimProfile
        $env:SCOOP = ''
        # Nothing at all on PATH: exactly what the installing session sees.
        $env:PATH = ''

        Assert-Equal -Actual (Get-ScoopRoot) `
            -Expected ([IO.Path]::GetFullPath((Join-Path $shimProfile 'scoop'))) `
            -Message 'The Scoop root was not taken from the Windows user profile.'
        Assert-Equal -Actual (Resolve-ScoopCommand) `
            -Expected (Join-Path $shimDirectory 'scoop.ps1') `
            -Message 'Scoop was not found in its shims directory with PATH empty.'
        foreach ($package in @('noctty', 'handy')) {
            Assert-Equal `
                -Actual (Resolve-ScoopShimCommand -Name $package) `
                -Expected (Join-Path $shimDirectory "$package.exe") `
                -Message "$package was not found in its shims directory with PATH empty."
        }
        Assert-Equal -Actual (Resolve-ScoopShimCommand -Name 'not-installed') `
            -Expected $null `
            -Message 'A command in neither PATH nor the shims directory must not resolve.'

        # The invariant the function owes its callers, which the fixture
        # above cannot express because it only ever empties PATH: a shim pair
        # must mean the same file whether or not the shims have reached PATH
        # yet. Which file that is belongs to PowerShell; that the two branches
        # agree on it belongs here. The resolved path is invoked as a command,
        # and a .ps1 shim runs in the caller's PowerShell while a .cmd shim
        # runs as a child process, so the two branches disagreeing is a real
        # behavioural difference and not a spelling one.
        $env:PATH = ''
        $resolvedWithoutPath = Resolve-ScoopCommand
        $env:PATH = $shimDirectory
        $resolvedWithPath = Resolve-ScoopCommand
        Assert-Equal -Actual $resolvedWithoutPath -Expected $resolvedWithPath `
            -Message 'A shim pair resolved to a different file once PATH had the shims.'
        if ($resolvedWithPath -ne (Join-Path $shimDirectory 'scoop.ps1')) {
            throw ('Scoop did not resolve inside its own shims directory: ' +
                "$resolvedWithPath")
        }

        # Neither extension may be the only one the fallback knows: a machine
        # with one half of the pair still has Scoop installed.
        foreach ($onlyShim in @('scoop.ps1', 'scoop.cmd')) {
            $soleProfile = Join-Path $testRoot ('SoleShim-{0}' -f $onlyShim.Replace('.', '-'))
            $soleDirectory = Join-Path $soleProfile 'scoop\shims'
            [IO.Directory]::CreateDirectory($soleDirectory) | Out-Null
            [IO.File]::WriteAllText((Join-Path $soleDirectory $onlyShim), '')

            $env:PATH = ''
            $env:SCOOP = ''
            $env:USERPROFILE = $soleProfile
            Assert-Equal -Actual (Resolve-ScoopCommand) `
                -Expected (Join-Path $soleDirectory $onlyShim) `
                -Message "Scoop was not found when only $onlyShim was published."
        }

        $env:USERPROFILE = $shimProfile
        $env:SCOOP = Join-Path $testRoot 'ExplicitScoop'
        Assert-Equal -Actual (Get-ScoopRoot) `
            -Expected ([IO.Path]::GetFullPath($env:SCOOP)) `
            -Message 'An explicit $env:SCOOP must decide where the shims are looked for.'
    }
    finally {
        $env:USERPROFILE = $originalUserProfile
        $env:SCOOP = $originalScoop
        $env:PATH = $originalPath
    }

    # The helper verify.ps1 dot-sources is held to the same read-only contract
    # as the verifier itself.
    $source = (Get-Content -LiteralPath $verifier -Raw)
    foreach ($helper in @('scoop.ps1', 'noctty-config.ps1')) {
        $source += (Get-Content -LiteralPath (
                Join-Path $repoRoot "platforms\windows\lib\$helper") -Raw)
    }
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

    # Every application this verifier proves is Scoop-owned, Handy included.
    if ($source -match '(?i)winget') {
        throw 'Windows verification must prove Scoop ownership, never WinGet ownership.'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Windows installed-state verifier fixture tests passed.'
exit 0
