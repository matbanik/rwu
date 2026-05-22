# Contributing to Windows Update Reset & Repair Tool

Thank you for your interest in improving this tool! Whether you're fixing a bug, adding a feature, improving documentation, or reporting an issue — your help is valued.

## How to Contribute

### 🐛 Reporting Bugs

1. **Check existing issues** first to avoid duplicates
2. Open a new issue using the [Bug Report template](.github/ISSUE_TEMPLATE/bug_report.md)
3. Include:
   - Windows version and build number (run `winver`)
   - The exact error or unexpected behavior
   - The log file output (sanitize any sensitive data)
   - Steps to reproduce

### 💡 Suggesting Features

1. Open a new issue using the [Feature Request template](.github/ISSUE_TEMPLATE/feature_request.md)
2. Describe the problem your feature would solve
3. Explain your proposed solution
4. Consider edge cases and safety implications

### 🔧 Submitting Code Changes

#### Setup

1. Fork the repository
2. Clone your fork:
   ```
    git clone https://github.com/YOUR_USERNAME/rwu.git
   ```
3. Create a feature branch:
   ```
   git checkout -b fix/describe-your-change
   ```

#### Guidelines

- **Test on a real Windows machine** (or VM) — batch scripts can't be unit-tested in isolation
- **Preserve safety defaults** — dangerous operations must remain OFF by default
- **Log everything** — every action should be logged with timestamps
- **Use errorlevel checks** — always check return codes and handle failures gracefully
- **Match existing style** — indentation, comment blocks, variable naming
- **Update the help screen** if you add CLI arguments
- **Bump the version** in the `set "ver=X.Y.Z"` line following semver

#### Commit Messages

Use clear, descriptive commit messages:
```
fix: handle SoftwareDistribution locked by antivirus
feat: add Step 0p - TPM health check
docs: update FAQ with domain-joined PC guidance
```

#### Pull Request Process

1. Push your branch to your fork
2. Open a PR against `main`
3. Include in the PR description:
   - **What** does this change?
   - **Why** is it needed?
   - **How** was it tested?
   - **Risk**: Low / Medium / High — and what's the rollback plan?
4. Wait for review — we aim to respond within 48 hours

### 📝 Improving Documentation

Documentation improvements are always welcome:
- Fix typos, clarify instructions, add examples
- Translate the README to other languages
- Improve inline comments in the script
- Add screenshots or screen recordings

No PR template needed for documentation-only changes — just open the PR with a clear title.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By participating, you agree to uphold a welcoming, inclusive environment.

## Questions?

Open a [Discussion](https://github.com/matbanik/rwu/discussions) — we're happy to help!
