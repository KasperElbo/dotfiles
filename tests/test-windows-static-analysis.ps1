<#
.SYNOPSIS
Holds every tracked PowerShell file to PSScriptAnalyzer, and proves the gate can fail.

.DESCRIPTION
PowerShell was the one language in this repository with behavioural tests but
no static analysis: 2,400 lines of it against the shell tier's `bash -n` plus
ShellCheck on every push. This suite is that floor.

It analyses the set `git ls-files` reports rather than a list written here, so
a new .ps1 cannot be added outside the gate, and it fails loudly when
PSScriptAnalyzer is absent instead of skipping -- a silent skip would read as a
pass on every future run.

The rule set lives in PSScriptAnalyzerSettings.psd1 at the repository root,
which editors read as well. Two further rules are excluded for the suites
under tests/ only, because redefining a built-in cmdlet as a recorder is how
they execute shipped code; excluding those repository-wide would hide the same
mistake in an installer.

Every claim above is checked rather than asserted: the self-tests at the end
analyse fixtures that must be reported, fixtures the exclusions must silence,
and the same excluded rules with the settings withdrawn, so a settings file
that stopped applying cannot pass as a clean tree.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

# tests/ executes shipped functions by redefining the cmdlets they call, which
# is the only way to run an installer's real body without a Windows host, a
# network or an elevated session. Both rules below describe that technique.
$harnessOnlyExclusions = @(
    # tests/test-windows-bootstrap.ps1 replaces Start-Process, Start-Sleep,
    # Write-Warning and Get-Command with recorders so the shipped call sites
    # bind unchanged.
    'PSAvoidOverwritingBuiltInCmdlets'

    # The same suites set $DryRun and $WindowsManifest for the function bodies
    # they then dot-source, so the assignment's reader is in text the analyser
    # is not looking at.
    'PSUseDeclaredVarsMoreThanAssignments'
)

# The entry points this repository ships on Windows. Anchoring them keeps an
# empty or mistyped file selection from passing as a clean analysis.
$requiredFiles = @(
    'platforms/windows/install.ps1'
    'platforms/windows/verify.ps1'
    'verify.ps1'
)

if (-not (Test-Path -LiteralPath $settingsPath)) {
    throw "The analyser settings are missing: $settingsPath"
}

# Pinned, because an analyser that moves on its own turns an unrelated pull
# request red for a rule nobody in it wrote. The version is named again in
# .github/workflows/validate.yml's install step, and this is the side that
# enforces the agreement: a runner image that already ships a different
# PSScriptAnalyzer must not quietly supply it instead.
$requiredVersion = '1.24.0'

$analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer |
    Where-Object { $_.Version -eq [version]$requiredVersion } |
    Select-Object -First 1
if (-not $analyzer) {
    $available = @(Get-Module -ListAvailable -Name PSScriptAnalyzer |
        ForEach-Object { $_.Version.ToString() })
    $found = if ($available) { "found $($available -join ', ')" } else { 'found none' }
    throw (
        "PSScriptAnalyzer $requiredVersion is not installed, so this gate cannot " +
        "run ($found). Install it with: Install-Module PSScriptAnalyzer " +
        "-RequiredVersion $requiredVersion -Scope CurrentUser -Force"
    )
}
Import-Module $analyzer -ErrorAction Stop

$settings = Import-PowerShellDataFile -LiteralPath $settingsPath
$harnessSettings = @{
    Severity = $settings.Severity
    ExcludeRules = $settings.ExcludeRules + $harnessOnlyExclusions
}

function Get-TrackedPowerShellFile {
    $tracked = & git -C $repoRoot ls-files -- '*.ps1' '*.psd1' '*.psm1'
    if ($LASTEXITCODE -ne 0) {
        throw 'git ls-files failed; the analysed set could not be established.'
    }
    return ,@($tracked | Where-Object { $_ })
}

function Invoke-Analysis {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Settings
    )

    return ,@(Invoke-ScriptAnalyzer -Path $Path -Settings $Settings)
}

function Get-RuleName {
    param([object[]]$Findings)

    return ,@($Findings | ForEach-Object { $_.RuleName } | Sort-Object -Unique)
}

function Assert-Reported {
    param(
        [object[]]$Findings,
        [string]$Rule,
        [string]$Case
    )

    if ((Get-RuleName -Findings $Findings) -notcontains $Rule) {
        throw "$Case did not report ${Rule}: $((Get-RuleName -Findings $Findings) -join ', ')"
    }
}

function Assert-NotReported {
    param(
        [object[]]$Findings,
        [string]$Rule,
        [string]$Case
    )

    if ((Get-RuleName -Findings $Findings) -contains $Rule) {
        throw "$Case reported $Rule, which the settings exclude."
    }
}

$trackedFiles = Get-TrackedPowerShellFile
if ($trackedFiles.Count -eq 0) {
    throw 'No tracked PowerShell file was found; the gate would have analysed nothing.'
}
foreach ($required in $requiredFiles) {
    if ($trackedFiles -notcontains $required) {
        throw "The analysed set no longer contains ${required}; update this suite with the move."
    }
}

