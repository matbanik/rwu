<#
.SYNOPSIS
    Bump the RWU version, commit, tag, and push.

.DESCRIPTION
    Updates the version in Reset_WindowsUpdate.cmd, commits the change,
    creates a signed git tag, and pushes to origin. The tag push triggers
    the GitHub Actions release workflow.

.PARAMETER Version
    Semver version string (e.g., 1.2.0). Do NOT include the "v" prefix.

.PARAMETER NoPush
    Stage and commit but do not push or tag. Useful for review before release.

.EXAMPLE
    .\bump.ps1 1.1.0
    .\bump.ps1 1.2.0 -NoPush
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [switch]$NoPush
)

$ErrorActionPreference = "Stop"
$ScriptFile = "Reset_WindowsUpdate.cmd"

# --- Validate working directory ---
if (-not (Test-Path $ScriptFile)) {
    Write-Host "ERROR: $ScriptFile not found. Run from the repo root." -ForegroundColor Red
    exit 1
}

# --- Read current version ---
$content = Get-Content $ScriptFile -Raw
if ($content -match 'set "ver=(\d+\.\d+\.\d+)"') {
    $oldVersion = $Matches[1]
} else {
    Write-Host "ERROR: Could not find version pattern in $ScriptFile" -ForegroundColor Red
    exit 1
}

if ($oldVersion -eq $Version) {
    Write-Host "Version is already $Version — nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  RWU Version Bump" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Current:  v$oldVersion" -ForegroundColor DarkGray
Write-Host "  New:      v$Version" -ForegroundColor Green
Write-Host ""

# --- Update version in script ---
$newContent = $content -replace 'set "ver=\d+\.\d+\.\d+"', "set `"ver=$Version`""
Set-Content -Path $ScriptFile -Value $newContent -NoNewline -Encoding UTF8

# Verify the change took effect
$verify = Get-Content $ScriptFile -Raw
if ($verify -notmatch "set `"ver=$Version`"") {
    Write-Host "ERROR: Version replacement failed!" -ForegroundColor Red
    exit 1
}
Write-Host "  Updated $ScriptFile" -ForegroundColor Green

# --- Git operations ---
$tag = "v$Version"

# Check for clean working tree (except our change)
$status = git status --porcelain
$otherChanges = $status | Where-Object { $_ -notmatch [regex]::Escape($ScriptFile) }
if ($otherChanges) {
    Write-Host ""
    Write-Host "  WARNING: Uncommitted changes detected beyond $ScriptFile" -ForegroundColor Yellow
    Write-Host "  These files have changes:" -ForegroundColor Yellow
    $otherChanges | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host ""
    $confirm = Read-Host "  Continue and include all changes in the bump commit? [y/N]"
    if ($confirm -ne 'y') {
        Write-Host "  Aborted. Commit other changes first, then re-run." -ForegroundColor Yellow
        exit 1
    }
}

# Stage, commit, tag
git add -A
git commit -m "bump: v$Version"

if ($NoPush) {
    Write-Host ""
    Write-Host "  Committed locally (--NoPush). To release:" -ForegroundColor Yellow
    Write-Host "    git tag $tag" -ForegroundColor DarkGray
    Write-Host "    git push origin main --tags" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# Tag and push
git tag $tag
Write-Host "  Tagged: $tag" -ForegroundColor Green

git push origin main --tags
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  Pushed $tag — GitHub Actions will create the release." -ForegroundColor Green
Write-Host "  https://github.com/matbanik/rwu/actions" -ForegroundColor DarkGray
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""
