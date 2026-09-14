[CmdletBinding()]
param(
    [string]$StatePath,

    [Parameter(DontShow = $true)]
    [string]$FixturePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$arguments = @{}
if ($StatePath) { $arguments.StatePath = $StatePath }
if ($FixturePath) { $arguments.FixturePath = $FixturePath }

& (Join-Path $PSScriptRoot 'platforms\windows\verify.ps1') @arguments
exit $LASTEXITCODE
