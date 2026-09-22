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

    # -----------------------------------------------------------------------
    # The selection state, which decides what everything below it demands.
    # [bool] on whatever JSON happened to hold is not a reading of a boolean:
    # in PowerShell a non-empty string is true, so a hand-edited "false" read
    # as selected and an empty array read as not selected, and either way the
    # run still printed a green schema line.
    # -----------------------------------------------------------------------

    . (Join-Path $repoRoot 'platforms\windows\lib\selection-state.ps1')

    function New-SelectionStateJson {
        param([hashtable]$Override = @{})

        $state = [ordered]@{
            SchemaVersion = 1
            FedoraDistribution = 'FedoraLinux-44'
            WslRequired = $true
            NocttySelected = $true
            NocttyConfigurationSelected = $true
            HandySelected = $false
        }
        foreach ($key in $Override.Keys) { $state[$key] = $Override[$key] }
        return ($state | ConvertTo-Json)
    }

    $healthy = Read-WindowsSelectionState -Json (New-SelectionStateJson) -SupportedSchemaVersion 1
    Assert-Equal -Actual $healthy.Valid -Expected $true `
        -Message "A healthy selection state was rejected: $($healthy.Error)"
    Assert-Equal -Actual $healthy.NocttySelected -Expected $true `
        -Message 'A selected component was not read as selected.'
    Assert-Equal -Actual $healthy.HandySelected -Expected $false `
        -Message 'An unselected component was not read as unselected.'
    Assert-Equal -Actual $healthy.FedoraDistribution -Expected 'FedoraLinux-44' `
        -Message 'The recorded distribution was not read back.'

    # Only JSON true and false. Each of these was accepted before, and four of
    # them silently changed which components verification demanded.
    foreach ($value in @('false', 'no', '', 1, 0, $null, @(), @{}, 'true')) {
        $json = New-SelectionStateJson -Override @{ NocttySelected = $value }
        $read = Read-WindowsSelectionState -Json $json -SupportedSchemaVersion 1
        Assert-Equal -Actual $read.Valid -Expected $false `
            -Message "A NocttySelected that is not a boolean was accepted: $json"
        if ($read.Error -notlike 'NocttySelected is *not true or false') {
            throw "A non-boolean flag was rejected for the wrong reason: $($read.Error)"
        }
        Assert-Equal -Actual $read.NocttySelected -Expected $false `
            -Message 'A rejected state still answered a selection question.'
    }
    Write-Host 'PASS: only JSON true and false are accepted for a selection flag'

    # A flag that is simply absent is not "not selected": it is a state file
    # this checkout did not write, and defaulting it is how a component drops
    # out of verification without anybody being told.
    foreach ($required in @(
            'SchemaVersion', 'FedoraDistribution', 'WslRequired',
            'NocttySelected', 'NocttyConfigurationSelected', 'HandySelected'
        )) {
        $state = New-SelectionStateJson | ConvertFrom-Json
        $state.PSObject.Properties.Remove($required)
        $read = Read-WindowsSelectionState -Json ($state | ConvertTo-Json) -SupportedSchemaVersion 1
        Assert-Equal -Actual $read.Valid -Expected $false `
            -Message "A state missing $required was accepted."
        if ($read.Error -notlike "*no $required*") {
            throw "A state missing $required was rejected for the wrong reason: $($read.Error)"
        }
    }
    Write-Host 'PASS: every required property is required, and named when it is absent'

    # Schemas in both directions refuse, and say which they are, because the
    # remedy differs: rerun the installer, or update the checkout.
    $older = Read-WindowsSelectionState -SupportedSchemaVersion 1 `
        -Json (New-SelectionStateJson -Override @{ SchemaVersion = 0 })
    Assert-Equal -Actual $older.Valid -Expected $false -Message 'An older schema was accepted.'
    if ($older.Error -notlike '*no migration for it*') {
        throw "An older schema was refused without saying so: $($older.Error)"
    }
    $newer = Read-WindowsSelectionState -SupportedSchemaVersion 1 `
        -Json (New-SelectionStateJson -Override @{ SchemaVersion = 2 })
    Assert-Equal -Actual $newer.Valid -Expected $false -Message 'A future schema was accepted.'
    if ($newer.Error -notlike '*this checkout cannot read it*') {
        throw "A future schema was refused without saying so: $($newer.Error)"
    }
    $quoted = Read-WindowsSelectionState -SupportedSchemaVersion 1 `
        -Json (New-SelectionStateJson -Override @{ SchemaVersion = '1' })
    Assert-Equal -Actual $quoted.Valid -Expected $false `
        -Message 'A quoted schema version was accepted as the number it looks like.'

    # The distribution reaches wsl.exe and a regex in this script, so it is held
    # to the shape install.ps1 would have accepted.
    foreach ($bad in @('', 'Fedora Linux 44', 'Fedora;rm -rf', 44, $true, $null, @())) {
        $read = Read-WindowsSelectionState -SupportedSchemaVersion 1 `
            -Json (New-SelectionStateJson -Override @{ FedoraDistribution = $bad })
        Assert-Equal -Actual $read.Valid -Expected $false `
            -Message "An invalid FedoraDistribution was accepted: '$bad'"
    }
    Write-Host 'PASS: the recorded distribution must be a distribution name'

    # A file that is not a JSON object at all answers every property lookup
    # with nothing, which would read as a state whose selections are all absent.
    foreach ($notAnObject in @('[]', '[1,2]', '1', '"text"', 'true', 'null', '', '   ')) {
        $read = Read-WindowsSelectionState -Json $notAnObject -SupportedSchemaVersion 1
        Assert-Equal -Actual $read.Valid -Expected $false `
            -Message "A state that is not a JSON object was accepted: $notAnObject"
    }
    $unparseable = Read-WindowsSelectionState -Json '{ "SchemaVersion": ' -SupportedSchemaVersion 1
    Assert-Equal -Actual $unparseable.Valid -Expected $false -Message 'Unparseable JSON was accepted.'
    if ($unparseable.Error -notlike 'it is not JSON*') {
        throw "Unparseable JSON was rejected for the wrong reason: $($unparseable.Error)"
    }
    Write-Host 'PASS: a state that is not a JSON object is not a state'

    # An invalid state may not suppress the checks it was supposed to demand.
    $case = New-CaseFixture -Name 'invalid-state' -Change {
        param($item)
        $item.State.Valid = $false
        $item.State.Error = 'NocttySelected is the string "false", not true or false'
        $item.State.NocttySelected = $false
        $item.State.NocttyConfigurationSelected = $false
        $item.State.HandySelected = $false
        $item.State.WslRequired = $false
    }
    $result = Invoke-Verifier -Fixture $case
    Assert-FailureContains -Name 'an invalid selection state' -Result $result `
        -Expected 'Windows selection state is invalid: NocttySelected is the string "false"'
    foreach ($suppressed in @(
            'No Scoop-owned application is selected',
            'Noctty configuration is not selected',
            'WSL is not recorded as required'
        )) {
        if ($result.Output -like "*$suppressed*") {
            throw ("An unreadable state was allowed to answer for the machine: " +
                "$suppressed")
        }
    }
    if ($result.Output -notlike '*depends on the selection state, which could not be read*') {
        throw "An invalid state did not say what it stopped: $($result.Output)"
    }

    # Every helper verify.ps1 dot-sources is held to the same read-only
    # contract as the verifier itself. The list is taken from the script's own
    # dot-source lines rather than written out here, so a helper added later
    # cannot join the verifier without joining the contract.
    $verifierSource = Get-Content -LiteralPath $verifier -Raw
    $helpers = @(
        [regex]::Matches($verifierSource, "(?m)^\. \(Join-Path \`$PSScriptRoot '(?<path>[^']+)'\)") |
            ForEach-Object { $_.Groups['path'].Value }
    )
    if ($helpers.Count -lt 1) {
        throw 'No dot-sourced helper was found in verify.ps1, so none was held to the contract.'
    }
    $source = $verifierSource
    foreach ($helper in $helpers) {
        $source += (Get-Content -LiteralPath (
                Join-Path $repoRoot "platforms\windows\$($helper.Replace('/', '\'))") -Raw)
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
