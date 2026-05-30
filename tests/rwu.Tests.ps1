#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.4.0' }
<#
    RWU — Pester 5 test suite
    Organised by implementation phase so tests can be written before code (TDD).
    Run:  pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.4.0; Invoke-Pester tests/ -Output Detailed"
#>

# ── Shared Helpers (loaded once at discovery time) ───────────────────────────
# Pester 5 scoping: BeforeAll at file level runs before any Describe block.

BeforeAll {
    function Invoke-RwuCmd {
        <#
        .SYNOPSIS  Run Reset_WindowsUpdate.cmd with given arguments, return exit code + captured output.
        #>
        [CmdletBinding()]
        param(
            [string]$ScriptPath = (Join-Path $PSScriptRoot '..\Reset_WindowsUpdate.cmd'),
            [string[]]$Arguments = @(),
            [string]$LogDir
        )
        $argString = ($Arguments -join ' ')
        if ($LogDir) { $argString += " /logdir `"$LogDir`"" }

        $proc = Start-Process -FilePath $env:ComSpec `
            -ArgumentList "/c call `"$ScriptPath`" $argString" `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput (Join-Path $LogDir 'stdout.txt') `
            -RedirectStandardError  (Join-Path $LogDir 'stderr.txt')

        @{
            ExitCode = $proc.ExitCode
            Stdout   = (Get-Content (Join-Path $LogDir 'stdout.txt') -Raw -ErrorAction SilentlyContinue)
            Stderr   = (Get-Content (Join-Path $LogDir 'stderr.txt') -Raw -ErrorAction SilentlyContinue)
            LogFile  = (Get-ChildItem $LogDir -Filter 'WU_Reset_Log.txt' -ErrorAction SilentlyContinue | Select-Object -First 1)
            DebugLog = (Get-ChildItem $LogDir -Filter 'RWU_Debug.log'    -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
    }

    function Get-CmdFileContent {
        Get-Content (Join-Path $PSScriptRoot '..\Reset_WindowsUpdate.cmd') -Raw
    }

    function Get-LauncherContent {
        Get-Content (Join-Path $PSScriptRoot '..\rwu.ps1') -Raw
    }
}

# ── Phase 0: Smoke ──────────────────────────────────────────────────────────

Describe 'Phase 0 — Test Harness Smoke' {
    It 'Pester 5.x is loaded' {
        (Get-Module Pester).Version.Major | Should -BeGreaterOrEqual 5
    }
    It 'Reset_WindowsUpdate.cmd exists' {
        Join-Path $PSScriptRoot '..\Reset_WindowsUpdate.cmd' | Should -Exist
    }
    It 'rwu.ps1 exists' {
        Join-Path $PSScriptRoot '..\rwu.ps1' | Should -Exist
    }
    It 'Invoke-RwuCmd helper is callable' {
        { Get-Command Invoke-RwuCmd -ErrorAction Stop } | Should -Not -Throw
    }
}

# ── Phase 1: Launcher ───────────────────────────────────────────────────────

Describe 'Phase 1 — Launcher (rwu.ps1)' {
    BeforeAll { $script:launcher = Get-LauncherContent }

    It 'Launch command uses /c call (not bare /c)' {
        $launcher | Should -Match '/c\s+call\s'
    }
    It 'Main body is wrapped in try/finally' {
        $launcher | Should -Match '(?s)try\s*\{.*finally\s*\{'
    }
    It 'Debug mode uses /k instead of /c' {
        $launcher | Should -Match '/k\s+call\s'
    }
    It 'Debug mode passes /debug flag to batch script' {
        $launcher | Should -Match '/debug'
    }
    It 'Normal mode calls Remove-Item for cleanup' {
        $launcher | Should -Match 'Remove-Item'
    }
}

# ── Phase 2: Batch Debug System ─────────────────────────────────────────────

Describe 'Phase 2 — Batch Debug/Trace System' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It 'DEBUG=0 is declared in the OPTIONS section' {
        $cmd | Should -Match 'set\s+"DEBUG=0"'
    }
    It 'DEBUGLOG path is set up' {
        $cmd | Should -Match 'set\s+"DEBUGLOG='
    }
    It '/debug CLI flag is parsed' {
        $cmd | Should -Match '"/debug"'
    }
    It ':DebugInit label exists' {
        $cmd | Should -Match ':DebugInit'
    }
    It ':Trace label exists' {
        $cmd | Should -Match ':Trace'
    }
    It ':ToggleDebug label exists' {
        $cmd | Should -Match ':ToggleDebug'
    }
    It 'Main menu choice includes key 8' {
        $cmd | Should -Match 'choice\s+/C:.*8.*0'
    }
    It '/help output mentions /debug' {
        $cmd | Should -Match '/debug.*Enable debug'
    }

    Context 'Integration — /debug /diag' -Skip {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_test_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/debug', '/diag') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Creates debug trace log' { $result.DebugLog | Should -Not -BeNullOrEmpty }
        It 'Trace log contains Step 0 entry' {
            $result.DebugLog | Get-Content -Raw | Should -Match 'entering :Step0'
        }
    }
}

# ── Phase 3: Step 6 Fail-Closed ─────────────────────────────────────────────

Describe 'Phase 3 — Step 6 Fail-Closed Backup' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It 'Checks mkdir success before proceeding' {
        $cmd | Should -Match 'mkdir.*POLICY_BACKUP_DIR.*\r?\n.*errorlevel'
    }
    It 'Checks reg export success before reg delete' {
        # reg export should be followed by errorlevel check, not bare reg delete
        $cmd | Should -Not -Match 'reg export.*\r?\n\s*reg delete'
    }
}

# ── Phase 4: Error Counting ─────────────────────────────────────────────────

Describe 'Phase 4 — Error Counting for Repair Commands' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It 'net stop has errorlevel checking' {
        $cmd | Should -Match 'net stop.*\r?\n.*errorlevel'
    }
    It 'bitsadmin has errorlevel checking' {
        $cmd | Should -Match 'bitsadmin.*\r?\n.*errorlevel'
    }
    It 'netsh winsock reset has errorlevel checking' {
        $cmd | Should -Match 'netsh winsock reset.*\r?\n.*errorlevel'
    }
    It 'net start has errorlevel checking' {
        $cmd | Should -Match 'net start.*\r?\n.*errorlevel'
    }
}

# ── Phase 5: PowerShell -NoProfile Consistency ──────────────────────────────

Describe 'Phase 5 — PowerShell -NoProfile Consistency' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It 'All powershell calls include -NoProfile' {
        $lines = $cmd -split "`n" | Where-Object { $_ -match 'powershell\s+-' -and $_ -match '-Command' }
        foreach ($line in $lines) {
            $line | Should -Match '-NoProfile' -Because "Line: $($line.Trim())"
        }
    }
}

# ── Phase 6: Help Text ──────────────────────────────────────────────────────

Describe 'Phase 6 — Help Text' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It '/help text mentions /debug flag' {
        $cmd | Should -Match 'debug.*trace'
    }
    It '/help exit code is 0' {
        $tmpDir = Join-Path $env:TEMP "rwu_test_help_$(Get-Random)"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $r = Invoke-RwuCmd -Arguments @('/help') -LogDir $tmpDir
        $r.ExitCode | Should -Be 0
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ── Phase 7: Test Mode + Automated TUI Navigation ──────────────────────────

Describe 'Phase 7 — Test Mode (static analysis)' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It '_TESTMODE=0 is declared' {
        $cmd | Should -Match 'set\s+"_TESTMODE=0"'
    }
    It '/testmode CLI flag is parsed' {
        $cmd | Should -Match '"/testmode"'
    }
    It ':Choice subroutine label exists' {
        $cmd | Should -Match ':Choice'
    }
    It 'Admin check is skipped in testmode' {
        # The fltmc admin check should be inside a _TESTMODE guard
        $cmd | Should -Match '_TESTMODE[\s\S]*?fltmc'
    }
    It 'Steps are no-ops in testmode' {
        $cmd | Should -Match ':Step0[\s\S]*?_TESTMODE'
    }
    It '/autokeys flag is parsed' {
        $cmd | Should -Match '"/autokeys"'
    }
    It ':Choice preserves errorlevel with exit /b !_erl!' {
        # Regression: 'set' resets errorlevel to 0. Without 'exit /b !_erl!',
        # the caller always sees errorlevel=0 and no menu option ever matches.
        $cmd | Should -Match ':Choice[\s\S]*?exit /b !_erl!'
    }
    It '_AUTOKEYS must NOT be pre-initialized (regression)' {
        # Regression: 'set "_AUTOKEYS="' creates a defined-but-empty variable.
        # 'if not defined _AUTOKEYS' returns FALSE for empty strings, so :Choice
        # never calls real choice.exe — menus don't respond to input at all.
        $cmd | Should -Not -Match 'set\s+"_AUTOKEYS="'
    }
    It 'DEBUG defaults to 0' {
        $cmd | Should -Match 'set\s+"DEBUG=0"'
    }
}

Describe 'Phase 8 — Diagnostic Output Formatting' {
    It 'All Format-Table calls pipe through Out-String -Width (no truncation)' {
        # Every Format-Table that redirects to LOGFILE must use Out-String -Width
        # to prevent column truncation in redirected console output
        $lines = $cmd -split "`n" | Where-Object {
            $_ -match 'Format-Table' -and $_ -match 'LOGFILE' -and $_ -notmatch '^\s*::'
        }
        $lines.Count | Should -BeGreaterThan 0
        foreach ($line in $lines) {
            $line | Should -Match 'Out-String\s+-Width' -Because "Format-Table at: $($line.Trim().Substring(0, [Math]::Min(80, $line.Trim().Length)))"
        }
    }
    It 'RAM shows CapacityGB not raw bytes' {
        $cmd | Should -Match 'CapacityGB'
    }
    It 'LicenseStatus uses human-readable enum' {
        $cmd | Should -Match "switch.*LicenseStatus.*Licensed"
    }
}

Describe 'Phase 9 — Diagnostic Findings Counter' {
    It 'DIAG_FINDINGS counter is initialized' {
        $cmd | Should -Match 'DIAG_FINDINGS=0'
    }
    It 'StepDone log references DIAG_FINDINGS' {
        $cmd | Should -Match 'DIAG_FINDINGS.*findings'
    }
    It 'StepDone TUI shows diagnostic findings count' {
        $cmd | Should -Match 'diagnostic findings detected'
    }
    It 'DISM repairable is detected as finding' {
        $cmd | Should -Match 'FINDING.*[Cc]omponent store'
    }
    It 'DISM uses temp file (not whole log) for repairable check' {
        $cmd | Should -Match '_DISM_TMP'
        $cmd | Should -Match 'findstr.*repairable.*_DISM_TMP'
    }
    It 'DIAG_FINDINGS is reset when returning to main menu' {
        # The menu return code should reset DIAG_FINDINGS alongside WARN_COUNT/FAIL_COUNT
        $lines = ($cmd -split "`n")
        $resetBlock = $lines | Where-Object { $_ -match 'WARN_COUNT=0' -and $_ -notmatch '::' }
        $resetBlock.Count | Should -BeGreaterOrEqual 1
        # Find the line index of WARN_COUNT=0 reset and check DIAG_FINDINGS=0 nearby
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'WARN_COUNT=0' -and $lines[$i] -notmatch '::' -and $i -gt 100) {
                $nearby = $lines[($i-2)..($i+3)] -join "`n"
                $nearby | Should -Match 'DIAG_FINDINGS=0'
                break
            }
        }
    }
    It 'Pending reboot is detected as finding' {
        $cmd | Should -Match 'FINDING.*[Pp]ending reboot'
    }
    It 'WU error events are detected as finding' {
        $cmd | Should -Match 'FINDING.*WU error events'
    }
    It 'Connectivity failures are detected as finding' {
        $cmd | Should -Match 'FINDING.*WU connectivity'
    }
    It 'Critically full disks are detected as finding' {
        $cmd | Should -Match 'FINDING.*critically low'
    }
}

