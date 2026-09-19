<#
.SYNOPSIS
Installs the Windows host pieces for the Fedora WSL workstation variant.

.DESCRIPTION
Discovers and installs the newest official Fedora WSL distribution on WSL 2,
then installs Noctty for the current user through Scoop. Run this script from a
normal PowerShell session; it requests elevation only for WSL changes.

.PARAMETER FedoraDistribution
Uses an exact distribution name returned by `wsl --list --online` instead of
automatically selecting the newest FedoraLinux entry.

.PARAMETER SkipNoctty
Installs or validates Fedora WSL without installing or configuring Noctty.

.PARAMETER SkipNocttyConfiguration
Installs Noctty without synchronizing Ghostty settings or changing its command.

.PARAMETER Handy
Additionally installs the Handy offline voice-dictation application from the
official Scoop extras bucket. Opt-in: dictation is desktop tooling and is never
a prerequisite for the WSL or terminal bootstrap.

.PARAMETER DryRun
Prints the planned changes without installing or writing configuration.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$FedoraDistribution,

    [switch]$SkipNoctty,
    [switch]$SkipNocttyConfiguration,
    [switch]$Handy,
    [switch]$DryRun,

    [Parameter(DontShow = $true)]
    [switch]$ElevatedWslPhase,

    [Parameter(DontShow = $true)]
    [switch]$ElevatedWslUpdateOnly,

    [Parameter(DontShow = $true)]
    [string]$ElevatedLogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WindowsManifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'manifest.psd1')
$MinimumProvenWslVersion = [version]$WindowsManifest.MinimumProvenWslVersion
$NocttyBucketUrl = $WindowsManifest.Scoop.NocttyBucket.Url
$ExtrasBucketUrl = $WindowsManifest.Scoop.ExtrasBucket.Url
$WslDistributionCatalogUrl = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
$ManagedBlockStart = '# BEGIN dotfiles Fedora WSL'
$ManagedBlockEnd = '# END dotfiles Fedora WSL'
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$GhosttyConfig = Join-Path $RepositoryRoot 'ghostty\.config\ghostty\shared.conf'
$GhosttyThemes = Join-Path $RepositoryRoot 'ghostty\.config\ghostty\themes'
$NocttyThemeHelper = Join-Path $PSScriptRoot 'set-noctty-theme.ps1'
$SelectionStatePath = Join-Path $env:LOCALAPPDATA $WindowsManifest.SelectionStateRelativePath
. (Join-Path $PSScriptRoot 'lib\wsl-version.ps1')

function Write-Step {
    param([string]$Message)

    Write-Host "==> $Message"
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @()
    )

    # Native stdout is success-stream output in PowerShell. Send it to the host
    # so callers that capture this function's return value do not also capture
    # installer progress messages as command paths.
    & $FilePath @Arguments | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')"
    }
}

function ConvertFrom-WslOutput {
    param([object[]]$Lines)

    return @(
        $Lines |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ }
    )
}

function Get-WslPackageVersion {
    $output = & wsl.exe --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ConvertFrom-WslVersionOutput -Lines $output
}

function Write-WslSupportStatus {
    $installedVersion = Get-WslPackageVersion
    $status = Get-WslSupportStatus `
        -InstalledVersion $installedVersion `
        -MinimumProvenVersion $MinimumProvenWslVersion

    if ($status -eq 'Proven') {
        Write-Step "WSL $installedVersion detected (proven-supported baseline)"
        return
    }

    if ($status -eq 'Older') {
        Write-Warning @"
WSL $installedVersion detected.
This repository is currently validated on WSL $MinimumProvenWslVersion and newer.
Older versions may work but are unvalidated.

Update WSL from PowerShell:
  wsl --update
"@
        return
    }

    Write-Warning @"
Unable to determine the installed WSL version.
Fedora WSL is currently validated on WSL $MinimumProvenWslVersion and newer.
Check manually with:
  wsl --version
"@
}

function Get-WslList {
    param([switch]$Online)

    $arguments = @('--list', '--quiet')
    if ($Online) {
        $arguments = @('--list', '--online', '--quiet')
    }

    $output = & wsl.exe @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query WSL distributions: $($output -join ' ')"
    }

    return ConvertFrom-WslOutput -Lines $output
}

