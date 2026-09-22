Set-StrictMode -Version Latest

# The Windows selection state, shared by install.ps1 and verify.ps1.
#
# install.ps1 records what the user chose; verify.ps1 reads that record to know
# which components it must prove are installed. So the file decides what
# verification demands, and a value it cannot read has to be an error rather
# than an answer. [bool] on whatever JSON happened to hold is not that: in
# PowerShell a non-empty string is true, so a hand-edited "false" reads as
# selected, and an empty array reads as not selected. Either way a corrupt file
# quietly changes what the machine is held to, and the run still reports a
# green schema line.
#
# The whole state is therefore validated before anything is observed, and the
# schema is declared here once so the writer and the reader cannot disagree
# about what the file holds.

# The selection flags, every one of which must be a JSON boolean.
$WindowsSelectionFlags = @(
    'WslRequired'
    'NocttySelected'
    'NocttyConfigurationSelected'
    'HandySelected'
)

# The same policy install.ps1 applies to -FedoraDistribution. A distribution
# name reaches `wsl.exe --distribution` and a regex in the verifier, so the
# recorded one is held to the shape the installer would have accepted.
$WindowsDistributionPattern = '^[A-Za-z0-9._-]+$'

# Read-WindowsSelectionState -Json <text> -SupportedSchemaVersion <int>:
# the state as a validated object, or an Error saying why it is not one.
#
# Every failure is one focused message naming the property and what was found,
# because the person reading it is looking at a file they may have edited. The
# flags are only filled in when the whole state validated, so no caller can
# read a selection out of a state that was rejected.
function Read-WindowsSelectionState {
    param(
        [AllowNull()][string]$Json,
        [Parameter(Mandatory = $true)][int]$SupportedSchemaVersion
    )

    $result = [ordered]@{
        Valid = $false
        Error = $null
        SchemaVersion = $null
        FedoraDistribution = ''
    }
    foreach ($flag in $WindowsSelectionFlags) { $result[$flag] = $false }
    $state = $null

    if ([string]::IsNullOrWhiteSpace($Json)) {
        $result.Error = 'the file is empty'
        return [pscustomobject]$result
    }

    try { $state = $Json | ConvertFrom-Json }
    catch {
        $result.Error = "it is not JSON: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    # A JSON array or a bare scalar parses without error and then answers every
    # property lookup with nothing, which would read as a state whose optional
    # selections are all absent. The type is named in full deliberately:
    # `-is [psobject]` is true of every value in PowerShell, including a number
    # and $null, so it would let all of them through.
    if ($null -eq $state -or
        $state.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
        $result.Error = 'it is not a JSON object'
        return [pscustomobject]$result
    }

    $schemaProperty = $state.PSObject.Properties['SchemaVersion']
    if ($null -eq $schemaProperty) {
        $result.Error = 'it has no SchemaVersion'
        return [pscustomobject]$result
    }

    # A schema version that is not a whole number is not a version. `[int]` on
    # a string would happily turn "1" into 1 and hide a file nothing in this
    # repository wrote.
    $schemaVersion = $schemaProperty.Value
    if ($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) {
        $result.Error = ("SchemaVersion is $(Get-WindowsSelectionTypeName $schemaVersion), " +
            'not a whole number')
        return [pscustomobject]$result
    }
    $result.SchemaVersion = [int]$schemaVersion

    # One schema has ever existed, so there is nothing to migrate from and
    # nothing to read forwards into. Both directions refuse, and say which
    # they are, rather than a single "unsupported" that leaves the user
    # guessing whether to rerun the installer or update the checkout.
    if ([int]$schemaVersion -lt $SupportedSchemaVersion) {
        $result.Error = ("schema $schemaVersion predates the supported schema " +
            "$SupportedSchemaVersion and there is no migration for it; rerun " +
            'platforms\windows\install.ps1 to record the selection again')
        return [pscustomobject]$result
    }
    if ([int]$schemaVersion -gt $SupportedSchemaVersion) {
        $result.Error = ("schema $schemaVersion is newer than the supported schema " +
            "$SupportedSchemaVersion; this checkout cannot read it")
        return [pscustomobject]$result
    }

    $distributionProperty = $state.PSObject.Properties['FedoraDistribution']
    if ($null -eq $distributionProperty) {
        $result.Error = 'it has no FedoraDistribution'
        return [pscustomobject]$result
    }
    $distribution = $distributionProperty.Value
    if ($distribution -isnot [string]) {
        $result.Error = ('FedoraDistribution is ' +
            "$(Get-WindowsSelectionTypeName $distribution), not a string")
        return [pscustomobject]$result
    }
    if (-not $distribution) {
        $result.Error = 'FedoraDistribution is empty'
        return [pscustomobject]$result
    }
    if ($distribution -notmatch $WindowsDistributionPattern) {
        $result.Error = "FedoraDistribution is not a distribution name: $distribution"
        return [pscustomobject]$result
    }

    # Every flag is required, and every one must be a JSON boolean. A flag that
    # is simply absent is not "not selected": it is a state file this checkout
    # did not write, and treating it as a default is how a component drops out
    # of verification without anybody being told.
    foreach ($flag in $WindowsSelectionFlags) {
        $property = $state.PSObject.Properties[$flag]
        if ($null -eq $property) {
            $result.Error = "it has no $flag"
            return [pscustomobject]$result
        }
        if ($property.Value -isnot [bool]) {
            $result.Error = ("$flag is $(Get-WindowsSelectionTypeName $property.Value), " +
                'not true or false')
            return [pscustomobject]$result
        }
    }

    foreach ($flag in $WindowsSelectionFlags) {
        $result[$flag] = [bool]$state.PSObject.Properties[$flag].Value
    }
    $result.FedoraDistribution = $distribution
    $result.Valid = $true
    return [pscustomobject]$result
}

# Get-WindowsSelectionTypeName: what a rejected value was, in the words of the
# file it came from rather than of the runtime that parsed it, so the message
# points at something the reader can find in their own JSON.
function Get-WindowsSelectionTypeName {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return 'true or false' }
    if ($Value -is [string]) { return "the string `"$Value`"" }
    if ($Value -is [Array]) { return 'an array' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
        $Value -is [decimal]) {
        return "the number $Value"
    }
    return 'an object'
}
