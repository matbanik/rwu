# RWU — Windows Update Reset & Repair Tool (PowerShell Launcher)
# Usage: irm https://matbanik.info/rwu | iex
# Source: https://github.com/matbanik/rwu
#
# This launcher fetches the latest Release asset (not raw.githubusercontent.com)
# to avoid GitHub's unauthenticated rate limits on raw URLs (May 2025 change).
#
# Debug mode: set $env:RWU_DEBUG=1 before running. Uses /k (window stays open),
# passes /debug to the batch script, and preserves temp files for inspection.

$repo  = 'matbanik/rwu'
$asset = 'Reset_WindowsUpdate.cmd'
$tmpDir = Join-Path $env:TEMP "rwu_$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$tmp   = Join-Path $tmpDir $asset
$debug = $env:RWU_DEBUG -eq '1'

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  RWU — Windows Update Reset & Repair Tool" -ForegroundColor Cyan
Write-Host "  https://github.com/$repo" -ForegroundColor DarkGray
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""

try {
    # Fetch latest release asset URL from GitHub API (Releases are rate-limit safe)
    Write-Host "  Fetching latest release..." -ForegroundColor Gray
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing -ErrorAction Stop
        $url = ($release.assets | Where-Object { $_.name -eq $asset }).browser_download_url
        # Extract pinned SHA256 from release body (format: SHA256: <64-hex-chars>)
        $pinnedHash = $null
        if ($release.body -match '(?i)SHA256:\s*([0-9A-Fa-f]{64})') { $pinnedHash = $Matches[1].ToUpper() }
        if (-not $url) {
            # Fallback: use the source tree from the tag
            $tag = $release.tag_name
            $url = "https://raw.githubusercontent.com/$repo/$tag/$asset"
        }
        Write-Host "  Version: $($release.tag_name)" -ForegroundColor Gray
    } catch {
        Write-Host "  ERROR: No releases found on GitHub." -ForegroundColor Red
        Write-Host "  The launcher requires a published release with a SHA256 checksum." -ForegroundColor Red
        Write-Host "  Download manually from: https://github.com/$repo/releases" -ForegroundColor Yellow
        return
    }

    Write-Host "  Downloading..." -ForegroundColor Gray
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host "  ERROR: Download failed." -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Manual download: https://github.com/$repo/releases" -ForegroundColor Yellow
        Write-Host ""
        return
    }

    if (-not (Test-Path $tmp)) {
        Write-Host "  ERROR: File not found after download." -ForegroundColor Red
        return
    }

    $size = (Get-Item $tmp).Length
    $hash = (Get-FileHash $tmp -Algorithm SHA256).Hash
    Write-Host "  Size:   $([math]::Round($size/1KB, 1)) KB" -ForegroundColor DarkGray
    Write-Host "  SHA256: $hash" -ForegroundColor DarkGray

    # Verify hash against pinned release checksum
    if ($pinnedHash) {
        if ($hash -eq $pinnedHash) {
            Write-Host "  Integrity: VERIFIED (matches release hash)" -ForegroundColor Green
        } else {
            Write-Host "  ERROR: Hash mismatch! Expected $pinnedHash" -ForegroundColor Red
            Write-Host "  The downloaded file may be corrupted or tampered with." -ForegroundColor Red
            Write-Host "  Download manually from: https://github.com/$repo/releases" -ForegroundColor Yellow
            return
        }
    } else {
        Write-Host "  ERROR: No SHA256 hash found in release notes." -ForegroundColor Red
        Write-Host "  Cannot verify file integrity. Aborting." -ForegroundColor Red
        Write-Host "  Download manually and verify: https://github.com/$repo/releases" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "  Launching as Administrator (UAC prompt)..." -ForegroundColor Cyan

    if ($debug) {
        Write-Host "  [DEBUG] Debug mode enabled (RWU_DEBUG=1)" -ForegroundColor Yellow
        Write-Host "  [DEBUG] Script path: $tmp" -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Using /k (window stays open on exit)" -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Temp files preserved for inspection" -ForegroundColor DarkGray
    }
    Write-Host ""

    try {
        if ($debug) {
            Start-Process $env:ComSpec -ArgumentList "/k call `"$tmp`" /debug" -Verb RunAs -Wait
        } else {
            Start-Process $env:ComSpec -ArgumentList "/c call `"$tmp`"" -Verb RunAs -Wait
        }
    } catch {
        Write-Host "  ERROR: Failed to launch elevated process." -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  This may happen if the UAC prompt was cancelled." -ForegroundColor Yellow
        Write-Host "  Temp files: $tmpDir" -ForegroundColor DarkGray
        return
    }
} finally {
    # Cleanup temp files (skip in debug mode for inspection)
    if (-not $debug) {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