function Get-WebFedoraDistributions {
    try {
        # network-source: wsl-distribution-catalog
        $catalog = Invoke-RestMethod -UseBasicParsing -Uri $WslDistributionCatalogUrl -TimeoutSec 60
        return @(
            $catalog.ModernDistributions.Fedora |
                ForEach-Object { $_.Name } |
                Where-Object { $_ -match '^FedoraLinux(?:-\d+)?$' }
        )
    }
    catch {
        Write-Warning "Unable to read Microsoft's current WSL distribution catalogue: $($_.Exception.Message)"
        return @()
    }
}

function Resolve-FedoraDistribution {
    param(
        [string]$RequestedDistribution,
        [switch]$AllowUnavailable
    )

    $installed = @(Get-WslList)
    $online = @(Get-WslList -Online)
    $web = @()

    if ($RequestedDistribution) {
        if (($installed -notcontains $RequestedDistribution) -and
            ($online -notcontains $RequestedDistribution)) {
            $web = @(Get-WebFedoraDistributions)
            if ($web -notcontains $RequestedDistribution) {
                if ($AllowUnavailable) {
                    return $null
                }
                throw "Fedora distribution '$RequestedDistribution' is neither installed nor present in Microsoft's WSL catalogues."
            }
        }
        return $RequestedDistribution
    }

    $candidates = @($online | Where-Object { $_ -match '^FedoraLinux(?:-\d+)?$' })
    if ($candidates.Count -eq 0) {
        $candidates = @(Get-WebFedoraDistributions)
    }
    if ($candidates.Count -eq 0) {
        if ($AllowUnavailable) { return $null }
        throw "No official FedoraLinux distribution was found in Microsoft's WSL catalogues."
    }

    return $candidates |
        Sort-Object -Property @(
            @{ Expression = {
                $match = [regex]::Match($_, '(\d+)$')
                if ($match.Success) { [int]$match.Groups[1].Value } else { 0 }
            }; Descending = $true },
            @{ Expression = { $_ }; Descending = $true }
        ) |
        Select-Object -First 1
}

function Update-Wsl {
    if (-not (Test-Administrator)) {
        throw 'Updating WSL requires administrator privileges.'
    }

    # --web-download is a no-op for `wsl --update` in current wsl.exe builds
    # (kept only for compatibility with older inbox WSL versions where it did
    # matter); it is harmless to pass and costs nothing to keep. Current
    # wsl.exe always checks api.github.com/repos/Microsoft/WSL/releases for
    # the latest version regardless of this flag, and there is no flag that
    # avoids that dependency -- callers that need this to tolerate a blocked
    # or rate-limited network (Wsl/UpdatePackage/0x80190193, an HTTP 403) must
    # catch failures from this function themselves.
    Write-Step 'Updating WSL'
    Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--update', '--web-download')
}