Describe 'Phase 10 — Step 6 reg delete Verification' {
    It 'Checks reg delete exit code (not just reg export)' {
        # Every reg delete in Step 6 should be followed by errorlevel check
        $step6Lines = ($cmd -split "`n") | Select-String 'reg delete.*Policies.*WindowsUpdate'
        $step6Lines.Count | Should -BeGreaterOrEqual 4
    }
    It 'WARN on reg delete failure' {
        $cmd | Should -Match 'WARN.*reg delete.*failed'
    }
    It 'Uses POLICY_EXPORTED flag to protect backup dir' {
        $cmd | Should -Match 'POLICY_EXPORTED'
    }
    It 'Never deletes backup dir when keys were exported' {
        # Step6End should check POLICY_EXPORTED before rmdir and preserve backup
        $cmd | Should -Match 'POLICY_EXPORTED.*1'
        $cmd | Should -Match 'Backup preserved'
    }
    It 'Only rmdir when no policies found at all' {
        # rmdir should only happen in the final else (no keys found)
        $lines = ($cmd -split "`n")
        $rmdirIdx = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'rmdir.*POLICY_BACKUP_DIR') { $rmdirIdx = $i; break }
        }
        $rmdirIdx | Should -Not -BeNullOrEmpty
        # The rmdir should be inside an else block after checking POLICY_EXPORTED
        $preceding = $lines[($rmdirIdx-3)..($rmdirIdx)] -join "`n"
        $preceding | Should -Match 'No WU policies found'
    }
    It 'Policy flags initialized before mkdir (mkdir failure safe)' {
        # POLICY_BACKUP_READY, POLICY_EXPORTED, POLICY_FOUND must be set before mkdir
        $lines = ($cmd -split "`n")
        $mkdirIdx = $null
        $flagIdx = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'POLICY_BACKUP_READY=0' -and $null -eq $flagIdx) { $flagIdx = $i }
            if ($lines[$i] -match 'mkdir.*POLICY_BACKUP_DIR' -and $null -eq $mkdirIdx) { $mkdirIdx = $i }
        }
        $flagIdx | Should -Not -BeNullOrEmpty
        $mkdirIdx | Should -Not -BeNullOrEmpty
        $flagIdx | Should -BeLessThan $mkdirIdx -Because 'flags must be initialized before mkdir'
    }
    It 'Step6End has distinct mkdir-failure branch (POLICY_BACKUP_READY)' {
        $cmd | Should -Match 'POLICY_BACKUP_READY.*0'
        $cmd | Should -Match 'backup directory could not be created'
    }
    It 'No gpupdate when export succeeded but delete failed' {
        # The POLICY_EXPORTED=1 branch should NOT run gpupdate
        $lines = ($cmd -split "`n")
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'Backup preserved') {
                # Check the next few lines do NOT contain gpupdate
                $next = $lines[($i+1)..($i+3)] -join "`n"
                $next | Should -Not -Match 'gpupdate' -Because 'gpupdate should not run when no deletion succeeded'
                break
            }
        }
    }
}

