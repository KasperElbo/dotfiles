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

.PARAMETER DryRun
Prints the planned changes without installing or writing configuration.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$FedoraDistribution,

    [switch]$SkipNoctty,
    [switch]$SkipNocttyConfiguration,
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

$NocttyBucketUrl = 'https://github.com/amanthanvi/scoop-noctty'
$WslDistributionCatalogUrl = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
$ManagedBlockStart = '# BEGIN dotfiles Fedora WSL'
$ManagedBlockEnd = '# END dotfiles Fedora WSL'
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$GhosttyConfig = Join-Path $RepositoryRoot 'ghostty\.config\ghostty\shared.conf'
$GhosttyThemes = Join-Path $RepositoryRoot 'ghostty\.config\ghostty\themes'
$NocttyThemeHelper = Join-Path $PSScriptRoot 'set-noctty-theme.ps1'

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
        $catalog = Invoke-RestMethod -UseBasicParsing -Uri $WslDistributionCatalogUrl
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

    # wsl --update normally fetches its package through the Microsoft Store.
    # On networks that restrict Store traffic (common on managed corporate
    # machines) that request is denied outright (Wsl/UpdatePackage/0x80190193,
    # an HTTP 403), so download the update directly instead.
    Write-Step 'Updating WSL'
    Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--update', '--web-download')
}

function Invoke-ElevatedPhase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PhaseSwitch,

        [string[]]$ExtraArguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$FailureDescription
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

    try {
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru
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
    Invoke-ElevatedPhase -PhaseSwitch '-ElevatedWslUpdateOnly' -FailureDescription 'The elevated WSL update'
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
        -FailureDescription 'The elevated WSL installation phase'
}

function Install-WslDistribution {
    param([string]$Distribution)

    if (-not (Test-Administrator)) {
        throw 'The internal WSL installation phase requires administrator privileges.'
    }

    Update-Wsl

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
        Invoke-WebRequest -UseBasicParsing -Uri 'https://get.scoop.sh' -OutFile $installerPath
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

function Install-Noctty {
    $nocttyCurrent = Join-Path $env:USERPROFILE 'scoop\apps\noctty\current\noctty.exe'
    if ((Get-Command noctty -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath $nocttyCurrent)) {
        Write-Step 'Noctty is already installed'
        return
    }

    $scoop = Resolve-ScoopCommand
    if (-not $scoop) {
        $scoop = Install-Scoop
    }

    if ($DryRun -and -not $scoop) {
        Write-Step "Would add the Noctty Scoop bucket: $NocttyBucketUrl"
        Write-Step 'Would install noctty/noctty for the current Windows user'
        return
    }

    $bucketList = & $scoop bucket list 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Scoop buckets: $($bucketList -join ' ')"
    }

    if (-not ($bucketList -match '(?m)^noctty\s')) {
        if ($DryRun) {
            Write-Step "Would add the Noctty Scoop bucket: $NocttyBucketUrl"
        }
        else {
            Write-Step 'Adding the official Noctty Scoop bucket'
            Invoke-NativeCommand -FilePath $scoop -Arguments @(
                'bucket', 'add', 'noctty', $NocttyBucketUrl
            )
        }
    }

    if ($DryRun) {
        Write-Step 'Would install noctty/noctty for the current Windows user'
    }
    else {
        Write-Step 'Installing Noctty'
        Invoke-NativeCommand -FilePath $scoop -Arguments @('install', 'noctty/noctty')
    }
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
    throw 'Run this script from a normal, non-administrator PowerShell session. It elevates only the WSL installation phase; Scoop and Noctty stay per-user.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe was not found. Install current Windows updates and enable Windows Subsystem for Linux, then rerun this script.'
}

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

Write-Host ''
Write-Host 'Windows-side installation is complete.'
Write-Host "Launch Fedora and complete its first-run user setup: wsl.exe --distribution $selectedFedora"
Write-Host 'Then clone this repository inside Fedora (for example under ~/src) and run:'
Write-Host '  ./install.sh --platform fedora-wsl'
