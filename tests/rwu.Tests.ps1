#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.4.0' }
<#
    RWU — Pester 5 test suite
    Organised by implementation phase so tests can be written before code (TDD).
    Run:  pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.4.0; Invoke-Pester tests/ -Output Detailed"
#>

# ── Shared Helpers (loaded once at discovery time) ───────────────────────────
# Pester 5 scoping: BeforeAll at file level runs before any Describe block.

BeforeAll {
    . (Join-Path $PSScriptRoot 'support\RwuBlockHarness.ps1')

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

AfterAll { Remove-RwuStubs }

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

    It 'netsh winsock reset has errorlevel checking' {
        $cmd | Should -Match 'netsh winsock reset.*\r?\n.*errorlevel'
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
            # Key 7 = Help, Key 2 = [M]ain Menu from help page 1, Key 10 = Exit
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '7.2.10') -LogDir $tmpDir
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

Describe 'Phase 14 — ASCII-only Shipped Scripts (encoding regression)' {
    # Regression: a UTF-8 em-dash (E2 80 94) in an echo line rendered as
    # "ΓÇö" in cmd.exe (OEM code page 437). BOM-less .ps1 files are also
    # decoded as ANSI by Windows PowerShell 5.1. Shipped scripts must be
    # pure 7-bit ASCII so they render identically on every code page.
    It '<File> contains only 7-bit ASCII bytes' -TestCases @(
        @{ File = 'Reset_WindowsUpdate.cmd' }
        @{ File = 'rwu.ps1' }
        @{ File = 'bump.ps1' }
    ) {
        param($File)
        $path  = Join-Path $PSScriptRoot "..\$File"
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bad   = @()
        $line  = 1
        foreach ($b in $bytes) {
            if ($b -eq 0x0A) { $line++ }
            elseif ($b -gt 0x7F -and $bad -notcontains $line) { $bad += $line }
        }
        $bad | Should -BeNullOrEmpty -Because "non-ASCII bytes found on line(s): $($bad -join ', ')"
    }
    It '<File> has CRLF on every line' -TestCases @(
        @{ File = 'Reset_WindowsUpdate.cmd' }
        @{ File = 'rwu.ps1' }
        @{ File = 'bump.ps1' }
    ) {
        $text = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\$File"))
        [regex]::Matches($text, '(?<!\r)\n|\r(?!\n)').Count | Should -Be 0
        $text.EndsWith("`r`n") | Should -BeTrue
    }
    It 'Reset_WindowsUpdate.cmd has no UTF-8 BOM (cmd.exe would fail on line 1)' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\Reset_WindowsUpdate.cmd'))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
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

# ── Phase 15: Block Harness ─────────────────────────────────────────────────

Describe 'Phase 15 — Block Harness and Gated Runner' {
    BeforeAll {
        $script:runner = Join-Path $PSScriptRoot 'support\Invoke-RwuPester.ps1'
    }
    It 'Every stubbed tool resolves to the stub directory under the child PATH' {
        $dir = Initialize-RwuStubs
        $out = Assert-RwuPreflight -StubDir $dir -ChildPath $dir -Cwd $TestDrive
        foreach ($t in 'sc', 'net', 'reg', 'bitsadmin', 'regsvr32', 'ping', 'fltmc') {
            $out | Should -Match ([regex]::Escape("$t.exe=$dir\$t.exe"))
        }
    }
    It 'A block that calls a stubbed tool is recorded and never reaches the real tool' {
        $r = Invoke-RwuBlock -Entry 'net stop RwuNoSuchService', 'sc query RwuNoSuchService' -Scenario @{ 'state.RwuNoSuchService' = '4' }
        $r.Calls | Should -Be @('net stop RwuNoSuchService', 'sc query RwuNoSuchService')
        $r.Output | Should -Match ': 1  STOPPED'
    }
    It 'With one stub removed the preflight throws and the call log stays empty' {
        $bad = Join-Path $TestDrive 'stubs'
        Copy-Item (Initialize-RwuStubs) $bad -Recurse
        Remove-Item (Join-Path $bad 'net.exe')
        { Invoke-RwuBlock -StubDir $bad -Entry 'sc query x' } | Should -Throw '*net.exe*calls=<>*'
    }
    It 'A tool that is not stubbed is "not recognized", not the real one' {
        (Invoke-RwuBlock -Entry 'whoami').Output | Should -Match 'not recognized'
    }
    It 'Runner exits 1 for a pattern that matches nothing' {
        & pwsh -NoProfile -File $runner -FullName 'no-such-phase' -MinTests 1 *> $null
        $LASTEXITCODE | Should -Be 1
    }
    It 'Runner exit code for <Name> is <Code>' -TestCases @(
        @{ Name = 'a passing file'; Body = "Describe 'x' { It 'a' { 1 | Should -Be 1 } }"; Code = 0 }
        @{ Name = 'too few tests'; Body = "Describe 'x' { }"; Code = 1 }
        @{ Name = 'a failing test'; Body = "Describe 'x' { It 'a' { 1 | Should -Be 1 }; It 'b' { 1 | Should -Be 2 } }"; Code = 1 }
        @{ Name = 'a skipped test'; Body = "Describe 'x' { It 'a' { 1 | Should -Be 1 }; It 'b' -Skip { } }"; Code = 1 }
        @{ Name = 'a failing block'; Body = "Describe 'x' { It 'a' { 1 | Should -Be 1 }; Context 'y' { AfterAll { throw 'z' }; It 'b' { } } }"; Code = 1 }
        @{ Name = 'a broken container'; Body = "Describe 'x' { It 'a' { 1 | Should -Be 1 } }; throw 'boom'"; Code = 1 }
    ) {
        $f = Join-Path $TestDrive "$(Get-Random).Tests.ps1"
        Set-Content $f $Body
        & pwsh -NoProfile -File $runner -FullName '*' -MinTests 1 -Path $f *> $null
        $LASTEXITCODE | Should -Be $Code
    }
}

# ── Phase 16: Services ──────────────────────────────────────────────────────

Describe 'Phase 16 — Service Stop and Start' {
    BeforeAll {
        function Get-Stopped($r) { @("$($r.Vars['_STOPPED_BY_RUN'])".Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) }
        function Get-NetCalls($r, $verb) { @($r.Calls | Where-Object { $_ -like "net $verb *" }) }
        $script:allRunning = @{}
        foreach ($s in 'wuauserv', 'UsoSvc', 'DoSvc', 'cryptSvc', 'bits', 'msiserver', 'appidsvc', 'TrustedInstaller') {
            $allRunning["state.$s"] = '4'
        }
    }

    Context 'SvcState and SvcStart' {
        It 'SvcState maps <Name> to <Want>' -TestCases @(
            @{ Name = 'a running service'; S = @{ 'state.bits' = '4' }; Want = '4' }
            @{ Name = 'a non-English state label'; S = @{ 'state.bits' = '4'; 'label.state' = 'ESTADO' }; Want = '4' }
            @{ Name = 'exit 1060'; S = @{ 'state.bits' = '0' }; Want = '0' }
            @{ Name = 'exit 5'; S = @{ 'state.bits' = 'U' }; Want = 'U' }
            @{ Name = 'unparsable output'; S = @{ 'state.bits' = 'X' }; Want = 'U' }
            @{ Name = 'a stopped service with WIN32_EXIT_CODE 5'; S = @{ 'state.bits' = '1'; 'winexit.bits' = '5  (0x5)' }; Want = '1' }
        ) {
            (Invoke-RwuBlock -Entry 'call :SvcState bits' -Scenario $S).Vars['_SVC_STATE'] | Should -BeExactly $Want
        }
        It 'SvcStart maps Start <Reg> to <Want>' -TestCases @(
            @{ Reg = '4'; Want = '4' }
            @{ Reg = '2'; Want = '2' }
            @{ Reg = ''; Want = 'U' }
        ) {
            (Invoke-RwuBlock -Entry 'call :SvcStart bits' -Scenario @{ 'start.bits' = $Reg }).Vars['_SVC_START'] | Should -BeExactly $Want
        }
    }

    Context 'Step 2 stop' {
        It 'net stop exit 2 with wuauserv still running is a warning' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario @{ 'state.wuauserv' = '4'; 'netstop.wuauserv' = 2 }
            $r.Vars.WARN_COUNT | Should -Be 1
            $r.Log | Should -Match 'WARN: wuauserv did not stop'
        }
        It 'a protected service that refuses the stop is INFO (<_>)' -ForEach 'DoSvc', 'appidsvc' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario @{ "state.$_" = '4'; "netstop.$_" = 2 }
            $r.Vars.WARN_COUNT | Should -Be 0
            $r.Log | Should -Match "INFO: $_ is protected"
        }
        It 'a stop that never leaves STOP_PENDING is a warning after five polls' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario @{ 'state.bits' = '4'; 'netstop.bits.sets' = 'bits:3' }
            $r.Vars.WARN_COUNT | Should -Be 1
            @($r.Calls | Where-Object { $_ -eq 'ping -n 2 127.0.0.1' }).Count | Should -Be 5
        }
        It 'a stop that settles while polling is not a warning' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario @{ 'state.bits' = '4'; 'netstop.bits.sets' = 'bits:3,3,3,3,1' }
            $r.Vars.WARN_COUNT | Should -Be 0
            Get-Stopped $r | Should -Be @('bits')
        }
        It 'an unknown state is a warning' {
            (Invoke-RwuBlock -Steps Step2 -Scenario @{ 'state.bits' = 'U' ; 'netstop.bits.sets' = 'bits:U' }).Vars.WARN_COUNT | Should -Be 1
        }
        It 'a missing or stopped service gets no net stop and no warning' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario @{ 'state.bits' = '0' }
            $r.Vars.WARN_COUNT | Should -Be 0
            Get-NetCalls $r stop | Should -HaveCount 0
            $r.Log | Should -Match 'INFO: bits is not installed'
            $r.Log | Should -Match 'INFO: wuauserv already stopped'
        }
        It 'all running services are stopped in STOP_ORDER' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario $allRunning
            Get-NetCalls $r stop | Should -Be @('wuauserv', 'UsoSvc', 'DoSvc', 'cryptSvc', 'bits', 'msiserver', 'appidsvc', 'TrustedInstaller' |
                    ForEach-Object { "net stop $_ /y" })
            (Get-Stopped $r).Count | Should -Be 8
            $r.Vars.WARN_COUNT | Should -Be 0
        }
        It 'a dependant stopped by cryptSvc is in the set, and gets no second stop' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario @{
                'state.cryptSvc' = '4'; 'state.appidsvc' = '4'; 'netstop.cryptSvc.sets' = 'cryptSvc:1;appidsvc:1'
            }
            Get-Stopped $r | Should -Be @('cryptSvc', 'appidsvc')
            Get-NetCalls $r stop | Should -Be @('net stop cryptSvc /y')
        }
        It 'a service that was already stopped, or did not stop, is not in the set' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario @{ 'state.bits' = '4'; 'state.DoSvc' = '4'; 'netstop.DoSvc' = 2 }
            Get-Stopped $r | Should -Be @('bits')
        }
        It 'a second run in the same process keeps the set and adds nothing twice' {
            $r = Invoke-RwuBlock -Steps Step2 -Scenario @{ 'state.bits' = '4' } -Vars @{ _STOPPED_BY_RUN = ' bits msiserver ' }
            Get-Stopped $r | Should -Be @('bits', 'msiserver')
        }
    }

    Context 'Step 11 start' {
        It 'starts the core services in order and no on-demand service' {
            $r = Invoke-RwuBlock -Steps Step11 -Scenario @{ 'start.appidsvc' = 3 }
            Get-NetCalls $r start | Should -Be @('cryptSvc', 'bits', 'DoSvc', 'UsoSvc', 'wuauserv' | ForEach-Object { "net start $_" })
            $r.Vars.WARN_COUNT | Should -Be 0
        }
        It 'starts appidsvc when its Start is 2' {
            Get-NetCalls (Invoke-RwuBlock -Steps Step11 -Scenario @{ 'start.appidsvc' = 2 }) start | Should -Contain 'net start appidsvc'
        }
        It 'starts exactly the on-demand services that this run stopped, and empties the set' {
            $r = Invoke-RwuBlock -Steps Step11 -Vars @{ _STOPPED_BY_RUN = ' wuauserv msiserver TrustedInstaller ' }
            @(Get-NetCalls $r start)[5..9] | Should -Be @('net start msiserver', 'net start TrustedInstaller')
            Get-Stopped $r | Should -HaveCount 0
        }
        It 'issues no net start when everything runs' {
            $r = Invoke-RwuBlock -Steps Step11 -Scenario ($allRunning + @{ 'start.appidsvc' = 2 })
            Get-NetCalls $r start | Should -HaveCount 0
            $r.Log | Should -Match 'INFO: bits already running'
        }
        It 'a service that is not installed is INFO' {
            $r = Invoke-RwuBlock -Steps Step11 -Scenario @{ 'state.UsoSvc' = '0' }
            $r.Vars.WARN_COUNT | Should -Be 0
            $r.Log | Should -Match 'INFO: UsoSvc is not installed'
        }
        It 'net start exit 2 with the service stopped is a warning' {
            (Invoke-RwuBlock -Steps Step11 -Scenario @{ 'netstart.bits' = 2 }).Vars.WARN_COUNT | Should -Be 1
        }
        It 'net start exit 2 with the service running is not a warning' {
            (Invoke-RwuBlock -Steps Step11 -Scenario @{ 'netstart.bits' = 2; 'netstart.bits.sets' = 'bits:4' }).Vars.WARN_COUNT | Should -Be 0
        }
        It 'START_PENDING then RUNNING is OK' {
            $r = Invoke-RwuBlock -Steps Step11 -Scenario @{ 'netstart.bits.sets' = 'bits:2,2,2,2,4' }
            $r.Vars.WARN_COUNT | Should -Be 0
            $r.Log | Should -Match 'OK: bits is running'
        }
        It 'the set from Step 2 drives Step 11' {
            $r = Invoke-RwuBlock -Steps Step2, Step11 -Scenario @{ 'state.msiserver' = '4' }
            Get-NetCalls $r start | Should -Contain 'net start msiserver'
            Get-NetCalls $r start | Should -Not -Contain 'net start TrustedInstaller'
        }
    }

    Context 'Disabled services' {
        It 'Step 11 warns with 0x80070422 for <_>, tries nothing and changes nothing' -ForEach 'wuauserv', 'bits', 'cryptSvc', 'UsoSvc' {
            $r = Invoke-RwuBlock -Steps Step11 -Scenario @{ "start.$_" = 4 }
            $r.Vars.WARN_COUNT | Should -Be 1
            $r.Log | Should -Match '0x80070422'
            $r.Log | Should -Match "sc config $_ start="
            Get-NetCalls $r start | Should -Not -Contain "net start $_"
            $r.Calls | Where-Object { $_ -like 'sc config*' } | Should -BeNullOrEmpty
        }
        It 'a disabled DoSvc is INFO only' {
            $r = Invoke-RwuBlock -Steps Step11 -Scenario @{ 'start.DoSvc' = 4 }
            $r.Vars.WARN_COUNT | Should -Be 0
            $r.Log | Should -Match 'INFO: DoSvc is disabled'
            Get-NetCalls $r start | Should -Not -Contain 'net start DoSvc'
        }
        It 'a service without a Start value is not treated as disabled' {
            Get-NetCalls (Invoke-RwuBlock -Steps Step11) start | Should -Contain 'net start wuauserv'
        }
        It 'Step 1 records a FINDING for each disabled member of the check list only' {
            $r = Invoke-RwuBlock -Steps Step1 -Vars @{ _STOP_AFTER = 'Step1' } -Scenario @{
                'start.wuauserv' = 4; 'start.UsoSvc' = 4; 'start.DoSvc' = 4; 'start.bits' = 3
            }
            $r.Vars.DIAG_FINDINGS | Should -Be 2
            $r.Log | Should -Match 'FINDING: wuauserv is disabled'
            $r.Log | Should -Not -Match 'FINDING: DoSvc'
        }
    }

    It '<_> logs numeric state and start on a non-English system' -ForEach 'Step1', 'Step12' {
        $r = Invoke-RwuBlock -Steps $_ -Vars @{ _STOP_AFTER = $_ } -Scenario @{
            'state.bits' = '4'; 'label.state' = 'ESTADO'; 'start.bits' = 3; 'state.msiserver' = '0'
        }
        $r.Log | Should -Match 'bits: state=4 start=3'
        $r.Log | Should -Match 'msiserver: state=0 start=U'
    }
}