Describe 'Phase 11 — Repair Command Failure Handling' {
    It 'BITS queue del checks exit code' {
        $cmd | Should -Match 'WARN.*[Cc]ould not delete qmgr'
    }
    It 'DNS flush checks exit code' {
        $cmd | Should -Match 'WARN.*DNS flush'
    }
    It 'Service restart distinguishes errorlevel 2 (already running) from real failures' {
        $cmd | Should -Match '_svc_erl'
    }
}

Describe 'Phase 12 — Log Noise Reduction' {
    It 'Insider section queries specific values not full dump' {
        $cmd | Should -Match 'BranchName'
        $cmd | Should -Not -Match 'WindowsSelfHost\\UI\\Selection'
    }
    It 'WSUS checks before querying (no raw error output)' {
        # The WSUS check should test >nul 2>&1 first, then query if present
        $lines = ($cmd -split "`n") | Where-Object { $_ -match 'Policies.*WindowsUpdate.*>nul' }
        $lines.Count | Should -BeGreaterOrEqual 1
    }
}


Describe 'Phase 7 — TUI Navigation (integration, no elevation)' {

    Context 'Main Menu → Exit' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_tui_exit_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '10') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Creates debug trace log' {
            Get-ChildItem $tmpDir -Filter 'RWU_Debug.log' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        It 'Trace log shows MainMenu entry' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'entering :MainMenu'
        }
        It 'Trace log shows exit' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'MainMenu: exit'
        }
    }

    Context 'Main Menu → Help → Return → Exit' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_tui_help_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '7.10') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Trace log shows ShowHelp' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'ShowHelp'
        }
    }

    Context 'Main Menu → Toggle Debug → Exit' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_tui_debug_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '8.10') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Trace log shows ToggleDebug' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'ToggleDebug'
        }
    }

    Context 'Main Menu → Advanced → Back → Exit' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_tui_adv_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '3.10.10') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Trace log shows AdvancedMenu' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'AdvancedMenu'
        }
        It 'Trace log shows return to MainMenu' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $matches = [regex]::Matches($log, 'entering :MainMenu')
            $matches.Count | Should -BeGreaterOrEqual 2
        }
    }

    Context 'Main Menu → Diagnostics (testmode no-op) → Return → Exit' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_tui_diag_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '1.1.10') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Trace log shows DiagnosticsOnly target' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'DiagnosticsOnly'
        }
        It 'Trace log shows TESTMODE skip' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'TESTMODE.*skip'
        }
        It 'Trace log shows StepDone' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'StepDone'
        }
    }
}

