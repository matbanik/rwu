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

    It 'Checks mkdir success before proceeding' -Skip {
        $cmd | Should -Match 'mkdir.*POLICY_BACKUP_DIR.*\r?\n.*errorlevel'
    }
    It 'Checks reg export success before reg delete' -Skip {
        $cmd | Should -Not -Match 'reg export.*\r?\n\s*reg delete'
    }
}

# ── Phase 4: Error Counting ─────────────────────────────────────────────────

Describe 'Phase 4 — Error Counting for Repair Commands' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It 'net stop has errorlevel checking' -Skip {
        $cmd | Should -Match 'net stop.*\r?\n.*errorlevel'
    }
    It 'bitsadmin has errorlevel checking' -Skip {
        $cmd | Should -Match 'bitsadmin.*\r?\n.*errorlevel'
    }
    It 'netsh winsock reset has errorlevel checking' -Skip {
        $cmd | Should -Match 'netsh winsock reset.*\r?\n.*errorlevel'
    }
    It 'net start has errorlevel checking' -Skip {
        $cmd | Should -Match 'net start.*\r?\n.*errorlevel'
    }
}

# ── Phase 5: PowerShell -NoProfile Consistency ──────────────────────────────

Describe 'Phase 5 — PowerShell -NoProfile Consistency' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It 'All powershell calls include -NoProfile' -Skip {
        $lines = $cmd -split "`n" | Where-Object { $_ -match 'powershell\s+-' -and $_ -match '-Command' }
        foreach ($line in $lines) {
            $line | Should -Match '-NoProfile' -Because "Line: $($line.Trim())"
        }
    }
}

# ── Phase 6: Help Text ──────────────────────────────────────────────────────

Describe 'Phase 6 — Help Text' {
    BeforeAll { $script:cmd = Get-CmdFileContent }

    It '/help text mentions /debug flag' -Skip {
        $cmd | Should -Match 'debug.*trace'
    }
    It '/help exit code is 0' -Skip {
        $tmpDir = Join-Path $env:TEMP "rwu_test_help_$(Get-Random)"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $r = Invoke-RwuCmd -Arguments @('/help') -LogDir $tmpDir
        $r.ExitCode | Should -Be 0
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
