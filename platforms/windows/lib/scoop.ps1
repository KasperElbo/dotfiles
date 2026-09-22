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
        [string]$Name,

        # The Scoop root to look under, so a caller that has already decided
        # which root a question is about asks about that one rather than
        # re-deriving it from the environment halfway through.
        [string]$Root
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if (-not $Root) { $Root = Get-ScoopRoot }
    $shims = Join-Path $Root 'shims'
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

# --- Ownership -------------------------------------------------------------
#
# One question, asked the same way by install.ps1 and by verify.ps1: does this
# machine have the bucket and the package platforms\windows\manifest.psd1
# declares, put there by Scoop, out of that bucket.
#
# A name is not an answer to it. A bucket called `extras` is whatever
# repository was cloned into buckets\extras, and `handy` resolving on PATH says
# a program by that name exists somewhere -- which is exactly what a
# substitution would also say. The functions below read what Scoop itself
# records, and keep PATH resolution as a separate observation about whether the
# user can reach what Scoop installed.

# ConvertTo-CanonicalScoopBucketUrl: two spellings of one repository compare
# equal. Git and Scoop both accept a trailing .git and a trailing slash, and
# GitHub owner and repository names are matched case-insensitively, so those
# differences are harmless. Anything else -- a different host, owner or
# repository -- is left exactly as written, so it cannot be normalised away.
function ConvertTo-CanonicalScoopBucketUrl {
    param([AllowNull()][string]$Url)

    if (-not $Url) { return '' }

    $value = $Url.Trim()
    $value = $value -replace '/+$', ''
    $value = $value -replace '\.git$', ''
    return $value.ToLowerInvariant()
}

# ConvertFrom-ScoopBucketList: `scoop bucket list` prints a table whose first
# two columns are the bucket's name and the URL it was added from. Reading it
# as a table rather than matching a name at the start of a line is what makes
# the URL available at all; the header and its underline are not buckets.
#
# Each row is written to the pipeline on its own, so a caller filters it with
# Where-Object and counts it with @(). Returning the whole array as one value
# instead -- `return ,$rows`, to keep .Count working on a single row -- is what
# would send the table through a filter as a single item, where $_.Name
# enumerates to every name at once and the filter matches whatever it is given.
function ConvertFrom-ScoopBucketList {
    param([AllowEmptyCollection()][object[]]$Lines = @())

    foreach ($line in $Lines) {
        $text = ([string]$line).Trim()
        if (-not $text) { continue }

        $fields = @($text -split '\s+' | Where-Object { $_ })
        if ($fields.Count -lt 2) { continue }
        if ($fields[0] -eq 'Name' -or $fields[0] -match '^-+$') { continue }

        [pscustomobject]@{
            Name = $fields[0]
            Source = $fields[1]
        }
    }
}

# Get-ScoopBucketOrigin: the URL the installed bucket's own checkout points at,
# read from its Git configuration. Scoop adds a bucket by cloning, so this is
# where a `scoop update` will actually fetch from, whatever name sits over it.
#
# It is also the same answer `scoop bucket list` gives: Scoop derives that
# table's Source column from each bucket's remote. That is what lets the
# verifier ask Scoop's own question without starting a process -- it stays
# read-only and has no external probe to bound -- while the installer, which
# already holds the table, requires the two to agree before it installs.
#
# The file is read rather than `git remote get-url` run, so the answer does not
# depend on a git being on PATH at the moment the question is asked.
function Get-ScoopBucketOrigin {
    param([Parameter(Mandatory = $true)][string]$Path)

    $configuration = Join-Path (Join-Path $Path '.git') 'config'
    if (-not (Test-Path -LiteralPath $configuration -PathType Leaf)) {
        return $null
    }

    $inOrigin = $false
    foreach ($line in (Get-Content -LiteralPath $configuration)) {
        $text = $line.Trim()
        if ($text -match '^\[remote\s+"([^"]+)"\]$') {
            $inOrigin = ($Matches[1] -eq 'origin')
            continue
        }
        if ($text.StartsWith('[')) {
            $inOrigin = $false
            continue
        }
        if ($inOrigin -and $text -match '^url\s*=\s*(.+)$') {
            return $Matches[1].Trim()
        }
    }

    return $null
}