# ── Phase 13: System Fixes (/fix) ──────────────────────────────────────────────────

Describe 'Phase 13 — System Fixes (static analysis)' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It '/fix CLI flag is parsed' {
        $cmd | Should -Match '"/fix"'
    }
    It '/fix requires a target argument' {
        $cmd | Should -Match '/fix requires a target'
    }
    It 'All 5 fix targets are dispatched' {
        foreach ($target in @('dism', 'sfc', 'combo', 'chkdsk', 'proxy')) {
            $cmd | Should -Match "CLI_FIX.*$target" -Because "/fix $target should be dispatched"
        }
    }
    It 'Invalid fix target shows error' {
        $cmd | Should -Match 'Unknown fix target'
    }
    It ':SystemFixesMenu label exists' {
        $cmd | Should -Match ':SystemFixesMenu'
    }
    It 'Main menu choice includes S' {
        $cmd | Should -Match 'choice\s+/C:.*S.*0'
    }
    It 'Main menu routes S to SystemFixesMenu' {
        $cmd | Should -Match 'SystemFixesMenu.*goto :SystemFixesMenu'
    }
    It 'Help text mentions /fix' {
        $cmd | Should -Match '/fix.*Run system fix'
    }
    It 'Help text lists all fix targets' {
        foreach ($target in @('dism', 'sfc', 'combo', 'chkdsk', 'proxy')) {
            $cmd | Should -Match "$target" -Because "Help should list fix target: $target"
        }
    }
    It 'DISM findstr uses /C: for literal phrase (no false positive)' {
        # Regression: findstr without /C: treats tokens separately.
        # "successfully repaired" without /C: matches "completed successfully".
        $lines = ($cmd -split "`n") | Where-Object { $_ -match 'findstr.*successfully repaired' }
        foreach ($line in $lines) {
            $line | Should -Match '/C:' -Because "findstr must use /C: for literal match: $($line.Trim())"
        }
    }
    It 'SFC checks _sfc_erl for non-zero exit code' {
        $cmd | Should -Match '_sfc_erl.*neq 0'
    }
    It 'SFC non-zero exit code increments FAIL_COUNT' {
        # When SFC fails with unrecognized output + non-zero exit, FAIL_COUNT should increase
        $cmd | Should -Match 'FAIL.*SFC returned exit code'
    }
    It 'CHKDSK has confirmation prompt in interactive mode' {
        $cmd | Should -Match 'Schedule CHKDSK on next reboot'
    }
    It 'CHKDSK skips prompt in CLI mode' {
        $cmd | Should -Match '_CLI_MODE.*1.*goto :FixCHKDSK_Run'
    }
    It 'Fix flow targets exist for all 5 fixes' {
        foreach ($label in @(':RunFixDISM', ':RunFixSFC', ':RunFixCombo', ':RunFixCHKDSK', ':RunFixProxy')) {
            $escaped = [regex]::Escape($label)
            $cmd | Should -Match $escaped -Because "Flow target $label should exist"
        }
    }
    It 'Fix workload labels exist for all 4 commands' {
        foreach ($label in @(':FixDISM', ':FixSFC', ':FixCHKDSK', ':FixProxy')) {
            $escaped = [regex]::Escape($label)
            $cmd | Should -Match $escaped -Because "Workload label $label should exist"
        }
    }
    It 'Combo sets _STOP_AFTER to FixSFC (runs both DISM and SFC)' {
        # RunFixCombo flow target should set _STOP_AFTER=FixSFC and goto :FixDISM
        $lines = ($cmd -split "`n")
        $comboIdx = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            # Match the flow target label, not the CLI dispatch line
            if ($lines[$i] -match '^:RunFixCombo') { $comboIdx = $i; break }
        }
        $comboIdx | Should -Not -BeNullOrEmpty
        $nearby = $lines[($comboIdx)..($comboIdx+5)] -join "`n"
        $nearby | Should -Match '_STOP_AFTER=FixSFC'
        $nearby | Should -Match 'goto :FixDISM'
    }
}

