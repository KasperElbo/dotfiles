<#
.SYNOPSIS
Verifies the repository-owned Windows and WSL installation state without mutation.

.DESCRIPTION
Checks the recorded Windows selection, Scoop ownership for selected Noctty and
selected Handy, repository-managed Noctty configuration copies, and the
Windows-owned WSL package/distribution baseline. It never installs, updates,
authenticates, creates configuration, launches a WSL distribution, or starts
the dictation application.
#>
[CmdletBinding()]
param(
    [string]$StatePath,

    [Parameter(DontShow = $true)]
    [string]$FixturePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'manifest.psd1')
. (Join-Path $PSScriptRoot 'lib\wsl-version.ps1')
. (Join-Path $PSScriptRoot 'lib\scoop.ps1')
. (Join-Path $PSScriptRoot 'lib\selection-state.ps1')

if (-not $StatePath) {
    if ($FixturePath) {
        $StatePath = '<fixture selection state>'
    }
    else {
        $StatePath = Join-Path $env:LOCALAPPDATA $Manifest.SelectionStateRelativePath
    }
}

$script:Passes = 0
$script:Warnings = 0
$script:Failures = 0

function Write-VerificationPass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
    $script:Passes++
}

function Write-VerificationWarning {
    param([string]$Message)
    Write-Warning $Message
    $script:Warnings++
}

function Write-VerificationFailure {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    $script:Failures++
}