# ── Phase 17: BITS ──────────────────────────────────────────────────────────

Describe 'Phase 17 — BITS Queue Reset' {
    BeforeAll {
        function Get-BitsCalls($r) { @($r.Calls | Where-Object { $_ -like 'bitsadmin*' }) }
    }
    It 'Step 5 in the full flow defers the reset and makes no bitsadmin call' {
        $r = Invoke-RwuBlock -Steps Step5
        Get-BitsCalls $r | Should -HaveCount 0
        $r.Vars._BITS_RESET_PENDING | Should -Be 1
        $r.Log | Should -Match 'deferred'
    }
    It '/step 5 calls bitsadmin once, even after a full reset in the same process' {
        $r = Invoke-RwuBlock -Steps Step5 -Vars @{ _FULLRESET = 1; _STOP_AFTER = 'Step5' }
        Get-BitsCalls $r | Should -Be @('bitsadmin /reset /allusers')
        $r.Vars._BITS_RESET_PENDING | Should -Be 0
        $r.Vars.WARN_COUNT | Should -Be 0
    }
    It '/step 5 warns when bitsadmin fails' {
        (Invoke-RwuBlock -Steps Step5 -Vars @{ _STOP_AFTER = 'Step5' } -Scenario @{ 'exit.bitsadmin' = 1 }).Vars.WARN_COUNT | Should -Be 1
    }
    It 'The deferred reset runs once in Step 11, after net start bits' {
        $r = Invoke-RwuBlock -Steps Step5, Step11
        Get-BitsCalls $r | Should -HaveCount 1
        $r.Calls.IndexOf('bitsadmin /reset /allusers') | Should -BeGreaterThan $r.Calls.IndexOf('net start bits')
        $r.Vars._BITS_RESET_PENDING | Should -Be 0
        $r.Vars.WARN_COUNT | Should -Be 0
    }
    It 'Step 11 resets a queue whose service already runs' {
        Get-BitsCalls (Invoke-RwuBlock -Steps Step11 -Vars @{ _BITS_RESET_PENDING = 1 } -Scenario @{ 'state.bits' = '4' }) | Should -HaveCount 1
    }
    It 'Step 11 without the flag (/step finalize) never calls bitsadmin' {
        Get-BitsCalls (Invoke-RwuBlock -Steps Step11) | Should -HaveCount 0
    }
    It 'When bits does not start there is no call, one more warning, and the flag is cleared' {
        $r = Invoke-RwuBlock -Steps Step11 -Vars @{ _BITS_RESET_PENDING = 1 } -Scenario @{ 'netstart.bits' = 1 }
        Get-BitsCalls $r | Should -HaveCount 0
        $r.Vars.WARN_COUNT | Should -Be 2
        $r.Log | Should -Match 'WARN: BITS queue not reset'
        $r.Vars._BITS_RESET_PENDING | Should -Be 0
    }
    It 'A failing deferred bitsadmin is a warning' {
        (Invoke-RwuBlock -Steps Step11 -Vars @{ _BITS_RESET_PENDING = 1 } -Scenario @{ 'exit.bitsadmin' = 1 }).Vars.WARN_COUNT | Should -Be 1
    }
    It ':FullReset clears a stale flag' {
        # testmode, so the entry sets its variables and stops
        (Invoke-RwuBlock -Entry 'goto :FullReset' -Vars @{ _BITS_RESET_PENDING = 1; _TESTMODE = 1 }).Vars._BITS_RESET_PENDING | Should -Be 0
    }
}

