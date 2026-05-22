# Frequently Asked Questions

## 1. My antivirus / Windows Defender flags this script as malicious

**This is a false positive.** Batch scripts that stop system services, rename system folders, and re-register DLLs match heuristic signatures used by antivirus engines — even though these are the exact steps [Microsoft documents](https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/additional-resources-for-windows-update) for resetting Windows Update.

**What to do:**
- Read the [source code](Reset_WindowsUpdate.cmd) — it's a single file, fully auditable
- [Submit a false positive report](https://www.microsoft.com/en-us/wdsi/filesubmission) to Microsoft Defender
- For other AV vendors, use their false-positive submission portals
- Temporarily exclude `Reset_WindowsUpdate.cmd` from real-time scanning while running

> We pre-submit every release to major AV vendors. If you encounter a detection, please [open an issue](../../issues) with the vendor name and detection signature.

---

## 2. Does this tool work on Windows 10 after end of support?

**Yes, with caveats.** Windows 10 mainstream support ended October 14, 2025. The tool still resets Windows Update components on Win10, but:

- **Without ESU enrollment**, you will not receive new security updates regardless of whether the reset succeeds
- **With ESU (Extended Security Updates)**, the tool works normally — your update pipeline is still active
- **LTSC/IoT Enterprise editions** have their own support lifecycles (LTSC 2021 is supported until 2027) and are unaffected

> **Our policy:** We support Windows 10 until October 2026. After that, the tool will display a deprecation notice but will not hard-block execution.

---

## 3. I'm on a domain with WSUS / SCCM — will this break my update configuration?

**Steps 6 and 7 are disabled by default** specifically because they modify registry policies and service permissions that enterprise environments rely on.

- **Step 6** (Delete WU registry policies) removes keys like `UseWUServer`, `WUServer`, `WUStatusServer`, and `NoAutoUpdate`. If your machine is domain-joined, **Group Policy will re-apply these on the next `gpupdate` cycle** — but the reset forces a fresh scan
- **Step 7** (Reset BITS/WU SDDLs) restores default service security descriptors. Only needed if permissions were corrupted

**For WSUS environments:**
1. Run the tool with default settings first (Steps 0–5, 8–14)
2. If updates still fail, enable Step 6 and run `gpupdate /force` afterward
3. After the reset, verify WSUS targeting with: `reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /s`

> **Note:** WSUS was [deprecated by Microsoft in September 2024](https://learn.microsoft.com/en-us/windows-server/administration/windows-server-update-services/plan/plan-your-wsus-deployment). It remains functional but receives no new features. If you're migrating off WSUS, this tool can help clear stale WSUS pointers.

---

## 4. The tool says "Access Denied" or services won't stop

**Root causes:**
- **Not running as Administrator** — the tool requires elevation. Right-click → "Run as administrator," or use the PowerShell launcher which auto-elevates via UAC
- **Group Policy blocking service control** — check if `TrustedInstaller` startup type is set to "Manual" by GPO. [Microsoft confirms](https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/common-windows-update-errors) this prevents pending transactions from completing
- **Another process holding a lock** — antivirus real-time scanning or backup software can lock `SoftwareDistribution`. Temporarily disable, then retry
- **BITS is corrupted** — if BITS won't stop/start, repair its configuration:
  ```cmd
  sc config bits binpath= "%systemroot%\system32\svchost.exe -k netsvcs"
  sc config bits depend= RpcSs/EventSystem
  sc config bits start= delayed-auto
  ```

---

## 5. Will this delete my downloaded updates / pending installs?

**Partially, by design.** The tool renames (not deletes) cache folders:
- `SoftwareDistribution` → `SoftwareDistribution.YYYYMMDD-HHMMSS.bak`
- `catroot2` → `catroot2.YYYYMMDD-HHMMSS.bak`

These backups remain on disk. After the reset, Windows Update will re-download any needed updates from scratch. If an update was stuck mid-install, the fresh download typically resolves it.

> **To recover:** Rename the timestamped folder back to its original name and restart the Windows Update service.

---

## 6. What's the difference between this and the built-in Windows Update Troubleshooter?

| | RWU | Windows Update Troubleshooter |
|---|---|---|
| **Steps** | 14-step reset including DLL re-registration, Winsock reset, BITS queue purge | ~5 automated checks, limited scope |
| **Visibility** | Full diagnostic log you can read and share | "We found problems" with minimal detail |
| **CLI mode** | `Reset_WindowsUpdate.cmd /diag` with exit codes | No CLI — GUI-only |
| **AI integration** | Diagnostic output designed for ChatGPT/Copilot analysis | None |
| **Optional steps** | Opt-in policy reset and SDDL repair for enterprise | Not available |
| **Scope** | Covers everything Microsoft documents in [KB971058](https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/additional-resources-for-windows-update) + extras | Subset only |

**Recommendation:** Try the built-in troubleshooter first. If it doesn't resolve the issue, run this tool.

---

## 7. Common error codes and what they mean

| Error Code | Meaning | Does RWU fix it? |
|---|---|---|
| `0x80070002` / `0x80070003` | Update files missing or path not found | ✅ Yes — cache reset resolves |
| `0x800f0922` | Insufficient disk space or System Reserved too small | ⚠️ Partially — detects component store issues (run `DISM /RestoreHealth` manually to repair), does not fix disk space |
| `0x80070422` | Windows Update service is disabled or stopped | ✅ Yes — service restart in Steps 1–2 |
| `0x80070020` | Another process blocking WU (usually AV) | ⚠️ Partially — identifies the conflict, but you must disable the blocker |
| `0x800705b4` | Update timed out or was interrupted | ✅ Yes — full reset clears stale state |
| `0x80073712` | Corrupted component store | ⚠️ Partially — cache reset + DLL re-registration resolve most cases; severe corruption may require `DISM /Online /Cleanup-Image /RestoreHealth` |
| `0x80240034` | Stuck update process | ✅ Yes — BITS queue purge + service restart |
| `0x80244007` | WSUS sync error | ⚠️ Requires Step 6 (opt-in) to clear WSUS policies |

> **For codes not listed:** Run `Reset_WindowsUpdate.cmd /diag` and paste the output into ChatGPT, Copilot, or Claude for AI-assisted analysis.

---

## 8. Does this tool phone home, install anything, or modify activation?

**No, no, and no.**

- **The tool** (`Reset_WindowsUpdate.cmd`) makes **no network calls** except the Windows Update connectivity test in Step 13 (which contacts `update.microsoft.com`)
- **The launcher** (`rwu.ps1`, used by the `irm | iex` one-liner) connects to the GitHub API to download the tool and verify its SHA256 hash — it does not run without a verified release
- **No binaries installed** — it's a single `.cmd` script
- **No telemetry** — no usage data is collected or transmitted
- **No activation changes** — this tool does not touch licensing, product keys, or KMS/MAK settings

---

## 9. Can I run this in an RMM / automated deployment pipeline?

**Yes.** CLI mode is designed for automation:

```cmd
:: Diagnostics only — exit code 0 (ok), 1 (error), 2 (warnings)
Reset_WindowsUpdate.cmd /diag

:: Full reset with all optional steps enabled
Reset_WindowsUpdate.cmd /reset /policy /sddl

:: Run a specific step
Reset_WindowsUpdate.cmd /step 3
```

**For RMM tools** (Datto, ConnectWise, NinjaRMM):
- Deploy the `.cmd` file to a temp directory
- Execute with `/reset` flag
- Capture the exit code for reporting
- Logs are written to `WU_Reset_Log.txt` on the Desktop by default (override with `/logdir "C:\logs"`)
- Console output can also be captured with `> C:\logs\rwu_console.log 2>&1`

---

## 10. SmartScreen warns "Windows protected your PC" when I download this

**Expected behavior for unsigned scripts.** Windows SmartScreen reputation is built over time based on download volume and code-signing certificates.

**What to do:**
1. Click "More info" → "Run anyway"
2. Or download from [GitHub Releases](../../releases) where you can verify the SHA256 checksum
3. Or inspect the source code on GitHub before downloading

> **Why not sign it?** Code-signing certificates cost ~$280/year. We plan to sign releases once the project reaches sufficient adoption to justify the cost. Until then, the full source code is available for audit.

---

## Still stuck?

1. Run `Reset_WindowsUpdate.cmd /diag` and save the output
2. [Open an issue](../../issues/new?template=bug_report.md) with the diagnostic log
3. Or paste the log into ChatGPT/Copilot/Claude — the output format is designed for AI analysis
