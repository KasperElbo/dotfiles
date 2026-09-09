Set-StrictMode -Version Latest

function ConvertFrom-WslVersionOutput {
    param([object[]]$Lines)

    $normalized = @(
        $Lines |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ }
    )
    if ($normalized.Count -eq 0) {
        return $null
    }

    # Current Store-delivered WSL emits the package version as the first
    # non-empty `label: major.minor.patch[.revision]` line. The label is
    # deliberately ignored so this does not depend on the Windows locale.
    # Do not scan later lines: kernel and component versions use the same
    # numeric shape and must never be mistaken for the WSL package version.
    $match = [regex]::Match(
        $normalized[0],
        '^[^:]+:\s*(?<Version>\d+\.\d+\.\d+(?:\.\d+)?)\s*$'
    )
    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Groups['Version'].Value
    }
    catch {
        return $null
    }
}

function Get-WslSupportStatus {
    param(
        [AllowNull()]
        [version]$InstalledVersion,

        [Parameter(Mandatory = $true)]
        [version]$MinimumProvenVersion
    )

    if ($null -eq $InstalledVersion) {
        return 'Unknown'
    }
    if ($InstalledVersion -lt $MinimumProvenVersion) {
        return 'Older'
    }
    return 'Proven'
}