function Invoke-ElevatedPhase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PhaseSwitch,

        [string[]]$ExtraArguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$FailureDescription,

        # What this phase's caller would have the user run by hand instead.
        # Each phase has its own: the update path cannot be replaced by a
        # distribution install, so the hint has to come from the call site
        # rather than being guessed here.
        [Parameter(Mandatory = $true)]
        [string]$ManualEquivalent
    )

    # Start-Process -Verb RunAs launches the elevated phase in its own console
    # window; that window's output is never captured by this process, so a
    # failure inside it is otherwise reported only as an opaque exit code.
    # Have the elevated phase transcript its own output to a log file this
    # process reads back and prints, so the real error is actually visible.
    $logPath = Join-Path ([IO.Path]::GetTempPath()) (
        'dotfiles-wsl-elevated-{0}.log' -f [guid]::NewGuid().ToString('N')
    )

    $powerShellPath = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        $PhaseSwitch,
        '-ElevatedLogPath', ('"{0}"' -f $logPath)
    ) + $ExtraArguments

    # Start-Process -Verb RunAs is known to intermittently fail to launch or
    # track the elevated process with a generic "the system cannot find all
    # the information required" error -- a transient Windows UAC/ShellExecute
    # quirk, not a problem with the elevated phase itself. Retrying is safe
    # because the elevated phase is idempotent (it checks what is already
    # installed before doing anything).
    $maxAttempts = 3
    $process = $null
    try {
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru
                break
            }
            catch {
                # Declining the prompt is a decision, not the quirk above:
                # ShellExecute reports ERROR_CANCELLED (1223) as a
                # Win32Exception. Retrying tells the user their own choice
                # failed, twice, before giving up. Say what happened instead.
                #
                # Start-Process does not hand that Win32Exception back: it
                # re-throws an InvalidOperationException that only quotes the
                # original message. Look for the error code anywhere in the
                # exception chain first, since that is exact wherever it
                # survives, and fall back to the message only when it does not.
                $declined = $false
                for ($inner = $_.Exception; $inner; $inner = $inner.InnerException) {
                    if ($inner -is [System.ComponentModel.Win32Exception] -and
                        $inner.NativeErrorCode -eq 1223) {
                        $declined = $true
                        break
                    }
                }
                if (-not $declined) {
                    # Message matching is locale-sensitive, so ask Windows for
                    # its own text for 1223 rather than hard-coding the English
                    # one: the quoted message came from the same source.
                    $cancelled = [System.ComponentModel.Win32Exception]::new(1223).Message
                    $declined = -not [string]::IsNullOrWhiteSpace($cancelled) -and
                        ([string]$_.Exception.Message).Contains($cancelled)
                }
                if ($declined) {
                    throw "Administrator approval was declined. $FailureDescription was not started. Re-run this script and approve the prompt, or make the change manually with: $ManualEquivalent"
                }
                if ($attempt -ge $maxAttempts) {
                    throw
                }
                Write-Warning "Requesting administrator approval failed (attempt $attempt of ${maxAttempts}): $($_.Exception.Message). Retrying..."
                Start-Sleep -Seconds 2
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $logPath) {
            $logContent = Get-Content -LiteralPath $logPath -Raw
            if ($logContent) {
                Write-Host ''
                Write-Host "--- Elevated console output ($FailureDescription) ---"
                Write-Host $logContent.TrimEnd()
                Write-Host '--- End of elevated console output ---'
                Write-Host ''
            }
            Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($process.ExitCode -ne 0) {
        throw "$FailureDescription failed with exit code $($process.ExitCode). See the elevated console output above for the actual error."
    }
}

