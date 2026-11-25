<#
.SYNOPSIS
    Run a selection of the Pester suite and fail unless it really ran.
.DESCRIPTION
    Exit 0 only if passed >= MinTests, failed tests, blocks and containers are 0, and skipped <= AllowSkipped.
    A pattern that matches nothing therefore fails. Tests tagged 'Live' run only when the pattern names Phase 24.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FullName,
    [Parameter(Mandatory)][ValidateRange(1, 100000)][int]$MinTests,
    [int]$AllowSkipped = 0,
    [string]$Path = (Join-Path $PSScriptRoot '..\rwu.Tests.ps1')
)
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.4.0
$c = New-PesterConfiguration
$c.Run.Path = $Path
$c.Run.PassThru = $true
$c.Output.Verbosity = 'Detailed'
$c.Output.RenderMode = 'Plaintext'
$c.Filter.FullName = $FullName
if ($FullName -notlike '*Phase 24*') { $c.Filter.ExcludeTag = 'Live' }
$r = Invoke-Pester -Configuration $c
$ok = $r -and $r.PassedCount -ge $MinTests -and $r.FailedCount -eq 0 -and $r.FailedBlocksCount -eq 0 -and
    $r.FailedContainersCount -eq 0 -and $r.SkippedCount -le $AllowSkipped
"RUNNER passed=$($r.PassedCount) (min $MinTests) failed=$($r.FailedCount) blocks=$($r.FailedBlocksCount) containers=$($r.FailedContainersCount) skipped=$($r.SkippedCount) (max $AllowSkipped) ok=$([bool]$ok)"
exit $(if ($ok) { 0 } else { 1 })