# ── Phase 18: DLL registration ──────────────────────────────────────────────

Describe 'Phase 18 — DLL Registration' {
    BeforeAll {
        $block = Get-RwuLabelBlock -Lines ((Get-RwuScriptText) -split '\r?\n') -Label Step8
        $script:dlls = @([regex]::Matches(($block -join "`n"), '\b\w+\.dll\b').Value | Select-Object -Unique)
    }
    It 'All 36 DLLs are offered to regsvr32' {
        $r = Invoke-RwuBlock -Steps Step8 -Dll $dlls
        $dlls.Count | Should -Be 36
        $r.Calls.Count | Should -Be 36
        $r.Vars.DLL_OK | Should -Be 36
        $r.Vars.WARN_COUNT | Should -Be 0
    }
    It 'regsvr32 exit <Code> counts as <Counter>, warnings <Warn>' -TestCases @(
        @{ Code = 0; Counter = 'DLL_OK'; Warn = 0; Text = '' }
        @{ Code = 1; Counter = 'DLL_FAIL'; Warn = 1; Text = 'FAIL: .*atl\.dll' }
        @{ Code = 2; Counter = 'DLL_FAIL'; Warn = 1; Text = 'FAIL: .*atl\.dll' }
        @{ Code = 3; Counter = 'DLL_FAIL'; Warn = 1; Text = 'FAIL: .*atl\.dll' }
        @{ Code = 4; Counter = 'DLL_SKIP'; Warn = 0; Text = 'SKIP: atl\.dll' }
        @{ Code = 5; Counter = 'DLL_INFO'; Warn = 0; Text = 'INFO: .*atl\.dll' }
        @{ Code = 9; Counter = 'DLL_FAIL'; Warn = 1; Text = 'FAIL: .*atl\.dll' }
        @{ Code = -1; Counter = 'DLL_FAIL'; Warn = 1; Text = 'FAIL: .*atl\.dll' }
    ) {
        $r = Invoke-RwuBlock -Steps Step8 -Dll atl.dll -Scenario @{ 'regsvr32.atl.dll' = $Code }
        $want = @{ DLL_OK = 0; DLL_SKIP = 35; DLL_INFO = 0; DLL_FAIL = 0 }   # 35 files are absent
        $want[$Counter]++
        foreach ($k in $want.Keys) { $r.Vars[$k] | Should -Be $want[$k] -Because $k }
        $r.Vars.WARN_COUNT | Should -Be $Warn
        $r.Log | Should -Match $Text
        $r.Log | Should -Match "DLL Summary: $($want.DLL_OK) registered, $($want.DLL_SKIP) skipped, $($want.DLL_INFO) informational, $($want.DLL_FAIL) failed"
    }
    It 'The current directory is restored with _STOP_AFTER=<_>' -ForEach 'Step8', 'Step14' {
        $r = Invoke-RwuBlock -Steps Step8 -Vars @{ _STOP_AFTER = $_ }
        $r.Cwd | Should -Be $r.Work
    }
    It 'A relative log written after Step 8 lands beside the earlier file' {
        $r = Invoke-RwuBlock -Steps Step8, Step12 -Dll $dlls -Vars @{ LOGFILE = 'log.txt' }
        $r.LogFiles | Should -Be @('work\log.txt')
        $r.Log | Should -Match '\[STEP 12\]'
    }
}

