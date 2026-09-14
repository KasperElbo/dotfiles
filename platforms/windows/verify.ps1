<#
.SYNOPSIS
Verifies the repository-owned Windows and WSL installation state without mutation.

.DESCRIPTION
Checks the recorded Windows selection, Scoop ownership for selected Noctty,
repository-managed Noctty configuration copies, and the Windows-owned WSL
package/distribution baseline. It never installs, updates, authenticates,
creates configuration, or launches a WSL distribution.
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

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if (-not $Path -or -not $Root) { return $false }
    try {
        if ($Path -match '^[A-Za-z]:[\\/]' -and $Root -match '^[A-Za-z]:[\\/]') {
            $fullPath = $Path.Replace('\', '/').TrimEnd('/')
            $fullRoot = $Root.Replace('\', '/').TrimEnd('/')
            $separator = '/'
        }
        else {
            $trimCharacters = [char[]]@('\', '/')
            $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd($trimCharacters)
            $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd($trimCharacters)
            $separator = [IO.Path]::DirectorySeparatorChar
        }
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
    $stateExists = Test-Path -LiteralPath $StatePath -PathType Leaf
    $stateError = $null
    $state = $null
    if ($stateExists) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        }
        catch {
            $stateError = $_.Exception.Message
        }
    }

    $nocttySelected = $false
    $configurationSelected = $false
    $wslRequired = $false
    $distribution = ''
    $schemaVersion = $null
    if ($null -ne $state) {
        $nocttySelected = [bool]$state.NocttySelected
        $configurationSelected = [bool]$state.NocttyConfigurationSelected
        $wslRequired = [bool]$state.WslRequired
        $distribution = [string]$state.FedoraDistribution
        $schemaVersion = $state.SchemaVersion
    }

    $scoopRoot = if ($env:SCOOP) {
        [IO.Path]::GetFullPath($env:SCOOP)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'scoop'))
    }
    $scoopCommand = Get-Command scoop -ErrorAction SilentlyContinue
    $nocttyCommand = Get-Command noctty -ErrorAction SilentlyContinue
    $bucketName = $Manifest.Scoop.NocttyBucket.Name
    $packageName = $Manifest.Scoop.NocttyPackage.Name
    $executableName = $Manifest.Scoop.NocttyPackage.Executable
    $bucketPath = Join-Path $scoopRoot "buckets\$bucketName"
    $packagePath = Join-Path $scoopRoot "apps\$packageName\current"
    $packageExecutable = Join-Path $packagePath $executableName

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
            Error = $stateError
            SchemaVersion = $schemaVersion
            NocttySelected = $nocttySelected
            NocttyConfigurationSelected = $configurationSelected
            WslRequired = $wslRequired
            FedoraDistribution = $distribution
        }
        Scoop = [pscustomobject]@{
            Available = ($null -ne $scoopCommand -and (Test-Path -LiteralPath $scoopRoot -PathType Container))
            Root = $scoopRoot
            CommandPath = if ($scoopCommand) { $scoopCommand.Source } else { $null }
            Bucket = [pscustomobject]@{
                Name = $bucketName
                Exists = Test-Path -LiteralPath $bucketPath -PathType Container
                Path = $bucketPath
            }
            Package = [pscustomobject]@{
                Name = $packageName
                Exists = Test-Path -LiteralPath $packageExecutable -PathType Leaf
                CurrentPath = $packageExecutable
                CommandPath = if ($nocttyCommand) { $nocttyCommand.Source } else { $null }
            }
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
    elseif ($observation.State.Error) {
        Write-VerificationFailure "Windows selection state is invalid: $($observation.State.Error)"
    }
    elseif ([int]$observation.State.SchemaVersion -ne [int]$Manifest.SchemaVersion) {
        Write-VerificationFailure "Unsupported Windows selection schema: $($observation.State.SchemaVersion)"
    }
    else {
        Write-VerificationPass "Windows selection state schema $($observation.State.SchemaVersion)"
    }

    Write-Host ''
    Write-Host 'Scoop ownership'
    if (-not $observation.State.NocttySelected) {
        Write-VerificationPass 'Noctty is not selected; Scoop/Noctty absence is allowed'
    }
    else {
        if ($observation.Scoop.Available) {
            Write-VerificationPass "Scoop is available under $($observation.Scoop.Root)"
        }
        else {
            Write-VerificationFailure 'Noctty is selected, but Scoop is unavailable'
        }

        $scoopShimRoot = Join-ObservedPath $observation.Scoop.Root 'shims'
        if (Test-PathWithinRoot -Path $observation.Scoop.CommandPath -Root $scoopShimRoot) {
            Write-VerificationPass "Scoop resolves through its owned shims: $($observation.Scoop.CommandPath)"
        }
        else {
            Write-VerificationFailure "Scoop resolves outside its owned shims: $($observation.Scoop.CommandPath)"
        }

        if ($observation.Scoop.Bucket.Exists) {
            Write-VerificationPass "Declared Scoop bucket exists: $($observation.Scoop.Bucket.Name)"
        }
        else {
            Write-VerificationFailure "Declared Scoop bucket is missing: $($observation.Scoop.Bucket.Name)"
        }

        if ($observation.Scoop.Package.Exists) {
            Write-VerificationPass "Declared Scoop package exists: $($observation.Scoop.Package.Name)"
        }
        else {
            Write-VerificationFailure "Declared Scoop package is missing: $($observation.Scoop.Package.Name)"
        }

        $shimRoot = Join-ObservedPath $observation.Scoop.Root 'shims'
        if (Test-PathWithinRoot -Path $observation.Scoop.Package.CommandPath -Root $shimRoot) {
            Write-VerificationPass "Noctty resolves through Scoop shims: $($observation.Scoop.Package.CommandPath)"
        }
        else {
            Write-VerificationFailure "Noctty resolves outside Scoop shims: $($observation.Scoop.Package.CommandPath)"
        }

        $appsRoot = Join-ObservedPath $observation.Scoop.Root 'apps'
        if (Test-PathWithinRoot -Path $observation.Scoop.Package.CurrentPath -Root $appsRoot) {
            Write-VerificationPass "Noctty current executable is Scoop-owned: $($observation.Scoop.Package.CurrentPath)"
        }
        else {
            Write-VerificationFailure "Noctty current executable is outside Scoop ownership: $($observation.Scoop.Package.CurrentPath)"
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
            try { $installedVersion = [version]$observation.Wsl.InstalledVersion } catch { }
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