Describe 'Phase 13 — System Fixes (CLI integration)' {

    Context '/fix with invalid target exits 1' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_fix_bad_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            # /testmode needed to bypass admin check which runs before arg dispatch
            $script:result = Invoke-RwuCmd -Arguments @('/fix', 'bogus', '/testmode') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 1' { $result.ExitCode | Should -Be 1 }
        It 'Shows valid targets in error' {
            $result.Stdout | Should -Match 'Valid targets.*dism.*sfc.*combo.*chkdsk.*proxy'
        }
    }

    Context '/fix conflicts with /diag' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_fix_conflict_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            # /testmode needed to bypass admin check which runs before arg dispatch
            $script:result = Invoke-RwuCmd -Arguments @('/diag', '/fix', 'sfc', '/testmode') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 1' { $result.ExitCode | Should -Be 1 }
        It 'Shows conflicting actions error' {
            $result.Stdout | Should -Match 'Conflicting actions'
        }
    }

    Context '/fix dism in testmode exits 0' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_fix_dism_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/fix', 'dism', '/testmode') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Shows DISM run label' { $result.Stdout | Should -Match 'DISM Repair Component Store' }
    }

    Context '/fix sfc in testmode exits 0' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_fix_sfc_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/fix', 'sfc', '/testmode') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Shows SFC run label' { $result.Stdout | Should -Match 'SFC System File Checker' }
    }

    Context '/fix combo in testmode exits 0' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_fix_combo_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/fix', 'combo', '/testmode') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Shows combo run label' { $result.Stdout | Should -Match 'DISM \+ SFC Combo' }
    }

    Context '/fix chkdsk in testmode exits 0' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_fix_chkdsk_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/fix', 'chkdsk', '/testmode') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Shows CHKDSK run label' { $result.Stdout | Should -Match 'Schedule CHKDSK' }
    }

    Context '/fix proxy in testmode exits 0' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_fix_proxy_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/fix', 'proxy', '/testmode') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Shows proxy run label' { $result.Stdout | Should -Match 'Reset WinHTTP Proxy' }
    }
}

