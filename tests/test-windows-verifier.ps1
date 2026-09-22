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

    $case = New-CaseFixture -Name 'package-missing' -Change {
        param($item)
        $item.Scoop.Package.Exists = $false
    }
    Assert-FailureContains -Name 'missing Scoop package' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Declared Scoop package is missing: noctty'

    # A bucket by the declared name that was cloned from somewhere else is the
    # substitution the whole ownership check exists for, and the only thing
    # that tells it from the real one is where its checkout points.
    $case = New-CaseFixture -Name 'substituted-bucket' -Change {
        param($item)
        $item.Scoop.Bucket.OriginUrl = 'https://github.com/someone-else/scoop-noctty'
        $item.Scoop.Bucket.OriginMatches = $false
        $item.Scoop.Bucket.Owned = $false
    }
    Assert-FailureContains -Name 'same-name bucket from another origin' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Scoop bucket noctty is not https://github.com/amanthanvi/scoop-noctty'

    $case = New-CaseFixture -Name 'bucket-without-remote' -Change {
        param($item)
        $item.Scoop.ExtrasBucket.OriginUrl = $null
        $item.Scoop.ExtrasBucket.OriginMatches = $false
        $item.Scoop.ExtrasBucket.Owned = $false
    }
    Assert-FailureContains -Name 'bucket directory with no Git remote' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'it points at no Git remote'

    # Scoop writes install.json last, so a directory with a manifest and an
    # executable in it is an install that was started, not one that finished
    # out of the declared bucket.
    $case = New-CaseFixture -Name 'package-without-install-record' -Change {
        param($item)
        $item.Scoop.Package.InstalledBucket = $null
        $item.Scoop.Package.BucketMatches = $false
        $item.Scoop.Package.Installed = $false
    }
    Assert-FailureContains -Name 'package with no recorded bucket' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'noctty was installed from no recorded bucket'

    $case = New-CaseFixture -Name 'package-from-another-bucket' -Change {
        param($item)
        $item.Scoop.HandyPackage.InstalledBucket = 'personal'
        $item.Scoop.HandyPackage.BucketMatches = $false
        $item.Scoop.HandyPackage.Installed = $false
    }
    Assert-FailureContains -Name 'package supplied by another bucket' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected "handy was installed from the 'personal' bucket, not 'extras'"

    $case = New-CaseFixture -Name 'package-without-manifest' -Change {
        param($item)
        $item.Scoop.Package.HasManifest = $false
        $item.Scoop.Package.Installed = $false
    }
    Assert-FailureContains -Name 'package directory without a Scoop manifest' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'noctty has no Scoop manifest'

    $case = New-CaseFixture -Name 'unreadable-install-record' -Change {
        param($item)
        $item.Scoop.Package.MetadataError = 'Unexpected token in JSON'
        $item.Scoop.Package.Installed = $false
    }
    Assert-FailureContains -Name 'unreadable Scoop install metadata' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Scoop install metadata for noctty is unreadable'

    $case = New-CaseFixture -Name 'package-executable-missing' -Change {
        param($item)
        $item.Scoop.Package.HasExecutable = $false
        $item.Scoop.Package.Installed = $false
    }
    Assert-FailureContains -Name 'package without its declared executable' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Noctty executable is missing'

    # PATH is a usability observation, not an ownership one: the session that
    # ran the install cannot see the registry PATH it just extended, and a
    # same-named program earlier on PATH shadows a correctly installed package
    # without making it any less installed. Both warn; neither fails.
    $case = New-CaseFixture -Name 'command-not-on-path' -Change {
        param($item)
        $item.Scoop.Package.CommandPath = $null
    }
    $result = Invoke-Verifier -Fixture $case
    Assert-Success -Name 'installed Noctty not yet on PATH' -Result $result
    if ($result.Output -notlike '*Noctty resolves to no command yet*') {
        throw "A shim that has not reached PATH was not reported: $($result.Output)"
    }

    $case = New-CaseFixture -Name 'wrong-command-owner' -Change {
        param($item)
        $item.Scoop.Package.CommandPath = 'C:\Tools\noctty.exe'
    }
    $result = Invoke-Verifier -Fixture $case
    Assert-Success -Name 'installed Noctty shadowed on PATH' -Result $result
    if ($result.Output -notlike '*Noctty resolves outside Scoop shims*') {
        throw "A shadowed Noctty command was not reported: $($result.Output)"
    }

    # The same shadowing on top of a package that is *not* installed is still a
    # failure, so the demotion above cannot be read as "PATH no longer matters".
    $case = New-CaseFixture -Name 'shadowed-and-not-installed' -Change {
        param($item)
        $item.Scoop.Package.CommandPath = 'C:\Tools\noctty.exe'
        $item.Scoop.Package.InstalledBucket = $null
        $item.Scoop.Package.BucketMatches = $false
        $item.Scoop.Package.Installed = $false
    }
    Assert-FailureContains -Name 'uninstalled Noctty shadowed by another program' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'noctty was installed from no recorded bucket'

    # Dictation (Handy) is optional and Scoop-owned. Unselected absence is
    # clean, selection is verified exactly like Noctty, and neither selection
    # depends on the other.
    $case = New-CaseFixture -Name 'handy-unselected' -Change {
        param($item)
        $item.State.HandySelected = $false
        $item.Scoop.ExtrasBucket.Exists = $false
        $item.Scoop.ExtrasBucket.OriginUrl = $null
        $item.Scoop.ExtrasBucket.OriginMatches = $false
        $item.Scoop.ExtrasBucket.Owned = $false
        $item.Scoop.HandyPackage.Exists = $false
        $item.Scoop.HandyPackage.HasManifest = $false
        $item.Scoop.HandyPackage.HasExecutable = $false
        $item.Scoop.HandyPackage.InstalledBucket = $null
        $item.Scoop.HandyPackage.BucketMatches = $false
        $item.Scoop.HandyPackage.Installed = $false
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

    # A Handy executable that is not under Scoop's apps directory is not the
    # one Scoop installed, whatever the metadata beside it claims.
    $case = New-CaseFixture -Name 'handy-outside-scoop' -Change {
        param($item)
        $item.Scoop.HandyPackage.ExecutablePath = 'C:\Program Files\Handy\handy.exe'
    }
    Assert-FailureContains -Name 'Handy owned outside Scoop' `
        -Result (Invoke-Verifier -Fixture $case) `
        -Expected 'Handy current executable is outside Scoop ownership'

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
    # The ownership predicate itself, against a Scoop root built on disk the
    # way Scoop builds one. The JSON fixtures above prove how the verifier
    # words each observation; these prove that the observations are the ones a
    # real tree produces -- and they are the same functions install.ps1 asks
    # before it installs anything, so the two cannot answer differently.
    # -----------------------------------------------------------------------

    $nocttyBucketDeclaration = @{
        Name = 'noctty'
        Url = 'https://github.com/amanthanvi/scoop-noctty'
    }
    $nocttyPackageDeclaration = @{
        Name = 'noctty'
        QualifiedName = 'noctty/noctty'
        Executable = 'noctty.exe'
    }

    function New-ScoopBucketFixture {
        param([string]$Root, [string]$Name, [AllowNull()][string]$Origin)

        $path = Join-Path (Join-Path $Root 'buckets') $Name
        [IO.Directory]::CreateDirectory((Join-Path $path '.git')) | Out-Null
        if ($null -ne $Origin) {
            [IO.File]::WriteAllText(
                (Join-Path (Join-Path $path '.git') 'config'),
                @"
[core]
	bare = false
[remote "upstream"]
	url = https://example.invalid/decoy
[remote "origin"]
	url = $Origin
[branch "master"]
	remote = origin
"@)
        }
        return $path
    }

    function New-ScoopPackageFixture {
        param(
            [string]$Root,
            [string]$Name,
            [string]$Executable,
            [AllowNull()][string]$Bucket,
            [bool]$WithManifest = $true,
            [bool]$WithExecutable = $true,
            [string]$InstallJson
        )

        $current = Join-Path (Join-Path (Join-Path $Root 'apps') $Name) 'current'
        [IO.Directory]::CreateDirectory($current) | Out-Null
        if ($WithManifest) {
            [IO.File]::WriteAllText((Join-Path $current 'manifest.json'), '{ "version": "1.0.0" }')
        }
        if ($WithExecutable) {
            [IO.File]::WriteAllText((Join-Path $current $Executable), '')
        }
        if ($PSBoundParameters.ContainsKey('InstallJson')) {
            [IO.File]::WriteAllText((Join-Path $current 'install.json'), $InstallJson)
        }
        elseif ($null -ne $Bucket) {
            [IO.File]::WriteAllText(
                (Join-Path $current 'install.json'),
                ('{{ "bucket": "{0}", "architecture": "64bit" }}' -f $Bucket))
        }
        return $current
    }

    $ownershipRoot = Join-Path $testRoot 'OwnershipScoop'

    # A bucket Scoop cloned from the declared repository, with the harmless
    # spellings Git and Scoop both accept: a trailing .git and a trailing
    # slash normalise away, and GitHub matches owner and repository names
    # case-insensitively.
    foreach ($origin in @(
            'https://github.com/amanthanvi/scoop-noctty',
            'https://github.com/amanthanvi/scoop-noctty.git',
            'https://github.com/amanthanvi/scoop-noctty/',
            'https://github.com/AmanThanvi/Scoop-Noctty.git'
        )) {
        $caseRoot = Join-Path $ownershipRoot ('origin-{0}' -f [guid]::NewGuid().ToString('N'))
        New-ScoopBucketFixture -Root $caseRoot -Name 'noctty' -Origin $origin | Out-Null
        $ownership = Get-ScoopBucketOwnership -Bucket $nocttyBucketDeclaration -Root $caseRoot
        Assert-Equal -Actual $ownership.Owned -Expected $true `
            -Message "The declared bucket spelled '$origin' was not recognised."
        Assert-Equal -Actual $ownership.BucketListRead -Expected $false `
            -Message 'A bucket table that was never read must not read as read.'
        Assert-Equal -Actual $ownership.Registered -Expected $null `
            -Message 'An unread bucket table must leave Registered unknown, not false.'
    }

    # Everything else is a different repository and must stay one. A bucket
    # that only differs after the host, or by one character in the repository
    # name, is exactly the substitution this check is for.
    foreach ($origin in @(
            'https://github.com/someone-else/scoop-noctty',
            'https://github.com/amanthanvi/scoop-noctty-fork',
            'https://gitlab.com/amanthanvi/scoop-noctty',
            'https://github.com/amanthanvi/scoop-nocttyx'
        )) {
        $caseRoot = Join-Path $ownershipRoot ('foreign-{0}' -f [guid]::NewGuid().ToString('N'))
        New-ScoopBucketFixture -Root $caseRoot -Name 'noctty' -Origin $origin | Out-Null
        $ownership = Get-ScoopBucketOwnership -Bucket $nocttyBucketDeclaration -Root $caseRoot
        Assert-Equal -Actual $ownership.Owned -Expected $false `
            -Message "A bucket cloned from '$origin' was accepted as the declared one."
        Assert-Equal -Actual $ownership.OriginUrl -Expected $origin `
            -Message 'The observed origin was not reported as found.'
    }

    # A bucket directory with no Git configuration at all: present, unowned,
    # and reported as having no remote rather than as matching.
    $caseRoot = Join-Path $ownershipRoot 'no-remote'
    New-ScoopBucketFixture -Root $caseRoot -Name 'noctty' -Origin $null | Out-Null
    $ownership = Get-ScoopBucketOwnership -Bucket $nocttyBucketDeclaration -Root $caseRoot
    Assert-Equal -Actual $ownership.Exists -Expected $true `
        -Message 'A bucket directory that is there must read as present.'
    Assert-Equal -Actual $ownership.OriginUrl -Expected $null `
        -Message 'A bucket with no Git configuration must report no origin.'
    Assert-Equal -Actual $ownership.Owned -Expected $false `
        -Message 'A bucket with no Git configuration was accepted as declared.'

    $caseRoot = Join-Path $ownershipRoot 'absent'
    $ownership = Get-ScoopBucketOwnership -Bucket $nocttyBucketDeclaration -Root $caseRoot
    Assert-Equal -Actual $ownership.Exists -Expected $false `
        -Message 'A bucket that was never added must not read as present.'
    Assert-Equal -Actual $ownership.Owned -Expected $false `
        -Message 'A bucket that was never added must not read as owned.'

    # The bucket table, when a caller has one. `scoop bucket list` prints a
    # header and one row per bucket; the name and the URL on the same row are
    # one fact, and reading only the name is what let a substituted bucket pass.
    $listRoot = Join-Path $ownershipRoot 'listed'
    New-ScoopBucketFixture -Root $listRoot -Name 'noctty' `
        -Origin 'https://github.com/amanthanvi/scoop-noctty' | Out-Null
    $table = @(
        'Name   Source                                          Updated     Manifests',
        '----   ------                                          -------     ---------',
        'main   https://github.com/ScoopInstaller/Main          2026-01-01       1000',
        'noctty https://github.com/amanthanvi/scoop-noctty.git  2026-01-01          4'
    )
    # The table reader writes one row per bucket to the pipeline. Returning the
    # whole array as one value is what would send the table through a filter as
    # a single item, where $_.Name enumerates to every name at once and the
    # filter matches whatever it is given, so the shape is pinned here.
    Assert-Equal -Actual (@(ConvertFrom-ScoopBucketList -Lines $table).Count) -Expected 2 `
        -Message 'The bucket table was not read as one row per bucket.'
    Assert-Equal -Actual (@(ConvertFrom-ScoopBucketList -Lines @(
                'Name Source',
                'main https://github.com/ScoopInstaller/Main 2026-01-01 1000'
            )).Count) -Expected 1 `
        -Message 'A one-bucket table was not read as one row.'
    Assert-Equal -Actual (@(ConvertFrom-ScoopBucketList -Lines @()).Count) -Expected 0 `
        -Message 'An empty bucket table was not read as no rows.'

    $ownership = Get-ScoopBucketOwnership -Bucket $nocttyBucketDeclaration `
        -BucketList $table -Root $listRoot
    Assert-Equal -Actual $ownership.BucketListRead -Expected $true `
        -Message 'A supplied bucket table must read as read.'
    Assert-Equal -Actual $ownership.Registered -Expected $true `
        -Message 'A listed bucket was not found in the bucket table.'
    Assert-Equal -Actual $ownership.ConfiguredMatches -Expected $true `
        -Message 'A listed bucket at the declared URL was not recognised.'
    Assert-Equal -Actual $ownership.Owned -Expected $true `
        -Message 'A listed bucket at the declared URL was not owned.'

    $substituted = $table -replace 'amanthanvi/scoop-noctty', 'someone-else/scoop-noctty'
    $ownership = Get-ScoopBucketOwnership -Bucket $nocttyBucketDeclaration `
        -BucketList $substituted -Root $listRoot
    Assert-Equal -Actual $ownership.Registered -Expected $true `
        -Message 'A substituted bucket is still registered under its name.'
    Assert-Equal -Actual $ownership.ConfiguredMatches -Expected $false `
        -Message 'A bucket listed at another URL was read as the declared one.'

    $ownership = Get-ScoopBucketOwnership -Bucket $nocttyBucketDeclaration `
        -BucketList @('Name Source', '---- ------') -Root $listRoot
    Assert-Equal -Actual $ownership.Registered -Expected $false `
        -Message 'A bucket table header was parsed as a bucket.'

    # Another bucket's row may not answer for this one. A filter fed the whole
    # table as a single value reads every name at once and matches whatever it
    # was given, which is how a bucket that is not listed at all reports a URL.
    $ownership = Get-ScoopBucketOwnership -Bucket $nocttyBucketDeclaration `
        -BucketList @(
            'Name Source',
            'main https://github.com/ScoopInstaller/Main 2026-01-01 1000'
        ) -Root $listRoot
    Assert-Equal -Actual $ownership.Registered -Expected $false `
        -Message 'A bucket absent from the table was matched by another row.'
    Assert-Equal -Actual $ownership.ConfiguredUrl -Expected $null `
        -Message 'A bucket absent from the table reported a configured URL.'
    Assert-Equal -Actual $ownership.ConfiguredMatches -Expected $false `
        -Message 'A bucket absent from the table was read as configured.'

    # Packages. install.json is what Scoop writes when an install finishes,
    # and its bucket field is the only record of which bucket supplied the
    # manifest; a directory, a manifest and an executable are all things a
    # half-finished or substituted install also has.
    $caseRoot = Join-Path $ownershipRoot 'package-healthy'
    New-ScoopPackageFixture -Root $caseRoot -Name 'noctty' `
        -Executable 'noctty.exe' -Bucket 'noctty' | Out-Null
    $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
        -BucketName 'noctty' -Root $caseRoot
    Assert-Equal -Actual $package.Installed -Expected $true `
        -Message 'A package Scoop finished installing was not read as installed.'
    Assert-Equal -Actual $package.InstalledBucket -Expected 'noctty' `
        -Message 'The recorded bucket was not read from install.json.'

    $caseRoot = Join-Path $ownershipRoot 'package-no-record'
    New-ScoopPackageFixture -Root $caseRoot -Name 'noctty' `
        -Executable 'noctty.exe' -Bucket $null | Out-Null
    $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
        -BucketName 'noctty' -Root $caseRoot
    Assert-Equal -Actual $package.Exists -Expected $true `
        -Message 'A started install leaves its directory behind and must read as present.'
    Assert-Equal -Actual $package.HasExecutable -Expected $true `
        -Message 'The fixture must have the executable, or it proves the wrong thing.'
    Assert-Equal -Actual $package.Installed -Expected $false `
        -Message 'A package with no install.json was read as installed.'

    $caseRoot = Join-Path $ownershipRoot 'package-other-bucket'
    New-ScoopPackageFixture -Root $caseRoot -Name 'noctty' `
        -Executable 'noctty.exe' -Bucket 'personal' | Out-Null
    $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
        -BucketName 'noctty' -Root $caseRoot
    Assert-Equal -Actual $package.InstalledBucket -Expected 'personal' `
        -Message 'The supplying bucket was not read from install.json.'
    Assert-Equal -Actual $package.Installed -Expected $false `
        -Message 'A package from another bucket was read as the declared one.'

    $caseRoot = Join-Path $ownershipRoot 'package-unreadable-record'
    New-ScoopPackageFixture -Root $caseRoot -Name 'noctty' `
        -Executable 'noctty.exe' -Bucket 'noctty' -InstallJson '{ "bucket": ' | Out-Null
    $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
        -BucketName 'noctty' -Root $caseRoot
    if (-not $package.MetadataError) {
        throw 'Unreadable Scoop install metadata was not reported as an error.'
    }
    Assert-Equal -Actual $package.Installed -Expected $false `
        -Message 'A package with unreadable install metadata was read as installed.'

    $caseRoot = Join-Path $ownershipRoot 'package-no-manifest'
    New-ScoopPackageFixture -Root $caseRoot -Name 'noctty' -Executable 'noctty.exe' `
        -Bucket 'noctty' -WithManifest $false | Out-Null
    $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
        -BucketName 'noctty' -Root $caseRoot
    Assert-Equal -Actual $package.Installed -Expected $false `
        -Message 'A package with no Scoop manifest was read as installed.'

    $caseRoot = Join-Path $ownershipRoot 'package-no-executable'
    New-ScoopPackageFixture -Root $caseRoot -Name 'noctty' -Executable 'noctty.exe' `
        -Bucket 'noctty' -WithExecutable $false | Out-Null
    $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
        -BucketName 'noctty' -Root $caseRoot
    Assert-Equal -Actual $package.Installed -Expected $false `
        -Message 'A package with no executable was read as installed.'

    $caseRoot = Join-Path $ownershipRoot 'package-absent'
    $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
        -BucketName 'noctty' -Root $caseRoot
    Assert-Equal -Actual $package.Exists -Expected $false `
        -Message 'A package that was never installed must not read as present.'
    Assert-Equal -Actual $package.Installed -Expected $false `
        -Message 'A package that was never installed must not read as installed.'

    # A program of the declared name somewhere else on PATH is what the old
    # fast path accepted as an install. It is now an observation beside the
    # verdict and may not move it, in either direction.
    $caseRoot = Join-Path $ownershipRoot 'package-shadowed'
    $foreignDirectory = Join-Path $ownershipRoot 'elsewhere'
    [IO.Directory]::CreateDirectory($foreignDirectory) | Out-Null
    $foreignCommand = Join-Path $foreignDirectory 'noctty'
    [IO.File]::WriteAllText($foreignCommand, '')
    $originalUserProfile = $env:USERPROFILE
    $originalScoop = $env:SCOOP
    $originalPath = $env:PATH
    try {
        $env:SCOOP = $caseRoot
        $env:PATH = $foreignDirectory
        $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
            -BucketName 'noctty' -Root $caseRoot
        Assert-Equal -Actual $package.Installed -Expected $false `
            -Message 'A command found outside Scoop satisfied the installed verdict.'

        New-ScoopPackageFixture -Root $caseRoot -Name 'noctty' `
            -Executable 'noctty.exe' -Bucket 'noctty' | Out-Null
        $package = Get-ScoopPackageOwnership -Package $nocttyPackageDeclaration `
            -BucketName 'noctty' -Root $caseRoot
        Assert-Equal -Actual $package.Installed -Expected $true `
            -Message 'A shadowing command on PATH made a real install read as absent.'
    }
    finally {
        $env:USERPROFILE = $originalUserProfile
        $env:SCOOP = $originalScoop
        $env:PATH = $originalPath
    }

    # The helper verify.ps1 dot-sources is held to the same read-only contract
    # as the verifier itself.
    $source = (Get-Content -LiteralPath $verifier -Raw) +
        (Get-Content -LiteralPath (Join-Path $repoRoot 'platforms\windows\lib\scoop.ps1') -Raw)
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
