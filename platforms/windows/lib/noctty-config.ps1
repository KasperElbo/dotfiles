Set-StrictMode -Version Latest

# The repository-managed block inside Noctty's config.ghostty, shared by
# install.ps1 and verify.ps1.
#
# The file belongs to the user; a few lines in it belong to this repository,
# fenced by two markers. Everything about that arrangement is a structure --
# how many blocks there are, where each begins and ends, what is inside one and
# what is outside every one -- and reading it with independent global regex
# matches answers none of those questions. A file holding two managed blocks
# satisfies "a BEGIN marker occurs somewhere" and "the expected config-file
# line occurs somewhere" while the two blocks give Ghostty conflicting
# settings, and an installer that removes only the first one leaves it that
# way. So the parse below is the one place either script learns what is in
# the file, and it answers with the blocks it found rather than with a verdict.

$NocttyManagedBlockStart = '# BEGIN dotfiles Fedora WSL'
$NocttyManagedBlockEnd = '# END dotfiles Fedora WSL'

# Get-NocttyManagedBlocks -Content <text>: every complete managed block, in the
# order they appear, each with the offsets it occupies and the lines between
# its markers. MarkerError is set instead when the markers do not pair up, and
# is the signal to leave the file alone: an END before any BEGIN, a second
# BEGIN inside a block, or a BEGIN the file never closes all mean this is not a
# file whose managed region can be identified, and rewriting it would be a
# guess at where somebody else's configuration starts.
function Get-NocttyManagedBlocks {
    param([AllowNull()][string]$Content)

    $blocks = @()
    $markerError = $null
    if ($null -ne $Content) {
        # Trailing spaces on a marker line are tolerated, because an editor
        # that strips or adds them has not changed which line it is. Anything
        # else on the line means it is not a marker.
        $pattern = '(?m)^# (?<kind>BEGIN|END) dotfiles Fedora WSL[ \t]*\r?$'
        $open = $null
        foreach ($match in [regex]::Matches($Content, $pattern)) {
            $kind = $match.Groups['kind'].Value
            if ($kind -eq 'BEGIN') {
                if ($null -ne $open) {
                    $markerError = 'a second BEGIN marker appears before the previous block is closed'
                    break
                }
                $open = $match
                continue
            }

            if ($null -eq $open) {
                $markerError = 'an END marker appears before any BEGIN marker'
                break
            }

            # The newline after the END marker belongs to the block: removing
            # the block without it would leave a blank line behind and a rerun
            # would not be a no-op.
            $end = $match.Index + $match.Length
            $newline = [regex]::Match($Content.Substring($end), '^\r?\n')
            if ($newline.Success) { $end += $newline.Length }

            $bodyStart = $open.Index + $open.Length
            $bodyStart += ([regex]::Match($Content.Substring($bodyStart), '^\r?\n')).Length
            $blocks += [pscustomobject]@{
                Index = $open.Index
                Length = $end - $open.Index
                Body = $Content.Substring($bodyStart, $match.Index - $bodyStart)
            }
            $open = $null
        }

        if (-not $markerError -and $null -ne $open) {
            $markerError = 'a BEGIN marker is never closed by an END marker'
        }
    }

    return [pscustomobject]@{
        Blocks = @($blocks)
        Count = @($blocks).Count
        MarkerError = $markerError
    }
}

# Remove-NocttyManagedBlocks -Content <text>: what is left of the file once
# every complete managed block is taken out, byte for byte. Blocks are removed
# back to front so an earlier removal cannot move a later block's offsets.
function Remove-NocttyManagedBlocks {
    param([AllowNull()][string]$Content)

    if ($null -eq $Content) { return '' }

    $parsed = Get-NocttyManagedBlocks -Content $Content
    if ($parsed.MarkerError) {
        throw ("Noctty's configuration has a malformed repository-managed block: " +
            "$($parsed.MarkerError). Fix the markers by hand and rerun; nothing was changed.")
    }

    $remaining = $Content
    for ($index = $parsed.Count - 1; $index -ge 0; $index--) {
        $block = $parsed.Blocks[$index]
        $remaining = $remaining.Remove($block.Index, $block.Length)
    }
    return $remaining
}

# Test-NocttyUserCommand -Content <text>: whether the user's own part of the
# file declares a Ghostty command. It is asked of the content with every
# managed block already removed, because a `command =` inside a stale managed
# block is this repository's line from an earlier run, not the user's, and
# reading it as the user's is how the installer talks itself out of writing the
# command the run is about.
function Test-NocttyUserCommand {
    param([AllowNull()][string]$Content)

    if (-not $Content) { return $false }
    return [bool]($Content -match '(?m)^\s*command\s*=')
}

# New-NocttyManagedBlockBody -Distribution <name> -HasUserCommand: the lines
# between the markers, which is the whole of what this repository owns in that
# file. The installer writes it and the verifier compares against it, so there
# is one spelling of it rather than an installer's and a verifier's idea of it.
function New-NocttyManagedBlockBody {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [switch]$HasUserCommand
    )

    $commandSetting = if ($HasUserCommand) {
        '# Fedora WSL command omitted: a user-managed command exists below.'
    }
    else {
        "command = direct:wsl.exe --distribution $Distribution"
    }

    return (@(
            '# Reuse the tracked Ghostty configuration; keep Windows-only settings here.'
            'config-file = "dotfiles/ghostty.conf"'
            'config-file = "dotfiles/theme.conf"'
            $commandSetting
        ) -join "`n") + "`n"
}

# New-NocttyManagedBlock: the body with its markers around it, ending in a
# newline so the user's own content starts on its own line.
function New-NocttyManagedBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [switch]$HasUserCommand
    )

    $body = New-NocttyManagedBlockBody -Distribution $Distribution -HasUserCommand:$HasUserCommand
    return "$NocttyManagedBlockStart`n$body$NocttyManagedBlockEnd`n"
}
