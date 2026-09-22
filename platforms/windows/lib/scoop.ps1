Set-StrictMode -Version Latest

# Scoop command resolution, shared by install.ps1 and verify.ps1.
#
# Neither script may rely on PATH alone. The Scoop installer runs in a child
# PowerShell, and a package's shim is published to the *user* PATH in the
# registry, so the session that installed something never sees it: Get-Command
# still fails in the parent even after a completely successful install. The
# installer has always had a fallback for that; the verifier had none, so
# running it in the same session after a successful install reported the very
# things that install had just put in place as missing.

# Get-ScoopRoot: the directory Scoop owns, honouring an explicit $env:SCOOP and
# otherwise the per-user default under the Windows profile.
function Get-ScoopRoot {
    if ($env:SCOOP) {
        return [IO.Path]::GetFullPath($env:SCOOP)
    }

    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'scoop'))
}

# Resolve-ScoopShimCommand -Name <name>: the full path of a command, taken from
# PATH when it is there and from Scoop's shims directory when it is not.
# Returns $null when neither has it, which is a real absence rather than a
# stale PATH.
#
# Scoop publishes a pair for the commands installed here -- shims\scoop.ps1
# beside shims\scoop.cmd -- so the two branches below have to name the same
# file for the same command. Which one that is belongs to PowerShell, not to
# this list: both callers are PowerShell, and PowerShell resolves an external
# script before an external application, which is the whole reason tools that
# ship a .cmd shim ship a .ps1 shim beside it. Hence .ps1 first, matching what
# the Get-Command above returns once the shims have reached PATH -- not
# PATHEXT's order, which is cmd.exe's rule and would have the two branches
# disagree for exactly the command this is most used on.
#
# The agreement is checked rather than argued: tests/test-windows-verifier.ps1
# resolves the same fixture with PATH set and with PATH empty and fails if the
# two answers differ. It matters because the result is then invoked as a
# command, and a .ps1 shim runs in the caller's PowerShell while a .cmd shim
# runs as a child process -- different propagation for $LASTEXITCODE and
# different behaviour for a 2>&1 redirect.
function Resolve-ScoopShimCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $shims = Join-Path (Get-ScoopRoot) 'shims'
    foreach ($extension in @('.ps1', '.cmd', '.exe', '')) {
        $candidate = Join-Path $shims ($Name + $extension)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

# Resolve-ScoopCommand: Scoop itself, by the same rule.
function Resolve-ScoopCommand {
    return Resolve-ScoopShimCommand -Name 'scoop'
}
