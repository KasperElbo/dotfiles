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
Installs Noctty without changing its default command.

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
    [switch]$ElevatedWslPhase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NocttyBucketUrl = 'https://github.com/amanthanvi/scoop-noctty'
$ManagedBlockStart = '# BEGIN dotfiles Fedora WSL'
$ManagedBlockEnd = '# END dotfiles Fedora WSL'

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

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
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

function Resolve-FedoraDistribution {
    param([string]$RequestedDistribution)

    $installed = @(Get-WslList)
    $online = @(Get-WslList -Online)

    if ($RequestedDistribution) {
        if (($installed -notcontains $RequestedDistribution) -and
            ($online -notcontains $RequestedDistribution)) {
            throw "Fedora distribution '$RequestedDistribution' is neither installed nor advertised by 'wsl --list --online'."
        }
        return $RequestedDistribution
    }

    $candidates = @($online | Where-Object { $_ -match '^FedoraLinux(?:-\d+)?$' })
    if ($candidates.Count -eq 0) {
        throw "No official FedoraLinux distribution was returned by 'wsl --list --online'. Update WSL or pass -FedoraDistribution explicitly."
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

    $powerShellPath = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-ElevatedWslPhase',
        '-FedoraDistribution', $Distribution
    )

    Write-Step "Requesting administrator approval for WSL 2 and $Distribution"
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The elevated WSL installation phase failed with exit code $($process.ExitCode)."
    }
}

function Install-WslDistribution {
    param([string]$Distribution)

    if (-not (Test-Administrator)) {
        throw 'The internal WSL installation phase requires administrator privileges.'
    }

    Write-Step 'Updating WSL'
    Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--update')

    Write-Step 'Making WSL 2 the default for new distributions'
    Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--set-default-version', '2')

    $installed = @(Get-WslList)
    if ($installed -notcontains $Distribution) {
        Write-Step "Installing $Distribution without launching its first-run prompt"
        Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @(
            '--install', '--distribution', $Distribution, '--no-launch'
        )
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

function Set-NocttyWslCommand {
    param([string]$Distribution)

    $configDirectory = Join-Path $env:LOCALAPPDATA 'noctty'
    $configPath = Join-Path $configDirectory 'config.ghostty'
    $newBlock = @"
$ManagedBlockStart
command = direct:wsl.exe --distribution $Distribution
$ManagedBlockEnd
"@

    $content = ''
    if (Test-Path -LiteralPath $configPath) {
        $content = [IO.File]::ReadAllText($configPath)
    }

    $managedPattern = '(?ms)^# BEGIN dotfiles Fedora WSL\r?\n.*?^# END dotfiles Fedora WSL\r?\n?'
    if ([regex]::IsMatch($content, $managedPattern)) {
        $managedRegex = [regex]::new($managedPattern)
        $updated = $managedRegex.Replace($content, "$newBlock`r`n", 1)
    }
    elseif ($content -match '(?m)^\s*command\s*=') {
        Write-Warning "Noctty already has a user-managed command in $configPath; leaving it unchanged. Select $Distribution from Noctty's WSL profiles or update it manually."
        return
    }
    else {
        $separator = if ($content -and -not $content.EndsWith("`n")) { "`r`n" } else { '' }
        $updated = "$content$separator$newBlock`r`n"
    }

    if ($DryRun) {
        Write-Step "Would configure Noctty to open $Distribution by default in $configPath"
        return
    }

    [IO.Directory]::CreateDirectory($configDirectory) | Out-Null
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($configPath, $updated, $utf8WithoutBom)
    Write-Step "Configured Noctty to open $Distribution by default"
}

if ($ElevatedWslPhase) {
    if (-not $FedoraDistribution) {
        throw 'The internal WSL installation phase requires -FedoraDistribution.'
    }
    Install-WslDistribution -Distribution $FedoraDistribution
    exit 0
}

if (Test-Administrator) {
    throw 'Run this script from a normal, non-administrator PowerShell session. It elevates only the WSL installation phase; Scoop and Noctty stay per-user.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe was not found. Install current Windows updates and enable Windows Subsystem for Linux, then rerun this script.'
}

$selectedFedora = Resolve-FedoraDistribution -RequestedDistribution $FedoraDistribution
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
        Set-NocttyWslCommand -Distribution $selectedFedora
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
