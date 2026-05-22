# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, **please report it responsibly**.

### How to Report

1. **DO NOT** open a public GitHub issue for security vulnerabilities
2. Email **matbanik+rwu@gmail.com** with:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if you have one)

### What to Expect

- **Acknowledgment** within 48 hours
- **Assessment** within 1 week
- **Fix & disclosure** timeline agreed upon together

### Scope

This policy covers:
- The `Reset_WindowsUpdate.cmd` script
- The `rwu.ps1` PowerShell launcher
- The `matbanik.info/rwu` redirect endpoint
- Any future scripts in this repository

### Out of Scope

- Windows operating system vulnerabilities (report to [Microsoft MSRC](https://msrc.microsoft.com/))
- Issues with third-party tools mentioned in documentation

## Security Considerations

This project has two components with different security profiles:

### `Reset_WindowsUpdate.cmd` (the tool)

Runs with **Administrator privileges** by design — it must modify system services and registry keys:

- Makes **no outbound network connections** except the WU connectivity test (Step 13)
- Does **not** download, install, or execute any external code
- Does **not** modify Windows licensing, activation, or product keys
- Does **not** collect, transmit, or store any telemetry
- **Logs** may contain system identifiers, network configuration, and license details — users are warned to review before sharing

### `rwu.ps1` (the launcher)

The `irm https://matbanik.info/rwu | iex` one-liner downloads this launcher, which then:

- **Fetches** the latest `Reset_WindowsUpdate.cmd` from the GitHub Releases API
- **Verifies** the SHA256 hash against the pinned checksum published in the release notes
- **Elevates** via UAC and runs the downloaded script
- **Cleans up** the temporary directory after execution

The launcher runs in a unique temporary directory (not a predictable path) and aborts if the hash does not match the published release.

## Integrity Verification

Users can verify the script before running:

```powershell
# View the launcher without executing
irm https://matbanik.info/rwu

# Compare SHA256 hash against published release hash
(Get-FileHash .\Reset_WindowsUpdate.cmd -Algorithm SHA256).Hash
```

Published hashes are available in each [GitHub Release](https://github.com/matbanik/rwu/releases).