$findings = @()
foreach ($relative in $trackedFiles) {
    $full = Join-Path $repoRoot $relative
    $fileSettings = if ($relative -like 'tests/*') { $harnessSettings } else { $settings }
    $findings += Invoke-Analysis -Path $full -Settings $fileSettings
}

if ($findings.Count -gt 0) {
    foreach ($finding in ($findings | Sort-Object ScriptPath, Line)) {
        $where = [IO.Path]::GetRelativePath($repoRoot, $finding.ScriptPath)
        Write-Host ("{0}:{1}: {2}: {3}" -f $where, $finding.Line, $finding.RuleName, $finding.Message)
    }
    throw "PSScriptAnalyzer reported $($findings.Count) finding(s) across $($trackedFiles.Count) tracked file(s)."
}

Write-Host "PSScriptAnalyzer $($analyzer.Version) is clean across $($trackedFiles.Count) tracked PowerShell file(s)."

# ---------------------------------------------------------------------------
# The gate's own failure modes. A lint gate that has never been seen to reject
# anything is a green light of unknown meaning.
# ---------------------------------------------------------------------------

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'dotfiles-psanalysis-{0}' -f [guid]::NewGuid().ToString('N')
)
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

function New-Fixture {
    param([string]$Name, [string]$Body)

    $path = Join-Path $fixtureRoot $Name
    Set-Content -LiteralPath $path -Value $Body -Encoding utf8
    return $path
}

try {
    # An unapproved verb, which is the acceptance case the Windows workstream
    # issue names, and a $null comparison written the wrong way round.
    $rejected = New-Fixture -Name 'rejected.ps1' -Body @'
function Normalize-Thing {
    param($Value)
    if ($Value -eq $null) {
        return ''
    }
    return $Value
}

Normalize-Thing -Value 'x'
'@
    $rejectedFindings = Invoke-Analysis -Path $rejected -Settings $settings
    Assert-Reported -Findings $rejectedFindings -Rule 'PSUseApprovedVerbs' -Case 'An unapproved verb'
    Assert-Reported -Findings $rejectedFindings `
        -Rule 'PSPossibleIncorrectComparisonWithNull' -Case 'A reversed $null comparison'
    Write-Host 'PASS: the analyser rejects an unapproved verb and a reversed $null comparison'

    # A file PowerShell cannot parse has to fail here rather than on a user's
    # machine. This is the coverage tests/test-windows-bootstrap.sh could only
    # offer when a pwsh happened to be installed.
    $unparseable = New-Fixture -Name 'unparseable.ps1' -Body @'
function Get-Thing {
    param([string]$Value)
'@
    $parseFindings = Invoke-Analysis -Path $unparseable -Settings $settings
    if ($parseFindings.Count -eq 0) {
        throw 'A file that does not parse was reported clean.'
    }
    Write-Host 'PASS: the analyser rejects a file that does not parse'

    # Redefining a built-in is the suites' technique and an installer's bug.
    # The two rule sets have to answer differently for the same text.
    $override = New-Fixture -Name 'override.ps1' -Body @'
function Get-Command {
    param([string]$Name)
    return $null
}

Get-Command -Name 'scoop'
'@
    Assert-Reported -Findings (Invoke-Analysis -Path $override -Settings $settings) `
        -Rule 'PSAvoidOverwritingBuiltInCmdlets' -Case 'A built-in redefined outside tests/'
    Assert-NotReported -Findings (Invoke-Analysis -Path $override -Settings $harnessSettings) `
        -Rule 'PSAvoidOverwritingBuiltInCmdlets' -Case 'A built-in redefined inside tests/'
    Write-Host 'PASS: redefining a built-in is a finding outside tests/ and the technique inside it'

    # Every repository-wide exclusion, proven to be what silences the finding:
    # reported with the rule set withdrawn, silent with it applied. An
    # exclusion that had stopped applying would otherwise look like clean code.
    $excluded = New-Fixture -Name 'excluded.ps1' -Body @'
function Get-Things {
    param([string]$Unused)
    Write-Host 'listing'
    return @('one', 'two')
}

function Set-Thing {
    param([string]$Value)
    Write-Host "setting $Value"
}

Get-Things -Unused 'x'
Set-Thing -Value 'y'
'@
    $unfiltered = Invoke-Analysis -Path $excluded -Settings @{ Severity = $settings.Severity }
    foreach ($rule in $settings.ExcludeRules) {
        Assert-Reported -Findings $unfiltered -Rule $rule -Case "The exclusion fixture, unfiltered,"
    }
    $filtered = Invoke-Analysis -Path $excluded -Settings $settings
    foreach ($rule in $settings.ExcludeRules) {
        Assert-NotReported -Findings $filtered -Rule $rule -Case 'The exclusion fixture'
    }
    Write-Host "PASS: all $($settings.ExcludeRules.Count) repository-wide exclusions are live and each silences a real finding"
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PowerShell static analysis tests passed.'