# ── Phase 19: Log paths ─────────────────────────────────────────────────────

Describe 'Phase 19 — Log Paths' {
    BeforeAll {
        $script:shipped = (Resolve-Path (Join-Path $PSScriptRoot '..\Reset_WindowsUpdate.cmd')).Path
        # The real script in test mode: no workload, no elevation.
        function Invoke-TestMode([string]$Arguments, [string]$Cwd, [hashtable]$Env = @{}) {
            Invoke-RwuProcess -CommandLine "`"$shipped`" /testmode $Arguments" -Cwd $Cwd -Env $Env
        }
    }

    Context '/logdir' {
        It '/logdir <Arg> gives absolute log paths that survive a directory change' -TestCases @(
            @{ Arg = '.'; Sub = '' }
            @{ Arg = '.\logs'; Sub = '\logs' }
            @{ Arg = 'logs\'; Sub = '\logs' }
            @{ Arg = '"logs\"'; Sub = '\logs' }
        ) {
            $r = Invoke-RwuBlock -Vars @{ _TESTMODE = 1; LOGFILE = 'unset'; DEBUGLOG = 'unset' } -Entry 'md logs',
            "call :ParseArgs /diag /logdir $Arg", 'cd /d "%windir%"', 'echo AFTER>>"!LOGFILE!"', 'echo AFTER>>"!DEBUGLOG!"'
            $r.Vars.LOGFILE | Should -Be "$($r.Work)$Sub\WU_Reset_Log.txt"
            $r.Vars.DEBUGLOG | Should -Be "$($r.Work)$Sub\RWU_Debug.log"
            $r.LogFiles | Should -Be @("work$Sub\WU_Reset_Log.txt")
        }
        It '/logdir <_> gives logs in the drive root' -ForEach 'C:\', '"C:\"' {
            $r = Invoke-RwuBlock -Vars @{ _TESTMODE = 1 } -Entry "call :ParseArgs /diag /logdir $_"
            $r.Vars.LOGFILE | Should -Be 'C:\WU_Reset_Log.txt'
            $r.Vars.DEBUGLOG | Should -Be 'C:\RWU_Debug.log'
        }
        It '/logdir .\logs on the shipped script writes both logs there' {
            $w = New-Item -ItemType Directory (Join-Path $TestDrive 'w1\logs') -Force
            (Invoke-TestMode '/debug /diag /logdir .\logs' -Cwd $w.Parent.FullName).ExitCode | Should -Be 0
            (Get-ChildItem $w).Name | Sort-Object | Should -Be @('RWU_Debug.log', 'WU_Reset_Log.txt')
        }
        It '/logdir with <Name> exits 1 with an error' -TestCases @(
            @{ Name = 'a missing folder'; Arg = '/diag /logdir nope'; Text = 'does not exist' }
            @{ Name = 'a wildcard'; Arg = '/diag /logdir "we*"'; Text = 'does not exist' }
            @{ Name = 'a file'; Arg = '/diag /logdir file.txt'; Text = 'does not exist' }
            @{ Name = 'no value'; Arg = '/diag /logdir'; Text = 'requires a path' }
            @{ Name = 'a path with !'; Arg = '/diag /logdir "we!rd"'; Text = "cannot contain '!'" }
            @{ Name = 'a path with two !'; Arg = '/diag /logdir "a!b!c"'; Text = "cannot contain '!'" }
        ) {
            $w = (New-Item -ItemType Directory (Join-Path $TestDrive "w_$(Get-Random)")).FullName
            # werd, ac: what the mangled names would hit
            foreach ($d in 'we!rd', 'werd', 'a!b!c', 'ac') { [void](New-Item -ItemType Directory (Join-Path $w $d)) }
            Set-Content (Join-Path $w 'file.txt') 'x'
            $r = Invoke-TestMode $Arg -Cwd $w
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'ERROR'
            $r.Output | Should -Match ([regex]::Escape($Text))
            @(Get-ChildItem $w -Recurse -File).Count | Should -Be 1
        }
        It 'A value after /logdir is not lost, and later options still work' {
            $w = New-Item -ItemType Directory (Join-Path $TestDrive 'a & b (c)') -Force
            (Invoke-TestMode "/logdir `"$($w.FullName)`" /debug /diag" -Cwd $TestDrive).ExitCode | Should -Be 0
            Join-Path $w.FullName 'RWU_Debug.log' | Should -Exist
        }
    }

    Context 'Change Log Output Folder' {
        BeforeAll {
            function Invoke-ChangeFolder([string[]]$Typed) {
                $f = Join-Path $TestDrive "in_$(Get-Random).txt"
                [IO.File]::WriteAllText($f, ($Typed -join "`r`n") + "`r`n")
                Invoke-RwuBlock -Vars @{ LOGFILE = 'unset'; DEBUGLOG = 'unset' } -Entry 'md logs', "call :ChangeLogFolder < `"$f`""
            }
        }
        It 'Typed <Typed> sets both variables' -TestCases @(
            @{ Typed = '.\logs'; Want = '<work>\logs' }
            @{ Typed = '"logs\"'; Want = '<work>\logs' }
            @{ Typed = 'C:\'; Want = 'C:' }
        ) {
            $r = Invoke-ChangeFolder $Typed
            $Want = $Want.Replace('<work>', $r.Work)
            $r.Vars.LOGFILE | Should -Be "$Want\WU_Reset_Log.txt"
            $r.Vars.DEBUGLOG | Should -Be "$Want\RWU_Debug.log"
            $r.Output | Should -Match 'HARNESS-GOTO MainMenu'
        }
        It 'Typed <Typed> re-prompts and changes nothing' -TestCases @(
            @{ Typed = 'we!rd'; Text = "cannot contain '!'" }
            @{ Typed = 'nope'; Text = 'does not exist' }
        ) {
            # pause takes one character (x) from the redirected input
            $r = Invoke-ChangeFolder $Typed, 'x0'
            $r.Output | Should -Match ([regex]::Escape($Text))
            ([regex]::Matches($r.Output, 'New folder path')).Count | Should -BeGreaterThan 1
            $r.Vars.LOGFILE | Should -Be 'unset'
            $r.Vars.DEBUGLOG | Should -Be 'unset'
        }
    }

    Context '! in the profile path' {
        BeforeAll {
            $script:bang = Join-Path $TestDrive 'pro!file'
            $script:plain = Join-Path $TestDrive 'profile'
            [void](New-Item -ItemType Directory "$bang\Desktop", "$plain\Desktop" -Force)
            # Everything above :ParseArgs, with markers for the labels it can reach.
            function Invoke-Startup([string]$Arguments, [int]$Fltmc, [string]$Text = (Get-RwuScriptText)) {
                $top = ($Text -replace '(?s)\r?\n:ParseArgs\s.*$', '') -split '\r?\n'
                $top += ':ParseArgs', 'echo REACHED', 'set LOGFILE', 'set DEBUGLOG', 'exit /b 0', ':ShowHelp', 'echo HELP', 'exit /b 0',
                ':MainMenu', 'echo MENU', 'exit /b 0', ':Trace', ':DebugInit', 'exit /b 0'
                $d = Join-Path $TestDrive "st_$(Get-Random)"
                [void](New-Item -ItemType Directory $d)
                [IO.File]::WriteAllText("$d\st.cmd", ($top -join "`r`n") + "`r`n")
                [IO.File]::WriteAllText("$d\scen.txt", "exit.fltmc=$Fltmc`n")
                $stub = Initialize-RwuStubs
                [void](Assert-RwuPreflight -StubDir $stub -ChildPath $stub -Cwd $d)
                Invoke-RwuProcess -CommandLine "`"$d\st.cmd`" $Arguments" -Cwd $d -Env @{
                    PATH = $stub; USERPROFILE = $bang; RWU_STUB_LOG = "$d\calls.txt"; RWU_STUB_SCENARIO = "$d\scen.txt"
                }
            }
            # STARTUP_ORDER mutant: expansion enabled only after the admin guard.
            $t = Get-RwuScriptText
            $script:late = $t.Replace("setlocal EnableDelayedExpansion`r`n", '').Replace(":: Generate timestamp for backups", "setlocal EnableDelayedExpansion`r`n:: Generate timestamp for backups")
        }
        It 'Elevated start continues with the right log paths' {
            $r = Invoke-Startup '/diag' 0
            $r.Output | Should -Match 'REACHED'
            $r.Output | Should -Match ([regex]::Escape("LOGFILE=$bang\Desktop\WU_Reset_Log.txt"))
            $r.Output | Should -Match ([regex]::Escape("DEBUGLOG=$bang\Desktop\RWU_Debug.log"))
        }
        It 'Not elevated: admin error, exit 1' {
            $r = Invoke-Startup '/diag' 1
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'must be run as Administrator'
            $r.Output | Should -Not -Match 'REACHED'
        }
        It 'Not elevated with /testmode continues' {
            (Invoke-Startup '/testmode' 1).Output | Should -Match 'REACHED'
        }
        It 'Not elevated with /help shows help, exit 0' {
            $r = Invoke-Startup '/help' 1
            $r.Output | Should -Match 'HELP'
            $r.ExitCode | Should -Be 0
        }
        It 'Not elevated without arguments: error, and an empty stdin cannot hang' {
            (Invoke-Startup '' 1).ExitCode | Should -Be 1
        }
        It 'A mutant that enables expansion after the guard fails for <Arg>, fltmc <Fltmc>' -TestCases @(
            @{ Arg = '/diag'; Fltmc = 0 }
            @{ Arg = '/testmode'; Fltmc = 1 }
        ) {
            $r = Invoke-Startup $Arg $Fltmc -Text $late
            $r.Output | Should -Not -Match 'REACHED'
            $r.Output | Should -Match 'must be run as Administrator'
        }
        It '/testmode /debug /diag writes the logs in that profile, not in the mangled one' {
            (Invoke-TestMode '/debug /diag' -Cwd $TestDrive -Env @{ USERPROFILE = $bang }).ExitCode | Should -Be 0
            (Get-ChildItem "$bang\Desktop").Name | Sort-Object | Should -Be @('RWU_Debug.log', 'WU_Reset_Log.txt')
            Get-ChildItem $plain -Recurse -File | Should -BeNullOrEmpty
        }
        It 'A logging block writes there, also from a pipe' {
            $log = "$bang\Desktop\block.txt"
            [void](Invoke-RwuBlock -Steps Step1 -Vars @{ LOGFILE = $log; _STOP_AFTER = 'Step1' })
            $log | Should -Exist
            $c = Get-Content $log -Raw
            $c | Should -Match 'START_TYPE\s+: 3'
            $c | Should -Match 'state=1 start=U'
            Get-ChildItem $plain -Recurse -File | Should -BeNullOrEmpty
        }
    }

    It 'No %VAR% use of LOGFILE, DEBUGLOG, DESKTOP or TEMP after delayed expansion is enabled' {
        $t = Get-RwuScriptText
        $after = $t.Substring($t.IndexOf("`nsetlocal EnableDelayedExpansion")) -split '\r?\n'
        $bad = $after | Where-Object { $_ -notmatch '^\s*(::|rem\b)' -and $_ -match '(?i)%(LOGFILE|DEBUGLOG|DESKTOP|TEMP)[%:]' }
        $bad | Should -BeNullOrEmpty
    }
}


# ── Phase 20: Connectivity probes ───────────────────────────────────────────

Describe 'Phase 20 — Connectivity' {
    Context 'https probe (AC-19)' {
        It 'Issuer <Dn>, status <Status>: fails, 1 finding' -TestCases @(
            @{ Dn = 'CN=Contoso TLS Inspection, O=Contoso'; Status = 200 }
            @{ Dn = 'CN=x, O=Microsoft Corporation Ltd'; Status = 200 }
            @{ Dn = 'CN=x, O=microsoft corporation'; Status = 200 }
            @{ Dn = ''; Status = 200 }
            @{ Dn = 'CN=Microsoft Update Test, O=Microsoft Corporation, C=US'; Status = 403 }
        ) {
            $r = Invoke-RwuStep13 -HttpsDn $Dn -HttpsReply "$Status|text/html"
            $r.ProbeExits.Count | Should -Be 2
            $r.ProbeExits[0] | Should -Not -Be 0
            $r.ProbeExits[1] | Should -Be 0
            $r.Https.Requests | Should -Be 1
            $r.Vars._conn_fail | Should -Be '1'
            $r.Vars.DIAG_FINDINGS | Should -Be '1'
            $r.Findings | Should -Be 1
            $r.Log | Should -Match "Status: $Status"
        }
        It 'Issuer <Dn>, status 200: passes, no finding' -TestCases @(
            @{ Dn = 'CN=Microsoft Update Test, O=Microsoft Corporation, C=US' }
            @{ Dn = 'O=Microsoft Corporation' }
        ) {
            $r = Invoke-RwuStep13 -HttpsDn $Dn
            $r.ProbeExits | Should -Be @(0, 0)
            $r.Vars._conn_fail | Should -Be '0'
            $r.Vars.DIAG_FINDINGS | Should -Be '0'
            $r.Findings | Should -Be 0
            $r.Log | Should -Match 'Status: 200'
            $r.Log | Should -Match ([regex]::Escape('O=Microsoft Corporation'))
        }
        It 'Mutant that <Name> changes the O=Contoso result' -TestCases @(
            @{ Name = 'drops the issuer condition'; From = " -and `$i -cmatch '(^|, )O=Microsoft Corporation(,|`$)'"; ProbeExit = 0 }
            @{ Name = 'ignores the probe exit code'; From = 'if !errorlevel! neq 0 set "_conn_fail=1"'; ProbeExit = 1 }
        ) {
            $t = Get-RwuScriptText
            $t.Contains($From) | Should -BeTrue
            $r = Invoke-RwuStep13 -HttpsDn 'CN=x, O=Contoso' -Text $t.Replace($From, '')
            $r.ProbeExits[0] | Should -Be $ProbeExit
            $r.Findings | Should -Be 0
        }
        It 'An untrusted chain is a TrustFailure with 1 connection, and fails' {
            $r = Invoke-RwuStep13 -NoPrologue
            $r.Https.Connections | Should -Be 1
            $r.Https.Requests | Should -Be 0
            $r.ProbeExits[0] | Should -Not -Be 0
            $r.Log | Should -Match 'TrustFailure'
            $r.Findings | Should -Be 1
        }
        It 'The seam refuses a text without exactly one probe literal' {
            $t = Get-RwuScriptText
            { Invoke-RwuStep13 -Text $t.Replace('fe2cr.', 'other.') } | Should -Throw '*occurs 0 times*'
            { Invoke-RwuStep13 -Text ($t + $t) } | Should -Throw '*occurs 2 times*'
        }
    }

    Context 'http probe (AC-20)' {
        It '<Reply> fails' -TestCases @(
            @{ Reply = '403|application/vnd.ms-cab-compressed' }
            @{ Reply = '407|application/vnd.ms-cab-compressed' }
            @{ Reply = '302|application/vnd.ms-cab-compressed' }
            @{ Reply = '200|text/html' }
            @{ Reply = '200|Text/HTML; charset=utf-8' }
        ) {
            $r = Invoke-RwuStep13 -HttpReply $Reply
            $r.ProbeExits[0] | Should -Be 0
            $r.ProbeExits[1] | Should -Not -Be 0
            $r.Http.Requests | Should -Be 1
            $r.Findings | Should -Be 1
            $r.Vars.DIAG_FINDINGS | Should -Be '1'
            $r.Log | Should -Match "Status: $($Reply.Split('|')[0])"
        }
        It '200 application/vnd.ms-cab-compressed passes' {
            $r = Invoke-RwuStep13
            $r.ProbeExits[1] | Should -Be 0
            $r.Http.Requests | Should -Be 1
            $r.Log | Should -Match ([regex]::Escape('application/vnd.ms-cab-compressed'))
        }
    }

    Context 'Retry (AC-21)' {
        It '<_> first: retried, pass with 2 requests' -ForEach 'drop', 'garbage' {
            $r = Invoke-RwuStep13 -HttpReply $_, '200|application/vnd.ms-cab-compressed'
            $r.ProbeExits[1] | Should -Be 0
            $r.Http.Requests | Should -Be 2
            $r.Findings | Should -Be 0
        }
        It 'An HTTP error is not retried' {
            (Invoke-RwuStep13 -HttpReply '403|text/plain', '200|application/vnd.ms-cab-compressed').Http.Requests | Should -Be 1
        }
        # .NET Framework sends a dropped GET a second time inside one GetResponse call, and no
        # public setting stops it. 'garbage' is the no-HTTP-response case that it does not resend.
        It 'Always <Reply>: exactly 3 attempts, then fail' -TestCases @(
            @{ Reply = 'garbage'; Requests = 3 }
            @{ Reply = 'drop'; Requests = 6 }
        ) {
            $r = Invoke-RwuStep13 -HttpReply $Reply
            $r.Http.Requests | Should -Be $Requests
            $r.ProbeExits[1] | Should -Not -Be 0
            $r.Findings | Should -Be 1
            [regex]::Matches($r.Log, 'Attempt \d of 3').Count | Should -Be 3
        }
    }

    Context 'Findings (AC-22)' {
        It 'Both probes failing add exactly one finding' {
            $r = Invoke-RwuStep13 -HttpsReply '403|text/html' -HttpReply '403|text/html'
            $r.Findings | Should -Be 1
            $r.Vars.DIAG_FINDINGS | Should -Be '1'
        }
        It 'The old URLs are gone' {
            $t = Get-RwuScriptText
            $t | Should -Not -Match 'https://update\.microsoft\.com'
            $t | Should -Not -Match 'https://download\.windowsupdate\.com'
        }
    }
}


# ── Phase 21: Batch cleanups ────────────────────────────────────────────────

Describe 'Phase 21 — Batch Cleanups' {
    It '/autokeys <Name> exits 1 with an error' -TestCases @(
        @{ Name = 'as the last argument'; Arg = '/testmode /autokeys' }
        @{ Name = 'followed by another switch'; Arg = '/testmode /autokeys /debug' }
        @{ Name = 'with an empty value'; Arg = '/testmode /autokeys ""' }
    ) {
        $shipped = (Resolve-Path (Join-Path $PSScriptRoot '..\Reset_WindowsUpdate.cmd')).Path
        $r = Invoke-RwuProcess -CommandLine "`"$shipped`" $Arg" -Cwd $TestDrive -TimeoutSec 20
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'ERROR: /autokeys requires a value'
    }
    It '/autokeys with a value sets _AUTOKEYS and continues' {
        $r = Invoke-RwuBlock -Entry 'set "_AUTOKEYS="', 'call :ParseArgs /autokeys 7.2 /diag /logdir .'
        $r.Vars._AUTOKEYS | Should -Be '7.2'
        $r.Vars.LOGFILE | Should -Be "$($r.Work)\WU_Reset_Log.txt"
    }
    It '_AUTOKEYS is not pre-initialized' {
        Get-RwuScriptText | Should -Not -Match '(?im)^\s*set\s+"_AUTOKEYS="'
    }
    It 'No executable line has a hardcoded C:\Windows path' {
        $bad = (Get-RwuScriptText) -split '\r?\n' | Where-Object { $_ -notmatch '^\s*(::|rem\b)' -and $_ -match '(?i)C:\\Windows\b' }
        $bad | Should -BeNullOrEmpty
        # the three log reads
        [regex]::Matches((Get-RwuScriptText), '(?i)\$env:SystemRoot\\Logs|\$env:SystemRoot\+''\\Logs|Join-Path \$env:SystemRoot').Count | Should -Be 3
    }
    It 'The DISM tip names an install.wim source' {
        $t = Get-RwuScriptText
        $t | Should -Match ([regex]::Escape('/Source:WIM:D:\sources\install.wim:1 /LimitAccess'))
        $t | Should -Not -Match '/Source:D:\\sources'
    }
}


# ── Phase 22: Launcher, bump script and release hash ────────────────────────

Describe 'Phase 22 — Launcher' {
    BeforeAll {
        # The shipped launcher in a child Windows PowerShell; the network and launch commands only record.
        function Invoke-Launcher([switch]$NoAsset, [string]$Body, [switch]$NoRelease) {
            $d = Join-Path $TestDrive "l_$(Get-Random)"
            [void](New-Item -ItemType Directory "$d\tmp" -Force)
            $name = if ($NoAsset) { 'other.txt' } else { 'Reset_WindowsUpdate.cmd' }
            $drv = @"
[Net.ServicePointManager]::SecurityProtocol = 768
function Invoke-RestMethod { Add-Content '$d\calls.txt' "rest `$(`$args[0]) tls=`$([int][Net.ServicePointManager]::SecurityProtocol)"
  if ($([int][bool]$NoRelease)) { throw 'no release' }
  [pscustomobject]@{ tag_name = 'v9.9.9'; body = '$Body'; assets = @([pscustomobject]@{ name = '$name'; browser_download_url = 'https://asset.example/x' }) } }
function Invoke-WebRequest { param(`$Uri, `$OutFile, [switch]`$UseBasicParsing, `$ErrorAction)
  Add-Content '$d\calls.txt' "web `$Uri"; [IO.File]::WriteAllText(`$OutFile, 'payload') }
function Start-Process { Add-Content '$d\calls.txt' "start `$args" }
. '$((Resolve-Path (Join-Path $PSScriptRoot '..\rwu.ps1')).Path)'
"@
            Set-Content "$d\drv.ps1" $drv -Encoding ascii
            $r = Invoke-RwuProcess -CommandLine "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$d\drv.ps1`"" -Cwd $d -Env @{
                TEMP = "$d\tmp"; TMP = "$d\tmp"; RWU_DEBUG = ''
                PSModulePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules" # not the one of PowerShell 7
            }
            [pscustomobject]@{
                Output = $r.Output
                Calls  = @(if (Test-Path "$d\calls.txt") { Get-Content "$d\calls.txt" })
                Left   = @(Get-ChildItem "$d\tmp" -Filter 'rwu_*')
            }
        }
        $sha = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes('payload'))
        $script:good = ($sha | ForEach-Object { $_.ToString('X2') }) -join ''
        $script:bad = 'A' * 64
    }
    It 'Right hash: 1 download of the asset, 1 launch' {
        $r = Invoke-Launcher -Body "SHA256: $good"
        @($r.Calls -like 'web *') | Should -Be @('web https://asset.example/x')
        @($r.Calls -like 'start *').Count | Should -Be 1
        $r.Output | Should -Match 'VERIFIED'
        $r.Left.Count | Should -Be 0
    }
    It 'Tls12 is added before the first request, and other protocols stay' {
        (Invoke-Launcher -Body "SHA256: $good").Calls[0] | Should -Match 'tls=3840$'
    }
    It 'No asset: error, 0 downloads, 0 launches' {
        $r = Invoke-Launcher -NoAsset -Body "SHA256: $good"
        @($r.Calls -match '^(web|start) ').Count | Should -Be 0
        $r.Output | Should -Match 'ERROR: .*Reset_WindowsUpdate\.cmd'
        $r.Left.Count | Should -Be 0
    }
    It '<Name>: 0 launches' -TestCases @(
        @{ Name = 'Wrong hash'; Body = "SHA256: $('A' * 64)"; Text = 'Hash mismatch' }
        @{ Name = 'No hash'; Body = 'nothing here'; Text = 'No SHA256 hash' }
    ) {
        $r = Invoke-Launcher -Body $Body
        @($r.Calls -like 'start *').Count | Should -Be 0
        $r.Output | Should -Match $Text
        $r.Left.Count | Should -Be 0
    }
    It 'No release: 0 downloads, 0 launches' {
        $r = Invoke-Launcher -NoRelease
        @($r.Calls -match '^(web|start) ').Count | Should -Be 0
        $r.Output | Should -Match 'No releases found'
    }
    It 'There is no raw-URL fallback' {
        Get-Content (Join-Path $PSScriptRoot '..\rwu.ps1') | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'raw\.githubusercontent' } | Should -BeNullOrEmpty
    }
}

