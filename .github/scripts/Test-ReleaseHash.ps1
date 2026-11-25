<#
.SYNOPSIS
    Checks that the launcher will read the right SHA256 from a release body.

.DESCRIPTION
    Takes the SHA256 regex from the launcher itself, applies it to the release body, and exits 0
    only if the first match is the expected hash. Exits 1 in every other case.
#>
param(
    [Parameter(Mandatory = $true)][string]$BodyPath,
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [Parameter(Mandatory = $true)][string]$ExpectedHash
)

$ErrorActionPreference = 'Stop'

function Stop-Check([string]$Message) {
    Write-Host "ERROR: $Message"
    exit 1
}

if ($ExpectedHash -notmatch '^[0-9A-Fa-f]{64}$') { Stop-Check 'the expected hash is not a SHA256' }

$found = [regex]::Matches([IO.File]::ReadAllText((Resolve-Path $LauncherPath)), "-match\s+'([^']*SHA256[^']*)'")
if ($found.Count -ne 1) { Stop-Check "$($found.Count) SHA256 regexes in $LauncherPath, expected 1" }

$m = [regex]::Match([IO.File]::ReadAllText((Resolve-Path $BodyPath)), $found[0].Groups[1].Value)
if (-not $m.Success) { Stop-Check "no SHA256 in $BodyPath" }
if ($m.Groups[1].Value -ne $ExpectedHash) { Stop-Check "the launcher would read $($m.Groups[1].Value), expected $ExpectedHash" }
Write-Host "OK: the launcher reads $ExpectedHash"