function ConvertTo-NormalizedPath {
    param([string]$Value)

    if ($Value -notmatch '^[A-Za-z]:[\\/]') {
        return [IO.Path]::GetFullPath($Value)
    }

    $windowsValue = $Value.Replace('/', '\')
    $drive = $windowsValue.Substring(0, 3)
    $segments = [Collections.Generic.List[string]]::new()
    foreach ($segment in $windowsValue.Substring(3).Split('\')) {
        if (-not $segment -or $segment -eq '.') { continue }
        if ($segment -eq '..') {
            if ($segments.Count -gt 0) {
                [void]$segments.RemoveAt($segments.Count - 1)
            }
            continue
        }
        [void]$segments.Add($segment)
    }
    if ($segments.Count -eq 0) {
        return $drive
    }
    return $drive + ($segments -join '\')
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if (-not $Path -or -not $Root) { return $false }
    try {
        $trimCharacters = [char[]]@('\', '/')
        $fullPath = (ConvertTo-NormalizedPath $Path).TrimEnd($trimCharacters)
        $fullRoot = (ConvertTo-NormalizedPath $Root).TrimEnd($trimCharacters)
        $separator = if ($Path -match '^[A-Za-z]:[\\/]') { '\' } else { [IO.Path]::DirectorySeparatorChar }
        if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        return $fullPath.StartsWith(
            "$fullRoot$separator",
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Join-ObservedPath {
    param(
        [string]$Root,
        [string]$Child
    )

    if ($Root -match '^[A-Za-z]:[\\/]') {
        $trimmedRoot = $Root.TrimEnd([char[]]@('\', '/'))
        return "$trimmedRoot\$Child"
    }
    return Join-Path $Root $Child
}

function Get-LinkObservation {
    param(
        [string]$Path,
        [string]$ExpectedRepositoryRoot
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [pscustomobject]@{
            Exists = $false
            BrokenLink = $false
            StaleLink = $false
            LinkTarget = $null
        }
    }

    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return [pscustomobject]@{
            Exists = $true
            BrokenLink = $false
            StaleLink = $false
            LinkTarget = $null
        }
    }

    $rawTarget = @($item.Target) | Select-Object -First 1
    if (-not $rawTarget) {
        return [pscustomobject]@{
            Exists = $true
            BrokenLink = $true
            StaleLink = $false
            LinkTarget = $null
        }
    }

    $target = [string]$rawTarget
    if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $Path) $target
    }
    $target = [IO.Path]::GetFullPath($target)
    $targetExists = Test-Path -LiteralPath $target
    return [pscustomobject]@{
        Exists = $true
        BrokenLink = -not $targetExists
        StaleLink = (
            $targetExists -and
            -not (Test-PathWithinRoot -Path $target -Root $ExpectedRepositoryRoot)
        )
        LinkTarget = $target
    }
}

function New-ManagedFileObservation {
    param(
        [string]$Name,
        [string]$Target,
        [AllowNull()]
        [string]$Source
    )

    $link = Get-LinkObservation -Path $Target -ExpectedRepositoryRoot $RepositoryRoot
    $matchesSource = $true
    if ($Source) {
        $matchesSource = (
            $link.Exists -and
            -not $link.BrokenLink -and
            (Test-Path -LiteralPath $Source -PathType Leaf) -and
            (Test-Path -LiteralPath $Target -PathType Leaf) -and
            ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq
                (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash)
        )
    }

    return [pscustomobject]@{
        Name = $Name
        Target = $Target
        Source = $Source
        Exists = $link.Exists
        BrokenLink = $link.BrokenLink
        StaleLink = $link.StaleLink
        LinkTarget = $link.LinkTarget
        MatchesSource = $matchesSource
    }
}

function ConvertFrom-WslText {
    param([object[]]$Lines)
    return @(
        $Lines |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ }
    )
}

function Get-LiveObservation {
    # The whole state is validated before anything on the machine is observed.
    # It is the file that decides what verification demands, so a value it
    # cannot read is an error rather than an answer: a state that does not
    # validate leaves every selection false, and the failure below is about the
    # state, not about the components a corrupt file stopped asking for.
    $stateExists = Test-Path -LiteralPath $StatePath -PathType Leaf
    $stateJson = if ($stateExists) { Get-Content -LiteralPath $StatePath -Raw } else { $null }
    $state = Read-WindowsSelectionState -Json $stateJson `
        -SupportedSchemaVersion ([int]$Manifest.SchemaVersion)

    $nocttySelected = $state.NocttySelected
    $configurationSelected = $state.NocttyConfigurationSelected
    $handySelected = $state.HandySelected
    $wslRequired = $state.WslRequired
    $distribution = $state.FedoraDistribution
    $schemaVersion = $state.SchemaVersion
    $stateError = $state.Error
    $stateValid = $state.Valid

    # Every command below is resolved through the shared resolver, never
    # through PATH alone: a package's shim reaches PATH through the registry,
    # so the session that ran a successful install still cannot see it, and
    # reporting that as a missing package would fail a healthy machine.
    $scoopRoot = Get-ScoopRoot
    $scoopCommandPath = Resolve-ScoopCommand

    # Bucket and package identity come from the shared predicate in
    # lib\scoop.ps1, the one install.ps1 asks before it installs anything. No
    # bucket table is passed here: reading it means running Scoop, and this
    # script neither mutates nor starts processes it would then have to bound.
    # The bucket checkout's own remote is what that table reports anyway.
    $nocttyBucket = Get-ScoopBucketOwnership `
        -Bucket $Manifest.Scoop.NocttyBucket -Root $scoopRoot
    $nocttyPackage = Get-ScoopPackageOwnership `
        -Package $Manifest.Scoop.NocttyPackage `
        -BucketName $Manifest.Scoop.NocttyBucket.Name -Root $scoopRoot
    $extrasBucket = Get-ScoopBucketOwnership `
        -Bucket $Manifest.Scoop.ExtrasBucket -Root $scoopRoot
    $handyPackage = Get-ScoopPackageOwnership `
        -Package $Manifest.Scoop.HandyPackage `
        -BucketName $Manifest.Scoop.ExtrasBucket.Name -Root $scoopRoot

    $configurationFiles = @()
    $configDirectory = Join-Path $env:LOCALAPPDATA 'noctty'
    $rootConfig = Join-Path $configDirectory 'config.ghostty'
    if ($configurationSelected) {
        $configurationFiles += New-ManagedFileObservation `
            -Name 'Noctty root configuration' -Target $rootConfig -Source $null
        foreach ($declaration in $Manifest.NocttyManagedFiles) {
            $configurationFiles += New-ManagedFileObservation `
                -Name $declaration.Name `
                -Source (Join-Path $RepositoryRoot $declaration.Source) `
                -Target (Join-Path $configDirectory $declaration.Target)
        }
        $configurationFiles += New-ManagedFileObservation `
            -Name 'Noctty selected theme' `
            -Target (Join-Path $configDirectory 'dotfiles\theme.conf') `
            -Source $null

        $sourceThemeDirectory = Join-Path $RepositoryRoot 'ghostty\.config\ghostty\themes'
        foreach ($theme in @(Get-ChildItem -LiteralPath $sourceThemeDirectory -Filter '*.conf' -File)) {
            $configurationFiles += New-ManagedFileObservation `
                -Name "Noctty theme $($theme.Name)" `
                -Source $theme.FullName `
                -Target (Join-Path $configDirectory "themes\$($theme.Name)")
        }
    }

    $managedBlockValid = $false
    if ($configurationSelected -and (Test-Path -LiteralPath $rootConfig -PathType Leaf)) {
        $content = Get-Content -LiteralPath $rootConfig -Raw
        $baseBlockValid = (
            $content -match '(?m)^# BEGIN dotfiles Fedora WSL\r?$' -and
            $content -match '(?m)^# END dotfiles Fedora WSL\r?$' -and
            $content -match '(?m)^config-file = "dotfiles/ghostty\.conf"\r?$' -and
            $content -match '(?m)^config-file = "dotfiles/theme\.conf"\r?$'
        )
        $expectedCommand = [regex]::Escape(
            "command = direct:wsl.exe --distribution $distribution"
        )
        $commandValid = (
            $content -match "(?m)^${expectedCommand}\r?$" -or
            $content -match '(?m)^# Fedora WSL command omitted: a user-managed command exists below\.\r?$'
        )
        $managedBlockValid = $baseBlockValid -and $commandValid
    }

    $wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $installedVersion = $null
    $distributionPresent = $false
    $distributionVersion = $null
    if ($wslCommand) {
        $versionOutput = & $wslCommand.Source --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $installedVersion = ConvertFrom-WslVersionOutput -Lines $versionOutput
        }
        $listOutput = & $wslCommand.Source --list --verbose 2>&1
        if ($LASTEXITCODE -eq 0 -and $distribution) {
            $escapedName = [regex]::Escape($distribution)
            foreach ($line in (ConvertFrom-WslText -Lines $listOutput)) {
                if ($line -match "^\*?\s*${escapedName}\s+.+\s+([12])\s*$") {
                    $distributionPresent = $true
                    $distributionVersion = [int]$Matches[1]
                    break
                }
            }
        }
    }

    return [pscustomobject]@{
        State = [pscustomobject]@{
            Exists = $stateExists
            Valid = $stateValid
            Error = $stateError
            SchemaVersion = $schemaVersion
            NocttySelected = $nocttySelected
            NocttyConfigurationSelected = $configurationSelected
            HandySelected = $handySelected
            WslRequired = $wslRequired
            FedoraDistribution = $distribution
        }
        Scoop = [pscustomobject]@{
            Available = ($null -ne $scoopCommandPath -and (Test-Path -LiteralPath $scoopRoot -PathType Container))
            Root = $scoopRoot
            CommandPath = $scoopCommandPath
            Bucket = $nocttyBucket
            Package = $nocttyPackage
            ExtrasBucket = $extrasBucket
            HandyPackage = $handyPackage
        }
        Configuration = [pscustomobject]@{
            ManagedBlockValid = $managedBlockValid
            Files = @($configurationFiles)
        }
        Wsl = [pscustomobject]@{
            CommandAvailable = ($null -ne $wslCommand)
            InstalledVersion = if ($installedVersion) { $installedVersion.ToString() } else { $null }
            DistributionPresent = $distributionPresent
            DistributionVersion = $distributionVersion
        }
    }
}

function Confirm-ScoopPackageOwnership {
    param(
        [string]$DisplayName,
        [object]$Scoop,
        [object]$Bucket,
        [object]$Package
    )

    # The bucket, by where its checkout points rather than by its name. A
    # `noctty` or `extras` cloned from somewhere else is the substitution this
    # whole check exists for, and it reads as present to anything that only
    # looks for the directory.
    if (-not $Bucket.Exists) {
        Write-VerificationFailure "Declared Scoop bucket is missing: $($Bucket.Name)"
    }
    elseif (-not $Bucket.OriginMatches) {
        $found = if ($Bucket.OriginUrl) { $Bucket.OriginUrl } else { 'no Git remote' }
        Write-VerificationFailure (
            "Scoop bucket $($Bucket.Name) is not $($Bucket.DeclaredUrl): it points at $found"
        )
    }
    else {
        Write-VerificationPass "Declared Scoop bucket is $($Bucket.DeclaredUrl): $($Bucket.Name)"
    }

    # The package, by Scoop's own record of installing it out of that bucket.
    # Scoop writes install.json last, so the directory and even the executable
    # can be there after an install that never finished, and install.json's
    # bucket field is the only record of which bucket supplied the manifest.
    if (-not $Package.Exists) {
        Write-VerificationFailure "Declared Scoop package is missing: $($Package.Name)"
    }
    elseif ($Package.MetadataError) {
        Write-VerificationFailure (
            "Scoop install metadata for $($Package.Name) is unreadable: $($Package.MetadataError)"
        )
    }
    elseif (-not $Package.HasManifest) {
        Write-VerificationFailure (
            "$($Package.Name) has no Scoop manifest, so no install finished there: $($Package.CurrentPath)"
        )
    }
    elseif (-not $Package.HasExecutable) {
        Write-VerificationFailure "$DisplayName executable is missing: $($Package.ExecutablePath)"
    }
    elseif (-not $Package.BucketMatches) {
        $from = if ($Package.InstalledBucket) { "the '$($Package.InstalledBucket)' bucket" }
        else { 'no recorded bucket' }
        Write-VerificationFailure (
            "$($Package.Name) was installed from $from, not '$($Package.DeclaredBucket)'"
        )
    }
    else {
        Write-VerificationPass "Declared Scoop package is installed: $($Package.QualifiedName)"
    }

    $appsRoot = Join-ObservedPath $Scoop.Root 'apps'
    if (Test-PathWithinRoot -Path $Package.ExecutablePath -Root $appsRoot) {
        Write-VerificationPass "$DisplayName current executable is Scoop-owned: $($Package.ExecutablePath)"
    }
    else {
        Write-VerificationFailure "$DisplayName current executable is outside Scoop ownership: $($Package.ExecutablePath)"
    }

    # Whether the shim has reached this session is a usability observation, not
    # an ownership one, so it warns rather than fails: the session that ran the
    # install cannot see the registry PATH it just extended, and a same-named
    # program earlier on PATH shadows a correctly installed package without
    # making it any less installed. The checks above already decided ownership.
    $shimRoot = Join-ObservedPath $Scoop.Root 'shims'
    if (Test-PathWithinRoot -Path $Package.CommandPath -Root $shimRoot) {
        Write-VerificationPass "$DisplayName resolves through Scoop shims: $($Package.CommandPath)"
    }
    elseif (-not $Package.CommandPath) {
        Write-VerificationWarning (
            "$DisplayName resolves to no command yet; open a new session so the " +
            'Scoop shims directory reaches PATH'
        )
    }
    else {
        Write-VerificationWarning (
            "$DisplayName resolves outside Scoop shims: $($Package.CommandPath) " +
            'shadows the Scoop-installed executable on this PATH'
        )
    }
}

function Read-Observation {
    if ($FixturePath) {
        return Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
    }
    return Get-LiveObservation
}

try {
    $observation = Read-Observation
}
catch {
    Write-VerificationFailure "Could not inspect Windows installed state: $($_.Exception.Message)"
    $observation = $null
}

if ($null -ne $observation) {
    Write-Host 'Windows selection state'
    if (-not $observation.State.Exists) {
        Write-VerificationFailure "Windows selection state is missing: $StatePath"
    }
    elseif (-not $observation.State.Valid) {
        Write-VerificationFailure "Windows selection state is invalid: $($observation.State.Error)"
    }
    else {
        Write-VerificationPass (
            "Windows selection state schema $($observation.State.SchemaVersion) " +
            'is complete and typed'
        )
    }
}

# Everything below is a question the state decides the answer to: which
# applications must be installed, whether the managed configuration must be
# there, whether WSL is required at all. A state that did not validate cannot
# decide any of them, so the sections are not run rather than run against
# defaults -- "no Scoop-owned application is selected" out of a file nobody
# could read would be the corrupt state suppressing the very checks it was
# supposed to demand.
if ($null -ne $observation -and -not $observation.State.Valid) {
    Write-Host ''
    Write-Host 'Everything below depends on the selection state, which could not be read.'
}
elseif ($null -ne $observation) {
    Write-Host ''
    Write-Host 'Scoop ownership'
    $scoopSelections = @()
    if ($observation.State.NocttySelected) { $scoopSelections += 'Noctty' }
    if ($observation.State.HandySelected) { $scoopSelections += 'Handy' }
    if ($scoopSelections.Count -eq 0) {
        Write-VerificationPass 'No Scoop-owned application is selected; Scoop absence is allowed'
    }
    else {
        if ($observation.Scoop.Available) {
            Write-VerificationPass "Scoop is available under $($observation.Scoop.Root)"
        }
        else {
            Write-VerificationFailure "$($scoopSelections -join ' and ') selected, but Scoop is unavailable"
        }

        $scoopShimRoot = Join-ObservedPath $observation.Scoop.Root 'shims'
        if (Test-PathWithinRoot -Path $observation.Scoop.CommandPath -Root $scoopShimRoot) {
            Write-VerificationPass "Scoop resolves through its owned shims: $($observation.Scoop.CommandPath)"
        }
        else {
            Write-VerificationFailure "Scoop resolves outside its owned shims: $($observation.Scoop.CommandPath)"
        }

        # verifies: terminal
        # Noctty is this host's terminal: declared bucket, declared package, a
        # shim-resolved command and a Scoop-owned current executable.
        if ($observation.State.NocttySelected) {
            Confirm-ScoopPackageOwnership -DisplayName 'Noctty' `
                -Scoop $observation.Scoop `
                -Bucket $observation.Scoop.Bucket `
                -Package $observation.Scoop.Package
        }

        # Handy is verified exactly like Noctty: declared bucket, declared
        # package, a shim-resolved command and a Scoop-owned current
        # executable. Nothing here launches it or reads its recordings.
        if ($observation.State.HandySelected) {
            Confirm-ScoopPackageOwnership -DisplayName 'Handy' `
                -Scoop $observation.Scoop `
                -Bucket $observation.Scoop.ExtrasBucket `
                -Package $observation.Scoop.HandyPackage
        }
    }

    Write-Host ''
    Write-Host 'Repository-managed Windows configuration'
    if (-not $observation.State.NocttyConfigurationSelected) {
        Write-VerificationPass 'Noctty configuration is not selected; managed configuration absence is allowed'
    }
    else {
        $expectedConfigurationNames = @(
            'Noctty root configuration',
            'Noctty selected theme'
        )
        $expectedConfigurationNames += @(
            $Manifest.NocttyManagedFiles | ForEach-Object { $_.Name }
        )
        $sourceThemeDirectory = Join-Path $RepositoryRoot 'ghostty\.config\ghostty\themes'
        $expectedConfigurationNames += @(
            Get-ChildItem -LiteralPath $sourceThemeDirectory -Filter '*.conf' -File |
                ForEach-Object { "Noctty theme $($_.Name)" }
        )
        $observedConfigurationNames = @(
            $observation.Configuration.Files | ForEach-Object { $_.Name }
        )
        foreach ($expectedName in $expectedConfigurationNames) {
            if ($observedConfigurationNames -notcontains $expectedName) {
                Write-VerificationFailure "Managed configuration observation is missing: $expectedName"
            }
        }

        foreach ($file in @($observation.Configuration.Files)) {
            if (-not $file.Exists) {
                Write-VerificationFailure "$($file.Name) is missing: $($file.Target)"
            }
            elseif ($file.BrokenLink) {
                Write-VerificationFailure "$($file.Name) is a broken link: $($file.Target)"
            }
            elseif ($file.StaleLink) {
                Write-VerificationFailure "$($file.Name) points at another checkout: $($file.LinkTarget)"
            }
            elseif (-not $file.MatchesSource) {
                Write-VerificationFailure "$($file.Name) differs from the current checkout: $($file.Target)"
            }
            else {
                Write-VerificationPass "$($file.Name): $($file.Target)"
            }
        }

        if ($observation.Configuration.ManagedBlockValid) {
            Write-VerificationPass 'Noctty root configuration contains the expected managed block'
        }
        else {
            Write-VerificationFailure 'Noctty root configuration managed block is missing or stale'
        }
    }

    Write-Host ''
    Write-Host 'Windows-owned WSL boundary'
    if (-not $observation.State.WslRequired) {
        Write-VerificationWarning 'WSL is not recorded as required; no Windows WSL invariant was selected'
    }
    elseif (-not $observation.Wsl.CommandAvailable) {
        Write-VerificationFailure 'wsl.exe is missing'
    }
    else {
        $installedVersion = $null
        if ($observation.Wsl.InstalledVersion) {
            # An unreadable version is not a version: leaving it null is what makes
            # Get-WslSupportStatus answer 'not proven' rather than throwing here.
            try { $installedVersion = [version]$observation.Wsl.InstalledVersion }
            catch { $installedVersion = $null }
        }
        $support = Get-WslSupportStatus `
            -InstalledVersion $installedVersion `
            -MinimumProvenVersion ([version]$Manifest.MinimumProvenWslVersion)
        if ($support -eq 'Proven') {
            Write-VerificationPass "WSL $installedVersion satisfies the proven baseline"
        }
        else {
            Write-VerificationFailure "WSL $($observation.Wsl.InstalledVersion) does not satisfy the >= $($Manifest.MinimumProvenWslVersion) baseline"
        }

        if (-not $observation.State.FedoraDistribution) {
            Write-VerificationFailure 'No Fedora WSL distribution is recorded'
        }
        elseif (-not $observation.Wsl.DistributionPresent) {
            Write-VerificationFailure "Recorded Fedora WSL distribution is missing: $($observation.State.FedoraDistribution)"
        }
        elseif ([int]$observation.Wsl.DistributionVersion -ne 2) {
            Write-VerificationFailure "Recorded Fedora distribution is not on WSL 2: $($observation.State.FedoraDistribution)"
        }
        else {
            Write-VerificationPass "Recorded Fedora distribution uses WSL 2: $($observation.State.FedoraDistribution)"
        }
    }
}

Write-Host ''
Write-Host ('Windows verification: {0} pass(es), {1} warning(s), {2} failure(s)' -f $script:Passes, $script:Warnings, $script:Failures)
if ($script:Failures -gt 0) { exit 1 }
exit 0