function Invoke-ElevatedWslUpdate {
    if ($DryRun) {
        Write-Step 'Would request administrator approval to update WSL'
        return
    }

    Write-Step 'The current WSL catalogue does not advertise Fedora; requesting administrator approval to update WSL'
    Invoke-ElevatedPhase `
        -PhaseSwitch '-ElevatedWslUpdateOnly' `
        -FailureDescription 'The elevated WSL update' `
        -ManualEquivalent 'wsl --update --web-download'
}

function Get-WslDistributionVersion {
    param([string]$Distribution)

    $output = & wsl.exe --list --verbose 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $escapedName = [regex]::Escape($Distribution)
    foreach ($line in (ConvertFrom-WslOutput -Lines $output)) {
        if ($line -match "^\*?\s*${escapedName}\s+.+\s+([12])\s*$") {
            return [int]$Matches[1]
        }
    }

    return $null
}

function Invoke-ElevatedWslInstall {
    param([string]$Distribution)

    if ($DryRun) {
        Write-Step "Would request administrator approval for WSL 2 and $Distribution"
        return
    }

    Write-Step "Requesting administrator approval for WSL 2 and $Distribution"
    Invoke-ElevatedPhase `
        -PhaseSwitch '-ElevatedWslPhase' `
        -ExtraArguments @('-FedoraDistribution', $Distribution) `
        -FailureDescription 'The elevated WSL installation phase' `
        -ManualEquivalent "wsl --install $Distribution"
}

function Install-WslDistribution {
    param([string]$Distribution)

    if (-not (Test-Administrator)) {
        throw 'The internal WSL installation phase requires administrator privileges.'
    }

    # wsl --update always checks api.github.com/repos/Microsoft/WSL/releases
    # for the current version before doing anything else -- --web-download is
    # a no-op for this command in current wsl.exe builds, so there is no flag
    # that avoids this dependency. That check commonly fails on restricted
    # corporate networks (rate limiting on a shared egress IP, or a proxy
    # blocking api.github.com outright) even though the already-installed WSL
    # platform is perfectly capable of installing this distribution. Treat a
    # failure here as non-fatal rather than blocking an otherwise-working
    # install on an optional freshness check.
    try {
        Update-Wsl
    }
    catch {
        Write-Warning "Could not update WSL; continuing with the currently installed WSL platform: $($_.Exception.Message)"
    }

    Write-Step 'Making WSL 2 the default for new distributions'
    Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--set-default-version', '2')

    $installed = @(Get-WslList)
    if ($installed -notcontains $Distribution) {
        Write-Step "Installing $Distribution without launching its first-run prompt"
        $arguments = @(
            '--install', '--distribution', $Distribution, '--no-launch'
        )
        $online = @(Get-WslList -Online)
        if ($online -notcontains $Distribution) {
            Write-Step "$Distribution is absent from the Store catalogue; using WSL web download"
            $arguments += '--web-download'
        }
        Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments $arguments
        return
    }

    $version = Get-WslDistributionVersion -Distribution $Distribution
    if ($version -eq 1) {
        Write-Step "Converting $Distribution to WSL 2"
        Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @(
            '--set-version', $Distribution, '2'
        )
    }
    elseif ($version -eq 2) {
        Write-Step "$Distribution is already installed on WSL 2"
    }
    else {
        throw "Unable to determine the WSL version for installed distribution $Distribution."
    }
}

function Resolve-ScoopCommand {
    $command = Get-Command scoop -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($candidate in @(
        (Join-Path $env:USERPROFILE 'scoop\shims\scoop.ps1'),
        (Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd')
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Install-Scoop {
    if ($DryRun) {
        Write-Step 'Would install Scoop for the current Windows user'
        return $null
    }

    $installerPath = Join-Path ([IO.Path]::GetTempPath()) (
        'dotfiles-scoop-install-{0}.ps1' -f [guid]::NewGuid().ToString('N')
    )

    try {
        Write-Step 'Downloading the official Scoop installer'
        # network-source: scoop-installer
        Invoke-WebRequest -UseBasicParsing -Uri 'https://get.scoop.sh' -OutFile $installerPath -TimeoutSec 120
        Invoke-NativeCommand -FilePath 'powershell.exe' -Arguments @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath
        )
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
        }
    }

    $scoop = Resolve-ScoopCommand
    if (-not $scoop) {
        throw 'Scoop installed, but its command could not be found.'
    }
    return $scoop
}

function Get-ScoopBucketList {
    param([Parameter(Mandatory = $true)][string]$Scoop)

    # Listing buckets reads Scoop's own per-user state; it is safe in a dry
    # run, and it is what keeps `bucket add` idempotent.
    $bucketList = & $Scoop bucket list 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Scoop buckets: $($bucketList -join ' ')"
    }
    return $bucketList
}

function Add-ScoopBucket {
    param(
        [Parameter(Mandatory = $true)][string]$Scoop,
        [AllowEmptyCollection()][object[]]$BucketList = @(),
        [Parameter(Mandatory = $true)][hashtable]$Bucket,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($BucketList -match "(?m)^$([regex]::Escape($Bucket.Name))\s") {
        return
    }

    if ($DryRun) {
        Write-Step "Would add the $Label Scoop bucket: $($Bucket.Url)"
        return
    }

    Write-Step "Adding the official $Label Scoop bucket"
    Invoke-NativeCommand -FilePath $Scoop -Arguments @(
        'bucket', 'add', $Bucket.Name, $Bucket.Url
    )
}

function Install-ScoopPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Scoop,
        [Parameter(Mandatory = $true)][hashtable]$Package,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($DryRun) {
        Write-Step "Would install $($Package.QualifiedName) for the current Windows user"
        return
    }

    Write-Step "Installing $Label"
    Invoke-NativeCommand -FilePath $Scoop -Arguments @(
        'install', $Package.QualifiedName
    )
}

function Test-ScoopPackageInstalled {
    param([Parameter(Mandatory = $true)][hashtable]$Package)

    $current = Join-Path $env:USERPROFILE (
        'scoop\apps\{0}\current\{1}' -f $Package.Name, $Package.Executable
    )
    return (
        ($null -ne (Get-Command $Package.Name -ErrorAction SilentlyContinue)) -or
        (Test-Path -LiteralPath $current)
    )
}

function Install-Noctty {
    $nocttyPackage = $WindowsManifest.Scoop.NocttyPackage
    $nocttyBucket = $WindowsManifest.Scoop.NocttyBucket
    if (Test-ScoopPackageInstalled -Package $nocttyPackage) {
        Write-Step 'Noctty is already installed'
        return
    }

    $scoop = Resolve-ScoopCommand
    if (-not $scoop) {
        $scoop = Install-Scoop
    }

    if ($DryRun -and -not $scoop) {
        Write-Step "Would add the Noctty Scoop bucket: $NocttyBucketUrl"
        Write-Step "Would install $($nocttyPackage.QualifiedName) for the current Windows user"
        return
    }

    $bucketList = @(Get-ScoopBucketList -Scoop $scoop)
    Add-ScoopBucket -Scoop $scoop -BucketList $bucketList -Bucket $nocttyBucket -Label 'Noctty'
    Install-ScoopPackage -Scoop $scoop -Package $nocttyPackage -Label 'Noctty'
}

function Install-Handy {
    # Handy is the offline voice-dictation application. Its manifest lives in
    # Scoop's official `extras` bucket and is sha256-pinned there, so this
    # installs per-user through exactly the same Scoop path as Noctty and adds
    # no second package manager. See docs/profiles/dictation.md.
    $handyPackage = $WindowsManifest.Scoop.HandyPackage
    $extrasBucket = $WindowsManifest.Scoop.ExtrasBucket
    if (Test-ScoopPackageInstalled -Package $handyPackage) {
        Write-Step 'Handy is already installed'
        return
    }

    $scoop = Resolve-ScoopCommand
    if (-not $scoop) {
        $scoop = Install-Scoop
    }

    if ($DryRun -and -not $scoop) {
        Write-Step "Would add the extras Scoop bucket: $ExtrasBucketUrl"
        Write-Step "Would install $($handyPackage.QualifiedName) for the current Windows user"
        return
    }

    $bucketList = @(Get-ScoopBucketList -Scoop $scoop)
    Add-ScoopBucket -Scoop $scoop -BucketList $bucketList -Bucket $extrasBucket -Label 'extras'
    Install-ScoopPackage -Scoop $scoop -Package $handyPackage -Label 'Handy'
}

function Copy-FileIfChanged {
    param(
        [string]$Source,
        [string]$Destination
    )

    if ((Test-Path -LiteralPath $Destination) -and
        ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash)) {
        return
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Sync-NocttyGhosttyConfig {
    param([string]$ConfigDirectory)

    if (-not (Test-Path -LiteralPath $GhosttyConfig -PathType Leaf)) {
        throw "Tracked shared Ghostty configuration was not found at $GhosttyConfig."
    }
    if (-not (Test-Path -LiteralPath $GhosttyThemes -PathType Container)) {
        throw "Tracked Ghostty themes were not found at $GhosttyThemes."
    }
    if (-not (Test-Path -LiteralPath $NocttyThemeHelper -PathType Leaf)) {
        throw "Noctty theme helper was not found at $NocttyThemeHelper."
    }

    $sourceThemes = @(Get-ChildItem -LiteralPath $GhosttyThemes -Filter '*.conf' -File)
    if ($sourceThemes.Count -eq 0) {
        throw "No tracked Ghostty themes were found at $GhosttyThemes."
    }

    $targetConfigDirectory = Join-Path $ConfigDirectory 'dotfiles'
    $targetConfig = Join-Path $targetConfigDirectory 'ghostty.conf'
    $targetThemeConfig = Join-Path $targetConfigDirectory 'theme.conf'
    $targetThemeHelper = Join-Path $targetConfigDirectory 'set-theme.ps1'
    $targetThemeDirectory = Join-Path $ConfigDirectory 'themes'
    if ($DryRun) {
        Write-Step "Would synchronize the shared Ghostty config to $targetConfig"
        Write-Step "Would install the WSL theme bridge at $targetThemeHelper"
        Write-Step "Would synchronize $($sourceThemes.Count) tracked Ghostty themes to $targetThemeDirectory"
        return
    }

    [IO.Directory]::CreateDirectory($targetConfigDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($targetThemeDirectory) | Out-Null
    Copy-FileIfChanged -Source $GhosttyConfig -Destination $targetConfig
    Copy-FileIfChanged -Source $NocttyThemeHelper -Destination $targetThemeHelper

    if (-not (Test-Path -LiteralPath $targetThemeConfig)) {
        $defaultTheme = Get-Content -LiteralPath $GhosttyConfig |
            Where-Object { $_ -match '^\s*theme\s*=' } |
            Select-Object -First 1
        if (-not $defaultTheme) {
            throw "The shared Ghostty config does not declare a default theme: $GhosttyConfig"
        }

        $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText(
            $targetThemeConfig,
            "$defaultTheme`r`n",
            $utf8WithoutBom
        )
    }

    foreach ($sourceTheme in $sourceThemes) {
        $targetTheme = Join-Path $targetThemeDirectory $sourceTheme.Name
        Copy-FileIfChanged -Source $sourceTheme.FullName -Destination $targetTheme
    }

    Write-Step 'Synchronized the shared Ghostty configuration and themes for Noctty'
}

function Set-NocttyConfiguration {
    param([string]$Distribution)

    $configDirectory = Join-Path $env:LOCALAPPDATA 'noctty'
    $configPath = Join-Path $configDirectory 'config.ghostty'
    $content = ''
    if (Test-Path -LiteralPath $configPath) {
        $content = [IO.File]::ReadAllText($configPath)
    }

    $managedPattern = '(?ms)^# BEGIN dotfiles Fedora WSL\r?\n.*?^# END dotfiles Fedora WSL\r?\n?'
    $managedRegex = [regex]::new($managedPattern)
    $userContent = $managedRegex.Replace($content, '', 1)
    $hasUserCommand = $userContent -match '(?m)^\s*command\s*='

    $commandSetting = "command = direct:wsl.exe --distribution $Distribution"
    if ($hasUserCommand) {
        $commandSetting = '# Fedora WSL command omitted: a user-managed command exists below.'
        Write-Warning "Noctty already has a user-managed command in $configPath; leaving it in control."
    }

    $newBlock = @"
$ManagedBlockStart
# Reuse the tracked Ghostty configuration; keep Windows-only settings here.
config-file = "dotfiles/ghostty.conf"
config-file = "dotfiles/theme.conf"
$commandSetting
$ManagedBlockEnd
"@

    $separator = if ($userContent) { "`r`n" } else { '' }
    $updated = "$newBlock$separator$userContent"

    if ($DryRun) {
        Write-Step "Would include the tracked Ghostty config and configure Noctty for $Distribution in $configPath"
        Sync-NocttyGhosttyConfig -ConfigDirectory $configDirectory
        return
    }

    [IO.Directory]::CreateDirectory($configDirectory) | Out-Null
    Sync-NocttyGhosttyConfig -ConfigDirectory $configDirectory
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($configPath, $updated, $utf8WithoutBom)
    Write-Step "Configured Noctty from the tracked Ghostty config for $Distribution"
}

function Write-WindowsSelectionState {
    param([string]$Distribution)

    $stateDirectory = Split-Path -Parent $SelectionStatePath
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    $state = [ordered]@{
        SchemaVersion = $WindowsManifest.SchemaVersion
        FedoraDistribution = $Distribution
        WslRequired = $true
        NocttySelected = -not $SkipNoctty.IsPresent
        NocttyConfigurationSelected = (
            -not $SkipNoctty.IsPresent -and
            -not $SkipNocttyConfiguration.IsPresent
        )
        HandySelected = $Handy.IsPresent
    }
    $temporaryPath = Join-Path $stateDirectory (
        'windows-selection-{0}.tmp' -f [guid]::NewGuid().ToString('N')
    )
    try {
        $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText(
            $temporaryPath,
            (($state | ConvertTo-Json) + "`r`n"),
            $utf8WithoutBom
        )
        Move-Item -LiteralPath $temporaryPath -Destination $SelectionStatePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Invoke-ElevatedEntryPoint {
    param([scriptblock]$Action)

    $transcribing = $false
    if ($ElevatedLogPath) {
        Start-Transcript -Path $ElevatedLogPath -Append | Out-Null
        $transcribing = $true
    }

    try {
        & $Action
        exit 0
    }
    catch {
        # Write the failure explicitly rather than relying on the transcript
        # to capture PowerShell's default unhandled-error formatting, so the
        # parent process always has a clear message to relay back.
        Write-Host "ERROR: $($_.Exception.Message)"
        if ($_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace
        }
        exit 1
    }
    finally {
        if ($transcribing) {
            Stop-Transcript | Out-Null
        }
    }
}

if ($ElevatedWslPhase -and $ElevatedWslUpdateOnly) {
    throw 'Only one internal elevated WSL phase may be selected.'
}

if ($ElevatedWslUpdateOnly) {
    Invoke-ElevatedEntryPoint -Action { Update-Wsl }
}

if ($ElevatedWslPhase) {
    Invoke-ElevatedEntryPoint -Action {
        if (-not $FedoraDistribution) {
            throw 'The internal WSL installation phase requires -FedoraDistribution.'
        }
        Install-WslDistribution -Distribution $FedoraDistribution
    }
}

if (Test-Administrator) {
    throw 'Run this script from a normal, non-administrator PowerShell session. It elevates only the WSL installation phase; Scoop, Noctty and Handy stay per-user.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe was not found. Install current Windows updates and enable Windows Subsystem for Linux, then rerun this script.'
}

Write-WslSupportStatus

$selectedFedora = Resolve-FedoraDistribution `
    -RequestedDistribution $FedoraDistribution `
    -AllowUnavailable

if (-not $selectedFedora) {
    if ($DryRun) {
        Write-Warning 'The current WSL catalogue does not advertise an official FedoraLinux distribution.'
        Invoke-ElevatedWslUpdate
        Write-Step 'Would rediscover the newest official FedoraLinux distribution after the WSL update'
        Write-Step 'Dry run stopped at this prerequisite; update WSL and rerun the dry run to preview the remaining changes'
        exit 0
    }

    Invoke-ElevatedWslUpdate
    $selectedFedora = Resolve-FedoraDistribution -RequestedDistribution $FedoraDistribution
}

Write-Step "Selected Fedora WSL distribution: $selectedFedora"

$installedDistributions = @(Get-WslList)
$wslVersion = Get-WslDistributionVersion -Distribution $selectedFedora
if (($installedDistributions -notcontains $selectedFedora) -or ($wslVersion -ne 2)) {
    Invoke-ElevatedWslInstall -Distribution $selectedFedora
}
else {
    Write-Step "$selectedFedora is already installed on WSL 2"
}

if (-not $SkipNoctty) {
    Install-Noctty
    if (-not $SkipNocttyConfiguration) {
        Set-NocttyConfiguration -Distribution $selectedFedora
    }
}

if ($Handy) {
    Install-Handy
}

if ($DryRun) {
    Write-Step 'Dry run complete; no changes were made'
    exit 0
}

$fedoraReady = $false
try {
    $installedDistributions = @(Get-WslList)
    $installedVersion = Get-WslDistributionVersion -Distribution $selectedFedora
    $fedoraReady = (($installedDistributions -contains $selectedFedora) -and
        ($installedVersion -eq 2))
}
catch {
    Write-Warning "WSL is not ready yet: $($_.Exception.Message)"
}

if (-not $fedoraReady) {
    Write-Warning "$selectedFedora is pending Windows restart or WSL 2 setup. Restart Windows, rerun this script, and then launch it with: wsl.exe --distribution $selectedFedora"
    exit 2
}

Write-WindowsSelectionState -Distribution $selectedFedora

Write-Host ''
Write-Host 'Windows-side installation is complete.'
Write-Host "Launch Fedora and complete its first-run user setup: wsl.exe --distribution $selectedFedora"
Write-Host 'Then clone this repository inside Fedora (for example under ~/src) and run:'
Write-Host '  ./install.sh --platform fedora-wsl'