# Get-ScoopBucketOwnership: everything known about one declared bucket, as
# observations rather than a verdict, so the installer and the verifier can
# word the same facts for their own readers.
#
# Owned is the verdict both of them use, and it means the same thing on both
# sides: the directory is there and the checkout inside it is the declared
# repository. The bucket table is an extra, independent reading that only the
# installer has; when it was not supplied, Registered and ConfiguredMatches are
# $null rather than $false, so a caller cannot mistake "not read" for "does not
# match" and BucketListRead says which of the two it was.
function Get-ScoopBucketOwnership {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Bucket,
        [AllowNull()][object[]]$BucketList,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-ScoopRoot }

    $path = Join-Path (Join-Path $Root 'buckets') $Bucket.Name
    $declared = ConvertTo-CanonicalScoopBucketUrl $Bucket.Url
    $exists = Test-Path -LiteralPath $path -PathType Container

    $origin = if ($exists) { Get-ScoopBucketOrigin -Path $path } else { $null }
    $originMatches = $null -ne $origin -and
        (ConvertTo-CanonicalScoopBucketUrl $origin) -eq $declared

    $bucketListRead = $null -ne $BucketList
    $registered = $null
    $configured = $null
    $configuredMatches = $null
    if ($bucketListRead) {
        $row = ConvertFrom-ScoopBucketList -Lines $BucketList |
            Where-Object { $_.Name -eq $Bucket.Name } |
            Select-Object -First 1
        $registered = [bool]$row
        $configured = if ($row) { $row.Source } else { $null }
        $configuredMatches = $null -ne $configured -and
            (ConvertTo-CanonicalScoopBucketUrl $configured) -eq $declared
    }

    return [pscustomobject]@{
        Name = $Bucket.Name
        Path = $path
        DeclaredUrl = $Bucket.Url
        Exists = $exists
        OriginUrl = $origin
        OriginMatches = $originMatches
        BucketListRead = $bucketListRead
        Registered = $registered
        ConfiguredUrl = $configured
        ConfiguredMatches = $configuredMatches
        Owned = ($exists -and $originMatches)
    }
}

# Get-ScoopPackageOwnership: a package is installed when Scoop says so in its
# own metadata, out of the bucket the manifest names.
#
# apps\<name>\current existing is not that. Scoop writes install.json when an
# install finishes, so a directory alone proves an install was started, and a
# manifest.json without it proves nothing about where the package came from.
# install.json's bucket field is the only record of which bucket supplied it,
# which is what makes `extras/handy` different from a `handy` someone published
# in a bucket of their own.
#
# CommandPath is deliberately not part of the verdict. Whether the shim has
# reached PATH is about the user's session, not about what Scoop installed: the
# session that ran the install cannot see it yet, and a program of the same name
# elsewhere on PATH is a shadowing problem rather than a missing package.
function Get-ScoopPackageOwnership {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Package,
        [Parameter(Mandatory = $true)][string]$BucketName,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-ScoopRoot }

    $current = Join-Path (Join-Path (Join-Path $Root 'apps') $Package.Name) 'current'
    $record = Join-Path $current 'install.json'
    $packageManifest = Join-Path $current 'manifest.json'
    $executable = Join-Path $current $Package.Executable

    $installedBucket = $null
    $metadataError = $null
    if (Test-Path -LiteralPath $record -PathType Leaf) {
        try {
            $metadata = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
            $property = $metadata.PSObject.Properties['bucket']
            if ($property) { $installedBucket = [string]$property.Value }
        }
        catch {
            $metadataError = $_.Exception.Message
        }
    }

    $hasManifest = Test-Path -LiteralPath $packageManifest -PathType Leaf
    $hasExecutable = Test-Path -LiteralPath $executable -PathType Leaf
    $bucketMatches = ($null -ne $installedBucket -and $installedBucket -eq $BucketName)

    return [pscustomobject]@{
        Name = $Package.Name
        QualifiedName = $Package.QualifiedName
        CurrentPath = $current
        ExecutablePath = $executable
        CommandPath = Resolve-ScoopShimCommand -Name $Package.Name -Root $Root
        DeclaredBucket = $BucketName
        InstalledBucket = $installedBucket
        MetadataError = $metadataError
        Exists = Test-Path -LiteralPath $current -PathType Container
        HasManifest = $hasManifest
        HasExecutable = $hasExecutable
        BucketMatches = $bucketMatches
        Installed = (
            $hasManifest -and $hasExecutable -and $bucketMatches -and
            $null -eq $metadataError
        )
    }
}
