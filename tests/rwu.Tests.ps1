#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
    RWU — Pester 5 test suite
    Organised by implementation phase so tests can be written before code (TDD).
    Run:  pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester tests/ -Output Detailed"
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
}

Describe 'Phase 7 — TUI Navigation (integration, no elevation)' {

    Context 'Main Menu → Exit' {
        BeforeAll {
            $script:tmpDir = Join-Path $env:TEMP "rwu_tui_exit_$(Get-Random)"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '9') -LogDir $tmpDir
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
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '7.9') -LogDir $tmpDir
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
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '8.9') -LogDir $tmpDir
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
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '3.10.9') -LogDir $tmpDir
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
            $script:result = Invoke-RwuCmd -Arguments @('/testmode', '/debug', '/autokeys', '1.1.9') -LogDir $tmpDir
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
