# RWU — Reset & Repair Utility for Windows Update

> Open-source Windows Update reset tool featuring comprehensive diagnostics, safe cache cleanup, DLL re-registration, and AI friendly log for analysis in a single script.

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Windows 11](https://img.shields.io/badge/Windows-11-0078D6?logo=windows11&logoColor=white)](#requirements)
[![Windows 10](https://img.shields.io/badge/Windows-10-0078D6?logo=windows&logoColor=white)](#requirements)

## Quick Start

Open **PowerShell** and run:

```powershell
irm https://matbanik.info/rwu | iex
```

Or [download from Releases](https://github.com/matbanik/rwu/releases) → right-click → **Run as administrator**.

> [!NOTE]
> `irm` downloads a tiny launcher; it fetches the tool from GitHub and runs it elevated (UAC prompt). Run `irm https://matbanik.info/rwu` alone to inspect the launcher first.

## Features

| Feature | Details |
|---------|---------|
| 🔍 **14-step reset** | Stop services → clear caches → re-register DLLs → restart → verify |
| 📋 **Interactive menu** | Full-screen TUI with color-coded toggles and step selection |
| ⚡ **CLI mode** | `/diag`, `/reset`, `/step N` — exit codes `0`/`1`/`2` |
| 🤖 **AI-ready diagnostics** | Paste the log into ChatGPT, Copilot, or Claude for instant analysis |
| 🛡️ **Safe by default** | Dangerous steps disabled; require explicit opt-in with confirmation |
| 🔄 **Reversible** | Cache folders timestamped, registry keys exported before deletion |
| 📦 **Zero dependencies** | Single `.cmd` file — no installers, no telemetry, no admin tools |

## Usage

```powershell
# Interactive menu
Reset_WindowsUpdate.cmd

# CLI: diagnostics only
Reset_WindowsUpdate.cmd /diag

# CLI: full reset with all optional steps
Reset_WindowsUpdate.cmd /reset /policy /sddl

# CLI: run a specific step
Reset_WindowsUpdate.cmd /step 3

# Full help
Reset_WindowsUpdate.cmd /help
```

<details>
<summary><strong>What each step does</strong></summary>

| Step | Action | Risk |
|------|--------|------|
| 0 | System diagnostics (OS, hardware, disk, events, network) | None |
| 1–2 | Record config & stop WU services | Low |
| 3 | Delete BITS queue data | Low |
| 4 | Rename SoftwareDistribution & catroot2 (timestamped) | Low |
| 5 | Reset BITS transfer queue | Low |
| 6 | Export & delete WU registry policies *(opt-in)* | Medium |
| 7 | Reset BITS/WU service permissions *(opt-in)* | Medium |
| 8 | Re-register 30+ WU DLLs | Low |
| 9–10 | Reset Winsock, proxy & flush DNS | Medium |
| 11–14 | Restart services, verify connectivity, capture history | None |

</details>

## When to Use This

- ❌ Windows Update stuck at 0% or failing with error codes
- ❌ Updates downloading but not installing
- ❌ "Something went wrong" or "Undoing changes" after update
- ❌ Windows Update missing from Settings

> **Not for activation issues.** This tool only resets update components — no licensing or product key changes.

## Requirements

| | |
|---|---|
| **OS** | Windows 10 / 11 |
| **Privileges** | Administrator |
| **Dependencies** | None |

## Security

- 100% open source — read every line before running
- **The tool** (`Reset_WindowsUpdate.cmd`) makes no outbound calls except the WU connectivity test (Step 13)
- **The launcher** (`rwu.ps1`) downloads the tool from GitHub Releases and verifies its SHA256 hash before execution
- No telemetry, no bundled software, no activation changes
- Logs may contain system identifiers — review before sharing

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[GPL-3.0](LICENSE) — **Mat Banik** · [matbanik.info/reset-windows-update-guide](https://matbanik.info/reset-windows-update-guide)

---

<sub>This is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Microsoft Corporation. "Windows" and "Windows Update" are trademarks of Microsoft Corporation, used here for descriptive purposes only under nominative fair use.</sub>

<p align="center"><strong>If this helped you, ⭐ the repo — it helps others find it.</strong></p>