Describe 'Phase 22 — Bump Script' {
    BeforeAll {
        $script:keyDir = Join-Path $TestDrive 'key'
        [void](New-Item -ItemType Directory $keyDir)
        ssh-keygen -q -t ed25519 -C 'rwu-test' -N '' -f "$keyDir\k" | Out-Null
        if (-not (Test-Path "$keyDir\k.pub")) { throw 'no test key' }
        $script:saved = @{}
        foreach ($n in 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE') {
            $saved[$n] = [Environment]::GetEnvironmentVariable($n)
        }
        # Set by git when this suite runs from a commit hook.
        Remove-Item Env:GIT_DIR, Env:GIT_WORK_TREE, Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        $env:GIT_CONFIG_NOSYSTEM = '1'

        # A temporary repository with a bare remote. Skip/Set change the signing settings.
        function New-BumpRepo([string]$Skip, [hashtable]$Set = @{}) {
            $d = Join-Path $TestDrive "b_$(Get-Random)"
            [void](New-Item -ItemType Directory "$d\repo" -Force)
            $env:GIT_CONFIG_GLOBAL = "$d\gitconfig"
            Set-Content $env:GIT_CONFIG_GLOBAL '' -NoNewline
            $cfg = @{
                'user.name' = 'MatBanik'; 'user.email' = '219344396+matbanik@users.noreply.github.com'; 'core.autocrlf' = 'false'
                'commit.gpgsign' = 'true'; 'tag.gpgsign' = 'true'; 'gpg.format' = 'ssh'; 'user.signingkey' = "$keyDir\k.pub".Replace('\', '/')
            }
            foreach ($k in $cfg.Keys) { git config --global $k $cfg[$k] }
            git init -q -b main "$d\repo"
            git init -q --bare -b main "$d\remote.git"
            git -C "$d\repo" remote add origin "$d\remote.git"
            [IO.File]::WriteAllText("$d\repo\Reset_WindowsUpdate.cmd", "@echo off`r`nset `"ver=1.1.1`"`r`necho x`r`n")
            git -C "$d\repo" add -A
            git -C "$d\repo" commit -q -m 'init'
            if ($Skip) { git config --global --unset $Skip }
            foreach ($k in $Set.Keys) { git config --global $k $Set[$k] }
            $d
        }
        function Invoke-Bump([string]$D, [string]$Arguments) {
            $bump = (Resolve-Path (Join-Path $PSScriptRoot '..\bump.ps1')).Path
            Invoke-RwuProcess -CommandLine "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$bump`" $Arguments" -Cwd "$D\repo"
        }
        function Get-CommitCount([string]$D) { [int](git -C "$D\repo" rev-list --count HEAD) }
    }
    AfterAll {
        foreach ($n in $saved.Keys) {
            if ($null -eq $saved[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue } else { Set-Item "Env:$n" $saved[$n] }
        }
    }

    It '<Name>: exit 1, file unchanged, no commit' -TestCases @(
        @{ Name = 'commit.gpgsign missing'; Skip = 'commit.gpgsign'; Set = @{} }
        @{ Name = 'tag.gpgsign missing'; Skip = 'tag.gpgsign'; Set = @{} }
        @{ Name = 'gpg.format missing'; Skip = 'gpg.format'; Set = @{} }
        @{ Name = 'user.signingkey missing'; Skip = 'user.signingkey'; Set = @{} }
        @{ Name = 'commit.gpgsign false'; Skip = ''; Set = @{ 'commit.gpgsign' = 'false' } }
        @{ Name = 'gpg.format openpgp'; Skip = ''; Set = @{ 'gpg.format' = 'openpgp' } }
    ) {
        $d = New-BumpRepo -Skip $Skip -Set $Set
        $before = [IO.File]::ReadAllText("$d\repo\Reset_WindowsUpdate.cmd")
        $r = Invoke-Bump $d '9.9.9'
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match ([regex]::Escape($Name.Split(' ')[0]))
        [IO.File]::ReadAllText("$d\repo\Reset_WindowsUpdate.cmd") | Should -Be $before
        Get-CommitCount $d | Should -Be 1
        git -C "$d\repo" tag -l | Should -BeNullOrEmpty
    }
    It 'A failing pre-commit hook: nonzero, no commit, no tag, nothing pushed' {
        $d = New-BumpRepo
        [IO.File]::WriteAllText("$d\repo\.git\hooks\pre-commit", "#!/bin/sh`nexit 1`n")
        (Invoke-Bump $d '9.9.9').ExitCode | Should -Not -Be 0
        Get-CommitCount $d | Should -Be 1
        git -C "$d\repo" tag -l | Should -BeNullOrEmpty
        git --git-dir "$d\remote.git" for-each-ref | Should -BeNullOrEmpty
    }
    It 'A failing git tag: nonzero, nothing pushed' {
        $d = New-BumpRepo
        git -C "$d\repo" -c tag.gpgsign=false tag v9.9.9
        (Invoke-Bump $d '9.9.9').ExitCode | Should -Not -Be 0
        git --git-dir "$d\remote.git" for-each-ref | Should -BeNullOrEmpty
    }
    It 'A failing push: nonzero, and no success message' {
        $d = New-BumpRepo
        Remove-Item "$d\remote.git" -Recurse -Force
        $r = Invoke-Bump $d '9.9.9'
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Not -Match 'Pushed v9\.9\.9'
    }
    It '-NoPush: one signed commit, no tag, only the ver line differs; a second run adds nothing' {
        $d = New-BumpRepo
        (Invoke-Bump $d '9.9.9 -NoPush').ExitCode | Should -Be 0
        Get-CommitCount $d | Should -Be 2
        (git -C "$d\repo" cat-file commit HEAD) -join "`n" | Should -Match 'BEGIN SSH SIGNATURE'
        git -C "$d\repo" log -1 --format='%an <%ae>' | Should -Be 'MatBanik <219344396+matbanik@users.noreply.github.com>'
        git -C "$d\repo" tag -l | Should -BeNullOrEmpty
        git --git-dir "$d\remote.git" for-each-ref | Should -BeNullOrEmpty
        $diff = @(git -C "$d\repo" diff -U0 HEAD~1 HEAD | Where-Object { $_ -match '^[+-](?![+-])' } | ForEach-Object { $_.TrimEnd("`r") })
        $diff | Should -Be @('-set "ver=1.1.1"', '+set "ver=9.9.9"')
        (Invoke-Bump $d '9.9.9 -NoPush').ExitCode | Should -Be 0
        Get-CommitCount $d | Should -Be 2
    }
    It 'A full run pushes main and a signed annotated tag' {
        $d = New-BumpRepo
        $r = Invoke-Bump $d '9.9.9'
        $r.ExitCode | Should -Be 0
        @(git --git-dir "$d\remote.git" for-each-ref --format='%(refname)') | Should -Be @('refs/heads/main', 'refs/tags/v9.9.9')
        (git -C "$d\repo" cat-file tag v9.9.9) -join "`n" | Should -Match 'BEGIN SSH SIGNATURE'
    }
}

Describe 'Phase 22 — Release Hash Check' {
    BeforeAll {
        $script:h = '0123456789abcdef' * 4
        $script:body = "## Integrity`n| File | SHA256 |`n| x | ``$('B' * 64)`` |`n`nSHA256: $($h.ToUpper())`n"
        function Invoke-HashCheck([string]$Body, [string]$Expected = $h, [string]$Launcher) {
            $d = Join-Path $TestDrive "h_$(Get-Random)"
            [void](New-Item -ItemType Directory $d)
            [IO.File]::WriteAllText("$d\body.md", $Body)
            $l = (Resolve-Path (Join-Path $PSScriptRoot '..\rwu.ps1')).Path
            if ($Launcher) { $l = "$d\l.ps1"; [IO.File]::WriteAllText($l, $Launcher) }
            $f = Join-Path $PSScriptRoot '..\.github\scripts\Test-ReleaseHash.ps1'
            pwsh -NoProfile -File $f -BodyPath "$d\body.md" -LauncherPath $l -ExpectedHash $Expected | Out-Null
            $LASTEXITCODE
        }
    }
    It 'The right hash exits 0' { Invoke-HashCheck $body | Should -Be 0 }
    It '<Name> exits 1' -TestCases @(
        @{ Name = 'An unreplaced placeholder'; Pat = 'SHA256: [0-9A-F]{64}'; With = 'SHA256: $HASH_PLACEHOLDER' }
        @{ Name = 'A wrong hash'; Pat = 'SHA256: [0-9A-F]{64}'; With = "SHA256: $('C' * 64)" }
        @{ Name = 'An earlier decoy hash'; Pat = '^'; With = "SHA256: $('C' * 64)`n" }
    ) {
        Invoke-HashCheck ([regex]$Pat).Replace($body, $With.Replace('$', '$$'), 1) | Should -Be 1
    }
    It 'A launcher with <Name> exits 1' -TestCases @(
        @{ Name = 'no regex'; Text = 'Write-Host hi' }
        @{ Name = 'two regexes'; Text = "`$a -match 'SHA256:\s*([0-9A-Fa-f]{64})'; `$b -match 'SHA256:\s*([0-9A-Fa-f]{64})'" }
    ) {
        Invoke-HashCheck $body -Launcher $Text | Should -Be 1
    }
    It 'An expected value that is not a SHA256 exits 1' { Invoke-HashCheck $body -Expected 'abc' | Should -Be 1 }
}


# ── Phase 23: Documentation ─────────────────────────────────────────────────

Describe 'Phase 23 — Documentation' {
    BeforeAll {
        function Get-RwuDoc([string]$Name) { [IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\$Name"), [Text.Encoding]::UTF8) }
    }
    It 'README lists <_>' -TestCases @('/fix', '/debug', '/logdir') {
        Get-RwuDoc 'README.md' | Should -Match "(?m)^Reset_WindowsUpdate\.cmd .*$([regex]::Escape($_)) "
    }
    It 'FAQ: 0x80070422 is detected and reported, not re-enabled' {
        $row = @((Get-RwuDoc 'FAQ.md') -split '\r?\n' | Where-Object { $_ -match '^\| `0x80070422`' })
        $row.Count | Should -Be 1
        $row[0] | Should -Match 'detects and reports a disabled service'
        $row[0] | Should -Match 'does not re-enable'
        $row[0] | Should -Not -Match '✅'
    }
    It 'FAQ: Step 13 names the two hosts that :ProbeWU contacts' {
        $faq = Get-RwuDoc 'FAQ.md'
        $hosts = @([regex]::Matches((Get-RwuScriptText), 'set "_PROBE_URI=https?://([^/"]+)') | ForEach-Object { $_.Groups[1].Value })
        $hosts.Count | Should -Be 2
        $line = @($faq -split '\r?\n' | Where-Object { $_ -match 'Step 13' })
        $line.Count | Should -Be 1
        foreach ($h in $hosts) { $line[0] | Should -Match ([regex]::Escape("``$h``")) }
        $faq | Should -Not -Match '`update\.microsoft\.com`'
    }
    It 'FAQ: Windows 10 support is past tense for October 2026' {
        $faq = Get-RwuDoc 'FAQ.md'
        $faq | Should -Match 'We supported Windows 10 until October 2026'
        $faq | Should -Match 'Consumer ESU ended on October 13, 2026'
        $faq | Should -Not -Match 'We support Windows 10|will display a deprecation notice'
    }
    It 'CONTRIBUTING describes the Pester suite' {
        $doc = Get-RwuDoc 'CONTRIBUTING.md'
        $doc | Should -Match 'tests/rwu\.Tests\.ps1'
        $doc | Should -Match 'Pester 5'
        $doc | Should -Match 'tests/support/Invoke-RwuPester\.ps1'
        $doc | Should -Not -Match "can't be unit-tested"
    }
}


# ── Phase 24: Live probe (network; excluded unless the filter names it) ──────

Describe 'Phase 24 — Live Probe' -Tag 'Live' {
    BeforeAll {
        $script:psDir = Split-Path $RwuWinPS
    }
    It 'The shipped :ProbeWU passes against <Uri>' -TestCases @(
        @{ Kind = 'https'; Uri = 'https://fe2cr.update.microsoft.com/v6/ClientWebService/client.asmx'; Detail = 'certificate issuer: .*O=Microsoft Corporation' }
        @{ Kind = 'http'; Uri = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/disallowedcertstl.cab'; Detail = 'content type: ' }
    ) {
        $entry = "set `"_PROBE_URI=$Uri`"", "set `"_PROBE_KIND=$Kind`"", 'call :ProbeWU', 'set "_rc=!errorlevel!"', 'goto :StepDone'
        $r = Invoke-RwuBlock -Entry $entry -ExtraPath $psDir -TimeoutSec 120
        $r.Log | Should -Match "Status: 200 - OK - $Detail"
        $r.Vars._rc | Should -Be '0'
    }
    It 'The shipped Step 13 finds nothing' {
        $r = Invoke-RwuBlock -Steps Step13 -ExtraPath $psDir -Vars @{ _STOP_AFTER = 'Step13' } -TimeoutSec 180
        [regex]::Matches($r.Log, 'Status: 200 - OK').Count | Should -Be 2
        $r.Vars.DIAG_FINDINGS | Should -Be '0'
        $r.Log | Should -Not -Match 'FINDING:'
    }
}