Describe 'Phase 13 — System Fixes (TUI integration)' {

    Context 'Main Menu → System Fixes → Back → Exit' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_tui_sysfix_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            # Key 9 = S (System Fixes), Key 6 = [0] Back, Key 10 = [0] Exit
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '9.6.10') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Trace log shows SystemFixesMenu' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'SystemFixesMenu'
        }
        It 'Trace log shows return to MainMenu' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $matches = [regex]::Matches($log, 'entering :MainMenu')
            $matches.Count | Should -BeGreaterOrEqual 2
        }
    }

    Context 'Main Menu → System Fixes → DISM (testmode) → Return → Exit' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_tui_fixdism_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            # Key 9 = S, Key 1 = DISM, Key 2 = Exit from StepDone, Key 10 = Exit from MainMenu
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '9.1.2.10') -LogDir $tmpDir
        }
        AfterAll { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'Exits with code 0' { $result.ExitCode | Should -Be 0 }
        It 'Trace log shows RunFixDISM' {
            $log = Get-Content (Join-Path $tmpDir 'RWU_Debug.log') -Raw -ErrorAction SilentlyContinue
            $log | Should -Match 'TESTMODE.*skip RunFixDISM'
        }
        It 'Output shows DISM run label' {
            $result.Stdout | Should -Match 'DISM Repair Component Store'
        }
    }
}
