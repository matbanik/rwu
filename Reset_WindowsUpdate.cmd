@echo off
setlocal EnableDelayedExpansion
:: ============================================================
:: Windows Update Reset & Repair Tool - Windows 11
:: Full-screen interactive TUI with color-coded menu and step toggles
::
:: References:
::   https://github.com/matbanik/rwu
::   https://matbanik.info/reset-windows-update-guide
::   https://support.microsoft.com/en-us/windows/troubleshoot-problems-updating-windows
::   https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/additional-resources-for-windows-update
::   https://www.elevenforum.com/t/reset-windows-update-in-windows-11.3808
:: Run as Administrator - Right-click > Run as administrator
:: Creates log on the Desktop (or user profile root as fallback)
:: ============================================================

:: Version: bump this before each GitHub release (semver: MAJOR.MINOR.PATCH)
set "ver=1.0.7"

:: ============================================================
:: OPTIONS (change these before running if needed)
:: ============================================================
:: Set to 1 to export and delete WU registry policies (Step 6)
set "RESET_WU_POLICIES=0"
:: Set to 1 to reset BITS/WU service security descriptors (Step 7)
set "RESET_SERVICE_SDDL=0"
:: Set to 1 to enable debug trace logging to Desktop\RWU_Debug.log
set "DEBUG=0"
:: Test mode: TUI navigation only, no workloads, no admin required
set "_TESTMODE=0"
:: Automated key sequence for testing (period-separated errorlevel values)
:: _AUTOKEYS is left UNDEFINED unless /autokeys is passed.
:: This is critical: :Choice uses 'if not defined _AUTOKEYS' to decide
:: whether to call real choice.exe or pop from the autokey sequence.
set /a _AUTOKEY_POS=0

:: ============================================================
:: EARLY HELP CHECK (runs before admin so users can view usage)
:: ============================================================
set "_CLI_MODE=0"
if not "%~1"=="" set "_CLI_MODE=1"

if /I "%~1"=="/help"   goto :ShowHelp
if /I "%~1"=="/?"      goto :ShowHelp
if /I "%~1"=="-help"   goto :ShowHelp
if /I "%~1"=="--help"  goto :ShowHelp

:: Early /testmode detection — scan all args before admin check
:: so testmode can skip elevation requirement
for %%A in (%*) do (
    if /I "%%~A"=="/testmode" set "_TESTMODE=1"
)

:: ============================================================
:: INITIALIZATION (admin check, log setup, timestamp)
:: ============================================================

:: Check for admin privileges (fltmc is more reliable than net session)
:: Skipped in test mode - TUI navigation only, no system changes
if not "!_TESTMODE!"=="1" (
    fltmc >nul 2>&1
    if !errorlevel! neq 0 (
        echo.
        echo *** ERROR: This script must be run as Administrator! ***
        echo Right-click the file and choose "Run as administrator"
        echo.
        if not "!_CLI_MODE!"=="1" pause
        exit /b 1
    )
)

:: Set log file path with fallback
set "DESKTOP=%USERPROFILE%\Desktop"
if not exist "%DESKTOP%" set "DESKTOP=%USERPROFILE%"
set "LOGFILE=%DESKTOP%\WU_Reset_Log.txt"
set "DEBUGLOG=%DESKTOP%\RWU_Debug.log"

:: Generate timestamp for backups (PowerShell - wmic is deprecated on Win11)
for /f "usebackq" %%I in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "TIMESTAMP=%%I"
:: Fallback if PowerShell failed
if not defined TIMESTAMP set "TIMESTAMP=%DATE:~-4%%DATE:~4,2%%DATE:~7,2%-%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%"
:: Strip spaces from pre-10AM timestamps (" 9" -> "09")
if defined TIMESTAMP set "TIMESTAMP=%TIMESTAMP: =0%"
if not defined TIMESTAMP set "TIMESTAMP=unknown"

:: Failure counter (script execution errors)
set /a WARN_COUNT=0
set /a FAIL_COUNT=0
:: Diagnostic findings counter (system health issues found during scan)
set /a DIAG_FINDINGS=0

:: ANSI escape character for spinner and screen control
for /f "delims=" %%a in ('powershell -NoProfile -Command "[char]27"') do set "ESC=%%a"
set /a _SP=0

:: ============================================================
:: CLI ARGUMENT PARSER (for non-interactive / AI agent usage)
:: ============================================================
:: Common variables are initialized above. If CLI mode, parse and dispatch.
if "%_CLI_MODE%"=="1" goto :ParseArgs

:: Console window title and size (interactive only)
title  Windows Update Reset Tool %ver%
if not "!_TESTMODE!"=="1" (
    mode con: cols=80 lines=35 >nul 2>&1 || (
        echo  [WARN] Could not set console size. Layout may vary. >> "%LOGFILE%" 2>nul
    )
)
:: Initialize debug log if enabled
if "!DEBUG!"=="1" call :DebugInit
call :Trace "INIT: interactive mode, testmode=!_TESTMODE!, goto :MainMenu"
goto :MainMenu

:: --- CLI Argument Parsing ---
:ParseArgs
set "_CLI_ACTION="
set "_CLI_STEP="

:ParseArgsLoop
if "%~1"=="" goto :RunCLI
if /I "%~1"=="/help"    goto :ShowHelp
if /I "%~1"=="/?"       goto :ShowHelp
if /I "%~1"=="-help"    goto :ShowHelp
if /I "%~1"=="--help"   goto :ShowHelp
if /I "%~1"=="/diag" (
    if defined _CLI_ACTION (
        echo ERROR: Conflicting actions: /!_CLI_ACTION! and /diag
        echo Only one action allowed. Use /help for usage.
        endlocal & exit /b 1
    )
    set "_CLI_ACTION=diag" & shift & goto :ParseArgsLoop
)
if /I "%~1"=="/reset" (
    if defined _CLI_ACTION (
        echo ERROR: Conflicting actions: /!_CLI_ACTION! and /reset
        echo Only one action allowed. Use /help for usage.
        endlocal & exit /b 1
    )
    set "_CLI_ACTION=reset" & shift & goto :ParseArgsLoop
)
if /I "%~1"=="/policy"  ( set "RESET_WU_POLICIES=1" & shift & goto :ParseArgsLoop )
if /I "%~1"=="/sddl"    ( set "RESET_SERVICE_SDDL=1" & shift & goto :ParseArgsLoop )
if /I "%~1"=="/debug"   ( set "DEBUG=1" & shift & goto :ParseArgsLoop )
if /I "%~1"=="/testmode" ( set "_TESTMODE=1" & shift & goto :ParseArgsLoop )
if /I "%~1"=="/autokeys" ( set "_AUTOKEYS=%~2" & shift & shift & goto :ParseArgsLoop )
if /I "%~1"=="/step" (
    if defined _CLI_ACTION (
        echo ERROR: Conflicting actions: /!_CLI_ACTION! and /step
        echo Only one action allowed. Use /help for usage.
        endlocal & exit /b 1
    )
    if "%~2"=="" (
        echo ERROR: /step requires a step number. Example: /step 3
        endlocal & exit /b 1
    )
    set "_CLI_ACTION=step"
    set "_CLI_STEP=%~2"
    shift & shift & goto :ParseArgsLoop
)
if /I "%~1"=="/fix" (
    if defined _CLI_ACTION (
        echo ERROR: Conflicting actions: /!_CLI_ACTION! and /fix
        echo Only one action allowed. Use /help for usage.
        endlocal & exit /b 1
    )
    if "%~2"=="" (
        echo ERROR: /fix requires a target. Example: /fix dism
        echo Valid targets: dism, sfc, combo, chkdsk, proxy
        endlocal & exit /b 1
    )
    set "_CLI_ACTION=fix"
    set "_CLI_FIX=%~2"
    shift & shift & goto :ParseArgsLoop
)
if /I "%~1"=="/logdir" (
    if "%~2"=="" (
        echo ERROR: /logdir requires a path. Example: /logdir "C:\Temp"
        endlocal & exit /b 1
    )
    set "_CLI_LOGDIR=%~2"
    shift & shift & goto :ParseArgsLoop
)
echo ERROR: Unknown argument: %~1
echo Run with /help for usage.
endlocal & exit /b 1

:RunCLI
:: Apply custom log directory if specified
if defined _CLI_LOGDIR (
    if not exist "!_CLI_LOGDIR!" (
        echo ERROR: Log directory does not exist: !_CLI_LOGDIR!
        endlocal & exit /b 1
    )
    set _CLI_LOGDIR 2>nul | findstr /C:"!" >nul 2>&1 && (
        echo ERROR: Log path cannot contain '!' characters.
        endlocal & exit /b 1
    )
    set "LOGFILE=!_CLI_LOGDIR!\WU_Reset_Log.txt"
    set "DEBUGLOG=!_CLI_LOGDIR!\RWU_Debug.log"
)
:: Initialize debug log if enabled (CLI mode)
if "!DEBUG!"=="1" call :DebugInit
call :Trace "INIT: CLI mode, action=!_CLI_ACTION!"
if not defined _CLI_ACTION (
    if "!_TESTMODE!"=="1" (
        :: No action specified but testmode active - enter interactive TUI
        call :Trace "INIT: testmode active, no CLI action, entering TUI"
        set "_CLI_MODE=0"
        goto :MainMenu
    )
    echo ERROR: No action specified. Use /diag, /reset, /step N, or /fix TARGET.
    echo Run with /help for usage.
    endlocal & exit /b 1
)
if /I "!_CLI_ACTION!"=="diag"  goto :DiagnosticsOnly
if /I "!_CLI_ACTION!"=="reset" goto :FullReset
if /I "!_CLI_ACTION!"=="step" (
    if /I "!_CLI_STEP!"=="0"       goto :DiagnosticsOnly
    if /I "!_CLI_STEP!"=="1"       goto :RunStopServices
    if /I "!_CLI_STEP!"=="2"       goto :RunStopServices
    if /I "!_CLI_STEP!"=="1-2"     goto :RunStopServices
    if /I "!_CLI_STEP!"=="3"       goto :RunStep3
    if /I "!_CLI_STEP!"=="4"       goto :RunStep4
    if /I "!_CLI_STEP!"=="5"       goto :RunStep5
    if /I "!_CLI_STEP!"=="6"       goto :RunStep6
    if /I "!_CLI_STEP!"=="7"       goto :RunStep7
    if /I "!_CLI_STEP!"=="8"       goto :RunStep8
    if /I "!_CLI_STEP!"=="9"       goto :RunNetwork
    if /I "!_CLI_STEP!"=="9-10"    goto :RunNetwork
    if /I "!_CLI_STEP!"=="10"      goto :RunNetwork
    if /I "!_CLI_STEP!"=="11"      goto :RunFinalize
    if /I "!_CLI_STEP!"=="11-14"   goto :RunFinalize
    if /I "!_CLI_STEP!"=="finalize" goto :RunFinalize
    echo ERROR: Unknown step: !_CLI_STEP!
    echo Valid steps: 0, 1-2, 3, 4, 5, 6, 7, 8, 9-10, 11-14, finalize
    endlocal & exit /b 1
)
if /I "!_CLI_ACTION!"=="fix" (
    if /I "!_CLI_FIX!"=="dism"   goto :RunFixDISM
    if /I "!_CLI_FIX!"=="sfc"    goto :RunFixSFC
    if /I "!_CLI_FIX!"=="combo"  goto :RunFixCombo
    if /I "!_CLI_FIX!"=="chkdsk" goto :RunFixCHKDSK
    if /I "!_CLI_FIX!"=="proxy"  goto :RunFixProxy
    echo ERROR: Unknown fix target: !_CLI_FIX!
    echo Valid targets: dism, sfc, combo, chkdsk, proxy
    endlocal & exit /b 1
)
echo ERROR: Unknown action: !_CLI_ACTION!
endlocal & exit /b 1

:: ============================================================
:: MAIN MENU
:: ============================================================

:MainMenu
call :Trace "entering :MainMenu"
:: Toggle state is read directly below via ANSI-colored labels
call :BlankScreen
color 0A
echo.
echo:  ================================================================
echo:
echo:     Windows Update Reset ^& Repair Tool  v%ver%
echo:     ________________________________________________________
echo:
echo:          [1]  Diagnostics Only
echo:               Collect full system health snapshot, no changes.
echo:
echo:          [2]  Full WU Reset
echo:               Run standard reset ^(Steps 0-14^). Steps 6/7
echo:               only run if their toggles are ON below.
echo:
echo:          [3]  Advanced  ^>
echo:               Pick individual steps to run.
echo:
echo:          [S]  System Fixes  ^>
echo:               DISM, SFC, CHKDSK — repair underlying system issues.
echo:          ________________________________________________________
echo:
:: Build colored toggle labels (OFF=gray, ON=yellow)
if "!RESET_WU_POLICIES!"=="1" (set "_WU_COL=!ESC![93m[ON]!ESC![92m") else (set "_WU_COL=!ESC![90m[OFF]!ESC![92m")
if "!RESET_SERVICE_SDDL!"=="1" (set "_SDDL_COL=!ESC![93m[ON]!ESC![92m") else (set "_SDDL_COL=!ESC![90m[OFF]!ESC![92m")
if "!DEBUG!"=="1" (set "_DBG_COL=!ESC![93m[ON]!ESC![92m") else (set "_DBG_COL=!ESC![90m[OFF]!ESC![92m")
<nul set /p "=!ESC![10C[4]  Delete WU policy keys after backup   !_WU_COL!"
echo.
<nul set /p "=!ESC![10C[5]  Reset BITS/WU service permissions    !_SDDL_COL!"
echo.
echo:          [6]  Change Log Folder
echo:          [7]  Help
<nul set /p "=!ESC![10C[8]  Debug trace log                      !_DBG_COL!"
echo.
echo:          ________________________________________________________
echo:
echo:          [0]  Exit
echo:
echo:  ================================================================
for %%F in ("%LOGFILE%") do set "_LOGNAME=%%~nxF"&set "_LOGDIR=%%~dpF"
if defined _LOGDIR set "_LOGDIR=!_LOGDIR:~0,-1!"
echo:     Log: ...\!_LOGNAME!
echo:     Dir: !_LOGDIR!
echo:  ================================================================
echo.
call :Trace "MainMenu: waiting for choice"
call :Choice /C:12345678S0 /N /M "  Choose an option [1,2,3,4,5,6,7,8,S,0]: "
if not defined _AUTOKEYS set "_erl=!errorlevel!"
call :Trace "MainMenu: choice returned !_erl!"

if !_erl!==10 ( call :Trace "MainMenu: exit" & endlocal & exit /b 0 )
if !_erl!==9  ( call :Trace "MainMenu: goto :SystemFixesMenu" & goto :SystemFixesMenu )
if !_erl!==8  ( call :Trace "MainMenu: goto :ToggleDebug" & goto :ToggleDebug )
if !_erl!==7  ( call :Trace "MainMenu: goto :ShowHelp" & goto :ShowHelp )
if !_erl!==6  ( call :Trace "MainMenu: goto :ChangeLogFolder" & goto :ChangeLogFolder )
if !_erl!==5  ( call :Trace "MainMenu: goto :ToggleSDDL" & goto :ToggleSDDL )
if !_erl!==4  ( call :Trace "MainMenu: goto :ToggleWUPolicy" & goto :ToggleWUPolicy )
if !_erl!==3  ( call :Trace "MainMenu: goto :AdvancedMenu" & goto :AdvancedMenu )
if !_erl!==2  ( call :Trace "MainMenu: goto :FullReset" & goto :FullReset )
if !_erl!==1  ( call :Trace "MainMenu: goto :DiagnosticsOnly" & goto :DiagnosticsOnly )
call :Trace "MainMenu: no match, looping"
goto :MainMenu

:: ============================================================
:: HELP SCREEN (shared by CLI /help and menu [7])
:: ============================================================

:ShowHelp
if not "!_CLI_MODE!"=="1" call :BlankScreen
echo.
echo  ================================================================
echo     Windows Update Reset ^& Repair Tool  v%ver%  -  Help
echo  ================================================================
echo.
echo  INTERACTIVE: Run with no arguments for the menu UI.
echo  CLI:         Reset_WindowsUpdate.cmd [action] [options]
echo.
echo  ACTIONS:                           STEP NUMBERS:
echo   /diag      Diagnostics only        0    System Diagnostics
echo   /reset     Full reset (0-14)       1-2  Stop services
echo   /step N    Run specific step       3    Delete BITS queue
echo   /fix T     Run system fix          4    Rename cache folders
echo                                      5    Reset BITS queue
echo  FIX TARGETS:                        6    Reset WU policies
echo   dism    DISM RestoreHealth          7    Reset service SDDL
echo   sfc     System File Checker         8    Re-register DLLs
echo   combo   DISM then SFC              9-10 Network reset
echo   chkdsk  Schedule disk check        11-14 or finalize
echo   proxy   Reset WinHTTP proxy
echo.
echo  OPTIONS:
echo   /policy    Enable policy reset
echo   /sddl      Enable SDDL reset
echo   /debug     Enable debug trace log
echo   /logdir P  Set log folder
echo:  /help /?   This help
echo  WARNING: /policy and /sddl bypass confirmation prompts.
echo  They delete registry keys and overwrite service permissions.
echo.
echo  EXAMPLES:
echo   Reset_WindowsUpdate.cmd /diag
echo   Reset_WindowsUpdate.cmd /reset /policy /sddl
echo   Reset_WindowsUpdate.cmd /step 3
echo   Reset_WindowsUpdate.cmd /fix combo
echo   Reset_WindowsUpdate.cmd /diag /logdir "C:\Temp"
echo.
echo  NOTES:
echo   - Admin required (except /help). Log: WU_Reset_Log.txt
echo   - Steps 6/7 skipped unless /policy or /sddl is set
echo   - /logdir must exist; exclamation mark in path rejected
echo   - CLI exits: 0=success, 1=failure, 2=warnings only
echo.
echo  ================================================================
if "!_CLI_MODE!"=="1" (
    endlocal
    exit /b 0
)
call :Trace "ShowHelp: displayed, waiting for keypress"
echo.
echo     Press any key to return to Main Menu...
if not "!_TESTMODE!"=="1" pause >nul
goto :MainMenu

:: --- Debug toggle ---
:ToggleDebug
call :Trace "entering :ToggleDebug"
if "!DEBUG!"=="0" (
    set "DEBUG=1"
    call :DebugInit
    call :Trace "DEBUG enabled via menu toggle"
) else (
    call :Trace "DEBUG disabled via menu toggle"
    set "DEBUG=0"
)
goto :MainMenu

:: --- Toggle with confirmation ---
:ToggleWUPolicy
if "!RESET_WU_POLICIES!"=="0" (
    call :BlankScreen
    echo.
    echo  ================================================================
    echo     WARNING: Delete WU Policy Registry Keys
    echo  ================================================================
    echo.
    echo   This will DELETE Windows Update registry policies.
    echo   This can remove WSUS, Intune, and WUfB configuration.
    echo   Do not enable on work/school-managed PCs unless instructed.
    echo.
    echo   Note: This only enables Step 6 for the next action you run.
    echo.
    echo  ================================================================
    echo.
    call :Choice /C:YN /N /M "  Enable WU Policy Reset? [Y/N]: "
    if not defined _AUTOKEYS set "_erl=!errorlevel!"
    if !_erl!==1 set "RESET_WU_POLICIES=1"
) else (
    set "RESET_WU_POLICIES=0"
)
goto :MainMenu

:ToggleSDDL
if "!RESET_SERVICE_SDDL!"=="0" (
    call :BlankScreen
    echo.
    echo  ================================================================
    echo     WARNING: Reset BITS/WU Service Permissions
    echo  ================================================================
    echo.
    echo   This will OVERWRITE BITS and WU service ACLs with hardcoded
    echo   default SDDLs. Build-specific or vendor ACLs will be lost.
    echo   Originals are logged first.
    echo   Do not enable unless standard reset failed or instructed.
    echo.
    echo   Note: This only enables Step 7 for the next action you run.
    echo.
    echo  ================================================================
    echo.
    call :Choice /C:YN /N /M "  Enable Service SDDL Reset? [Y/N]: "
    if not defined _AUTOKEYS set "_erl=!errorlevel!"
    if !_erl!==1 set "RESET_SERVICE_SDDL=1"
) else (
    set "RESET_SERVICE_SDDL=0"
)
goto :MainMenu

:: ============================================================
:: ADVANCED MENU - Pick individual steps
:: ============================================================

:AdvancedMenu
call :Trace "entering :AdvancedMenu"
call :BlankScreen
echo.
echo:  ================================================================
echo:     Advanced: Run Individual Steps
echo:  ================================================================
echo:
echo:     Diagnostics:
echo:       [1]  Step 0  - System Diagnostics
echo:
echo:     Core Reset:
echo:       [2]  Step 1-2  - Record config + Stop services
echo:       [3]  Step 3    - Delete BITS queue data
echo:       [4]  Step 4    - Rename WU cache folders ^(run 2 first^)
echo:       [5]  Step 5    - Reset BITS transfer queue
if "!RESET_WU_POLICIES!"=="1" (
    echo:       [6]  Step 6    - Reset WU policies
) else (
    <nul set /p "=!ESC![10C!ESC![90m[OFF] Step 6    - Reset WU policies!ESC![92m"
    echo.
)
if "!RESET_SERVICE_SDDL!"=="1" (
    echo:       [7]  Step 7    - Reset service permissions
) else (
    <nul set /p "=!ESC![10C!ESC![90m[OFF] Step 7    - Reset service permissions!ESC![92m"
    echo.
)
echo:       [8]  Step 8    - Re-register WU DLLs
echo:
echo:     Network:
echo:       [9]  Step 9-10 - Reset Winsock + Flush DNS
echo:
echo:     Finalize:
echo:       [A]  Step 11-14 - Restart services + post-reset checks
echo:     ________________________________________________________
echo:     NOTE: If you stop services or run repair steps,
echo:           run [A] Finalize before exiting.
echo:
echo:       [0]  Back to Main Menu
echo:
echo:  ================================================================
echo.
call :Choice /C:1234567890A /N /M "  Choose a step [1-9,A,0]: "
if not defined _AUTOKEYS set "_erl=!errorlevel!"

if !_erl!==11 goto :RunFinalize
if !_erl!==10 goto :MainMenu
if !_erl!==9  goto :RunNetwork
if !_erl!==8  goto :RunStep8
if !_erl!==7  goto :RunStep7
if !_erl!==6  goto :RunStep6
if !_erl!==5  goto :RunStep5
if !_erl!==4  goto :RunStep4
if !_erl!==3  goto :RunStep3
if !_erl!==2  goto :RunStopServices
if !_erl!==1  goto :DiagnosticsOnly
goto :AdvancedMenu

:: ============================================================
:: SYSTEM FIXES MENU
:: ============================================================

:SystemFixesMenu
call :Trace "entering :SystemFixesMenu"
call :BlankScreen
echo.
echo:  ================================================================
echo:     System Fixes: Repair Underlying System Issues
echo:  ================================================================
echo:
echo:     These commands repair system-level corruption that
echo:     prevents Windows Update from functioning correctly.
echo:     Run them AFTER a WU reset if updates still fail.
echo:
echo:       [1]  DISM - Repair Component Store
echo:            Repairs the Windows system image. (10-30 min)
echo:            Requires internet to download repairs.
echo:
echo:       [2]  SFC - Scan ^& Repair System Files
echo:            Scans and repairs protected OS files. (5-15 min)
echo:
echo:       [3]  DISM + SFC Combo (recommended)
echo:            Runs DISM first, then SFC - correct order. (15-45 min)
echo:
echo:       [4]  CHKDSK - Schedule Disk Check
echo:            Schedules disk repair on next reboot. (30-120 min)
echo:            Requires reboot. Do NOT interrupt once started.
echo:
echo:       [5]  Reset Proxy Settings
echo:            Resets WinHTTP proxy to direct connection.
echo:     ________________________________________________________
echo:
echo:       [0]  Back to Main Menu
echo:
echo:  ================================================================
echo.
call :Choice /C:123450 /N /M "  Choose a fix [1-5,0]: "
if not defined _AUTOKEYS set "_erl=!errorlevel!"

if !_erl!==6 goto :MainMenu
if !_erl!==5 goto :RunFixProxy
if !_erl!==4 goto :RunFixCHKDSK
if !_erl!==3 goto :RunFixCombo
if !_erl!==2 goto :RunFixSFC
if !_erl!==1 goto :RunFixDISM
goto :SystemFixesMenu

:: ============================================================
:: CHANGE LOG FOLDER
:: ============================================================

:: NOTE: Input is read with delayed expansion OFF to protect special chars.
:: Paths containing ! are explicitly rejected since the rest of the script
:: uses EnableDelayedExpansion which would mangle them.
:ChangeLogFolder
call :BlankScreen
echo.
echo:  ================================================================
echo:     Change Log Output Folder
echo:  ================================================================
echo:
echo:     Current log file:
echo:       %LOGFILE%
echo:
echo:     Enter a new folder path, or type 0 to go back.
echo:     The folder must already exist. Cannot contain '!'.
echo:     Quotes are OK if pasted.
echo:
echo:     Examples:
echo:       C:\Temp
echo:       D:\Diagnostics
echo:       C:\Users\YourName\Documents
echo:
echo:     [0]  Back to Main Menu
echo:  ================================================================
echo.
:: Read input with delayed expansion OFF to protect ! in paths
setlocal DisableDelayedExpansion
set "_newpath="
set /p "_newpath=  New folder path (or 0): "
if not defined _newpath endlocal & goto :MainMenu
if "%_newpath%"=="0" endlocal & goto :MainMenu
:: Strip surrounding quotes if pasted from Explorer
set "_newpath=%_newpath:"=%"
:: Trim trailing backslash
if "%_newpath:~-1%"=="\" set "_newpath=%_newpath:~0,-1%"
:: Validate path exists
if not exist "%_newpath%\" (
    echo.
    echo   ERROR: Folder "%_newpath%" does not exist.
    echo   Press any key to try again...
    pause >nul
    endlocal & goto :ChangeLogFolder
)
:: Reject paths containing ! (delayed expansion would mangle them).
:: Use 'set _newpath' which safely outputs name=value without parsing
:: metacharacters like & | < > in the path string.
set _newpath 2>nul | findstr /C:"!" >nul 2>&1 && (
    echo.
    echo   ERROR: Path cannot contain '!' characters.
    echo   Press any key to try again...
    pause >nul
    endlocal & goto :ChangeLogFolder
)
:: Promote path out of DisableDelayedExpansion scope
endlocal & set "LOGFILE=%_newpath%\WU_Reset_Log.txt"
echo.
echo   Log file set to: %LOGFILE%
echo   Press any key to return to menu...
pause >nul
goto :MainMenu

:: ============================================================
:: FLOW TARGETS - These set up the log and jump to step code
:: ============================================================

:DiagnosticsOnly
call :Trace "entering :DiagnosticsOnly"
set "_FULLRESET=0"
set "_STOP_AFTER=Step0"
set "_RUN_LABEL=Diagnostics Only"
if "!_TESTMODE!"=="1" (
    call :Trace "TESTMODE: skip workload, goto :StepDone"
    goto :StepDone
)
call :InitLog
goto :Step0

:FullReset
call :Trace "entering :FullReset"
set "_FULLRESET=1"
set "_STOP_AFTER=Step14"
set "_RUN_LABEL=Full WU Reset (standard flow; optional steps by toggle)"
if "!_TESTMODE!"=="1" (
    call :Trace "TESTMODE: skip workload, goto :StepDone"
    goto :StepDone
)
call :InitLog
goto :Step0

:: --- Initialize the log file header ---
:: Regenerate timestamp each run so backups don't collide
:InitLog
for /f "usebackq" %%I in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "TIMESTAMP=%%I"
if defined TIMESTAMP set "TIMESTAMP=!TIMESTAMP: =0!"
echo. >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"
echo  Windows Update Reset Log >> "%LOGFILE%"
echo  Action: !_RUN_LABEL! >> "%LOGFILE%"
echo  Computer: %COMPUTERNAME% >> "%LOGFILE%"
echo  User: %USERNAME% >> "%LOGFILE%"
echo  Date: %DATE% %TIME% >> "%LOGFILE%"
echo  Backup Timestamp: !TIMESTAMP! >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"
echo. >> "%LOGFILE%"
echo  NOTICE: This log may contain system identifiers, network >> "%LOGFILE%"
echo  configuration, and license details. Treat as sensitive if >> "%LOGFILE%"
echo  sharing outside the immediate troubleshooting context. >> "%LOGFILE%"
echo. >> "%LOGFILE%"
exit /b

:: --- Run individual steps from Advanced menu ---
:: Each target sets _STOP_AFTER to prevent fall-through

:RunStopServices
set "_STOP_AFTER=Step2"
set "_RUN_LABEL=Steps 1-2: Record config + Stop services"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunStopServices" & goto :StepDone )
call :InitLog
goto :Step1

:RunStep3
set "_STOP_AFTER=Step3"
set "_RUN_LABEL=Step 3: Delete BITS queue data"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunStep3" & goto :StepDone )
call :InitLog
goto :Step3

:RunStep4
set "_STOP_AFTER=Step4"
set "_RUN_LABEL=Step 4: Rename WU cache folders"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunStep4" & goto :StepDone )
call :InitLog
goto :Step4

:RunStep5
set "_STOP_AFTER=Step5"
set "_RUN_LABEL=Step 5: Reset BITS transfer queue"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunStep5" & goto :StepDone )
call :InitLog
goto :Step5

:RunStep6
set "_STOP_AFTER=Step6"
set "_RUN_LABEL=Step 6: WU policy reset (runs only if toggle ON)"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunStep6" & goto :StepDone )
call :InitLog
goto :Step6

:RunStep7
set "_STOP_AFTER=Step7"
set "_RUN_LABEL=Step 7: Service permissions reset (runs only if toggle ON)"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunStep7" & goto :StepDone )
call :InitLog
goto :Step7

:RunStep8
set "_STOP_AFTER=Step8"
set "_RUN_LABEL=Step 8: Re-register WU DLLs"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunStep8" & goto :StepDone )
call :InitLog
goto :Step8

:RunNetwork
set "_STOP_AFTER=Step10"
set "_RUN_LABEL=Steps 9-10: Reset Winsock + Flush DNS"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunNetwork" & goto :StepDone )
call :InitLog
goto :Step9

:RunFinalize
set "_STOP_AFTER=Step14"
set "_RUN_LABEL=Steps 11-14: Restart services + post-reset checks"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunFinalize" & goto :StepDone )
call :InitLog
goto :Step11

:: --- System Fix flow targets ---
:: Each sets _STOP_AFTER and _RUN_LABEL, then jumps to workload

:RunFixDISM
set "_STOP_AFTER=FixDISM"
set "_RUN_LABEL=System Fix: DISM Repair Component Store"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunFixDISM" & goto :StepDone )
call :InitLog
goto :FixDISM

:RunFixSFC
set "_STOP_AFTER=FixSFC"
set "_RUN_LABEL=System Fix: SFC System File Checker"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunFixSFC" & goto :StepDone )
call :InitLog
goto :FixSFC

:RunFixCombo
set "_STOP_AFTER=FixSFC"
set "_RUN_LABEL=System Fix: DISM + SFC Combo (recommended order)"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunFixCombo" & goto :StepDone )
call :InitLog
goto :FixDISM

:RunFixCHKDSK
set "_STOP_AFTER=FixCHKDSK"
set "_RUN_LABEL=System Fix: Schedule CHKDSK on Next Reboot"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunFixCHKDSK" & goto :StepDone )
call :InitLog
goto :FixCHKDSK

:RunFixProxy
set "_STOP_AFTER=FixProxy"
set "_RUN_LABEL=System Fix: Reset WinHTTP Proxy Settings"
if "!_TESTMODE!"=="1" ( call :Trace "TESTMODE: skip RunFixProxy" & goto :StepDone )
call :InitLog
goto :FixProxy

:: -----------------------------------------------
:: STEP 0: Capture system diagnostics
:: -----------------------------------------------
:Step0
echo [STEP 0] Capturing system diagnostics...
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 0] System Diagnostics >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo. >> "%LOGFILE%"
call :Spin

:: --- 0a: OS Identity ---
echo --- 0a: OS Version and Build --- >> "%LOGFILE%"
ver >> "%LOGFILE%" 2>&1
powershell -NoProfile -Command "Get-ComputerInfo | Select-Object OsName, OsVersion, OsBuildNumber, WindowsVersion, OsArchitecture, OsProductType, OsRegisteredUser, OsInstallDate, OsLastBootUpTime | Format-List" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0b: Windows Edition and Activation ---
echo --- 0b: Edition and Activation Status --- >> "%LOGFILE%"
powershell -NoProfile -Command "Get-CimInstance SoftwareLicensingProduct -Filter 'ApplicationID=''55c92734-d682-4d71-983e-d6ec3f16059f'' AND PartialProductKey IS NOT NULL' | Select-Object Name, @{N='LicenseStatus';E={switch([int]$_.LicenseStatus){0{'Unlicensed'}1{'Licensed'}2{'OOB Grace'}3{'OOT Grace'}4{'Non-Genuine Grace'}5{'Notification'}6{'Extended Grace'}default{$_.LicenseStatus}}}}, Description | Format-List" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0c: Insider Program Status ---
echo --- 0c: Windows Insider Status --- >> "%LOGFILE%"
reg query "HKLM\SOFTWARE\Microsoft\WindowsSelfHost\Applicability" /v BranchName >nul 2>&1
if !errorlevel! equ 0 (
    echo   Insider Program: ENROLLED >> "%LOGFILE%"
    reg query "HKLM\SOFTWARE\Microsoft\WindowsSelfHost\Applicability" /v BranchName >> "%LOGFILE%" 2>&1
    reg query "HKLM\SOFTWARE\Microsoft\WindowsSelfHost\Applicability" /v Ring >> "%LOGFILE%" 2>&1
    reg query "HKLM\SOFTWARE\Microsoft\WindowsSelfHost\Applicability" /v ContentType >> "%LOGFILE%" 2>&1
    set /a DIAG_FINDINGS+=1
) else (
    echo   Insider Program: Not enrolled >> "%LOGFILE%"
)
echo. >> "%LOGFILE%"
call :Spin

:: --- 0d: Hardware - CPU and RAM ---
echo --- 0d: CPU and Memory --- >> "%LOGFILE%"
powershell -NoProfile -Command "Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors | Format-List" >> "%LOGFILE%" 2>&1
powershell -NoProfile -Command "$m = Get-CimInstance Win32_PhysicalMemory; $total = ($m | Measure-Object Capacity -Sum).Sum / 1GB; Write-Output \"  Total RAM: $total GB  Sticks: $($m.Count)\"; $m | Select-Object DeviceLocator, @{N='CapacityGB';E={[math]::Round($_.Capacity/1GB)}}, Speed, Manufacturer | Format-Table -AutoSize | Out-String -Width 200" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0e: Disk Health (SMART + Reliability) ---
echo --- 0e: Disk Health --- >> "%LOGFILE%"
powershell -NoProfile -Command "Get-PhysicalDisk | Select-Object FriendlyName, MediaType, BusType, HealthStatus, OperationalStatus, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}} | Format-Table -AutoSize | Out-String -Width 200" >> "%LOGFILE%" 2>&1
powershell -NoProfile -Command "Get-PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue | Select-Object DeviceId, ReadErrorsTotal, WriteErrorsTotal, Wear, Temperature, PowerOnHours | Format-Table -AutoSize | Out-String -Width 200" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0f: Disk Space (all drives) ---
echo --- 0f: Disk Space --- >> "%LOGFILE%"
powershell -NoProfile -Command "$disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, @{N='FreeGB';E={[math]::Round($_.FreeSpace/1GB,1)}}, @{N='FreePercent';E={[math]::Round($_.FreeSpace/$_.Size*100,1)}}; $disks | Format-Table -AutoSize | Out-String -Width 200; $crit = $disks | Where-Object { $_.FreePercent -lt 5 }; foreach ($d in $crit) { Write-Output \"  FINDING: $($d.DeviceID) critically low ($($d.FreePercent)%% free)\" }; if ($crit) { exit 1 } else { exit 0 }" >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 set /a DIAG_FINDINGS+=1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0g: Component Store Health (quick check) ---
echo --- 0g: Component Store Health --- >> "%LOGFILE%"
:: Capture DISM output to temp file to avoid scanning the entire appended log
set "_DISM_TMP=%TEMP%\rwu_dism_%RANDOM%.txt"
DISM /Online /Cleanup-Image /CheckHealth > "!_DISM_TMP!" 2>&1
set "_dism_erl=!errorlevel!"
type "!_DISM_TMP!" >> "%LOGFILE%"
echo   DISM CheckHealth exit code: !_dism_erl! >> "%LOGFILE%"
if !_dism_erl! neq 0 (
    echo   FINDING: Component store needs repair >> "%LOGFILE%"
    set /a DIAG_FINDINGS+=1
)
:: Check only the DISM temp output for "repairable" (not the whole log)
findstr /I "repairable" "!_DISM_TMP!" >nul 2>&1
if !errorlevel! equ 0 if !_dism_erl! equ 0 (
    echo   FINDING: Component store is repairable >> "%LOGFILE%"
    set /a DIAG_FINDINGS+=1
)
del "!_DISM_TMP!" >nul 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0h: Pending Reboot Check ---
echo --- 0h: Pending Reboot Flags --- >> "%LOGFILE%"
set "_reboot_needed=0"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" >nul 2>&1
if !errorlevel! equ 0 (echo   CBS RebootPending: YES >> "%LOGFILE%"& set "_reboot_needed=1") else (echo   CBS RebootPending: No >> "%LOGFILE%")
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress" >nul 2>&1
if !errorlevel! equ 0 (echo   CBS RebootInProgress: YES >> "%LOGFILE%"& set "_reboot_needed=1") else (echo   CBS RebootInProgress: No >> "%LOGFILE%")
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" >nul 2>&1
if !errorlevel! equ 0 (echo   WU RebootRequired: YES >> "%LOGFILE%"& set "_reboot_needed=1") else (echo   WU RebootRequired: No >> "%LOGFILE%")
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v PendingFileRenameOperations >nul 2>&1
if !errorlevel! equ 0 (echo   PendingFileRename: YES >> "%LOGFILE%"& set "_reboot_needed=1") else (echo   PendingFileRename: No >> "%LOGFILE%")
if "!_reboot_needed!"=="1" (
    echo   FINDING: Pending reboot detected >> "%LOGFILE%"
    set /a DIAG_FINDINGS+=1
)
echo. >> "%LOGFILE%"
call :Spin

:: --- 0i: Windows Update Configuration (registry) ---
echo --- 0i: Windows Update Registry Config --- >> "%LOGFILE%"
echo   --- AU Settings --- >> "%LOGFILE%"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
echo   --- WU Server (WSUS) --- >> "%LOGFILE%"
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" >nul 2>&1
if !errorlevel! equ 0 (
    echo   WSUS/WUfB policy detected: >> "%LOGFILE%"
    reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer >> "%LOGFILE%" 2>&1
    reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer >> "%LOGFILE%" 2>&1
    reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess >> "%LOGFILE%" 2>&1
    set /a DIAG_FINDINGS+=1
) else (
    echo   No WSUS/WUfB policy configured ^(OK for home/standard use^) >> "%LOGFILE%"
)
echo. >> "%LOGFILE%"
call :Spin

:: --- 0j: Recent Windows Update Failures (Event Log) ---
echo --- 0j: Recent WU Failures (last 10, past 30 days) --- >> "%LOGFILE%"
powershell -NoProfile -Command "$ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; Level=2,3; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 10 -ErrorAction SilentlyContinue; if ($ev) { $ev | Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize -Wrap | Out-String -Width 200; Write-Output \"  FINDING: $($ev.Count) WU error events in the last 30 days\"; exit 1 } else { Write-Output '  No WU error events in the last 30 days'; exit 0 }" >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 set /a DIAG_FINDINGS+=1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0k: Recent System Crashes - Bugchecks (BSODs) ---
echo --- 0k: Recent Bugchecks / BSODs (last 5, past 30 days) --- >> "%LOGFILE%"
powershell -NoProfile -Command "$ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 5 -ErrorAction SilentlyContinue; if ($ev) { $ev | Format-Table TimeCreated, Message -AutoSize -Wrap | Out-String -Width 200 } else { Write-Output '  No bugcheck events in the last 30 days' }" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0k2: Kernel-Power (Event 41) - Unexpected Power Loss / Hard Resets ---
echo --- 0k2: Unexpected Power Loss / Hard Resets (Event 41, last 10, past 30 days) --- >> "%LOGFILE%"
powershell -NoProfile -Command "$ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 10 -ErrorAction SilentlyContinue; if ($ev) { $ev | Format-Table TimeCreated, Id, @{N='BugcheckCode';E={$_.Properties[0].Value}}, @{N='PowerButtonTimestamp';E={$_.Properties[4].Value}} -AutoSize | Out-String -Width 200; Write-Output \"  FINDING: $($ev.Count) unexpected power loss events\"; exit 1 } else { Write-Output '  No Kernel-Power Event 41 in the last 30 days'; exit 0 }" >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 set /a DIAG_FINDINGS+=1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0k3: Unexpected Shutdown (Event 6008) ---
echo --- 0k3: Unexpected/Dirty Shutdowns (Event 6008, last 10, past 30 days) --- >> "%LOGFILE%"
powershell -NoProfile -Command "$ev = Get-WinEvent -FilterHashtable @{LogName='System'; Id=6008; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 10 -ErrorAction SilentlyContinue; if ($ev) { $ev | Format-Table TimeCreated, Message -AutoSize -Wrap | Out-String -Width 200; Write-Output \"  FINDING: $($ev.Count) unexpected/dirty shutdown events\"; exit 1 } else { Write-Output '  No unexpected shutdown events in the last 30 days'; exit 0 }" >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 set /a DIAG_FINDINGS+=1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0k4: Critical Events (Level 1 = Critical, any source) ---
echo --- 0k4: All Critical System Events (last 10, past 30 days) --- >> "%LOGFILE%"
powershell -NoProfile -Command "$ev = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 10 -ErrorAction SilentlyContinue; if ($ev) { $ev | Format-Table TimeCreated, ProviderName, Id, Message -AutoSize -Wrap | Out-String -Width 200 } else { Write-Output '  No critical events in the last 30 days' }" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0k5: Memory Dump Files ---
echo --- 0k5: Memory Dump Files --- >> "%LOGFILE%"
echo   --- Full Memory Dump --- >> "%LOGFILE%"
powershell -NoProfile -Command "$sr = $env:SystemRoot; if (Test-Path \"$sr\MEMORY.DMP\") { $f = Get-Item \"$sr\MEMORY.DMP\"; Write-Output ('  MEMORY.DMP: ' + [math]::Round($f.Length/1MB) + ' MB, Last written: ' + $f.LastWriteTime) } else { Write-Output '  MEMORY.DMP: Not found' }" >> "%LOGFILE%" 2>&1
echo   --- Minidump Files (last 10) --- >> "%LOGFILE%"
powershell -NoProfile -Command "$sr = $env:SystemRoot; if (Test-Path \"$sr\Minidump\") { $dumps = Get-ChildItem \"$sr\Minidump\*.dmp\" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10; if ($dumps) { $dumps | Format-Table Name, @{N='SizeKB';E={[math]::Round($_.Length/1KB)}}, LastWriteTime -AutoSize | Out-String -Width 200 } else { Write-Output '  Minidump folder exists but no .dmp files found' } } else { Write-Output '  Minidump folder: Not found' }" >> "%LOGFILE%" 2>&1
echo   --- Crash Dump Settings --- >> "%LOGFILE%"
reg query "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v CrashDumpEnabled >> "%LOGFILE%" 2>&1
reg query "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v DumpFile >> "%LOGFILE%" 2>&1
reg query "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v MinidumpDir >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0l: Installed Updates (last 15) ---
echo --- 0l: Recent Installed Updates --- >> "%LOGFILE%"
powershell -NoProfile -Command "Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 15 | Format-Table HotFixID, InstalledOn, Description -AutoSize | Out-String -Width 200" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0m: Network Configuration ---
echo --- 0m: Network Configuration --- >> "%LOGFILE%"
echo   --- Active Adapters --- >> "%LOGFILE%"
powershell -NoProfile -Command "Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object Name, InterfaceDescription, Status, LinkSpeed | Format-Table -AutoSize | Out-String -Width 200" >> "%LOGFILE%" 2>&1
echo   --- DNS Servers --- >> "%LOGFILE%"
powershell -NoProfile -Command "Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses | Select-Object InterfaceAlias, ServerAddresses | Format-Table -AutoSize | Out-String -Width 200" >> "%LOGFILE%" 2>&1
echo   --- Proxy Settings --- >> "%LOGFILE%"
netsh winhttp show proxy >> "%LOGFILE%" 2>&1
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable >> "%LOGFILE%" 2>&1
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"
call :Spin

:: --- 0n: CBS/DISM Log Tail (last errors) ---
echo --- 0n: Last CBS.log Errors (last 20 error lines) --- >> "%LOGFILE%"
powershell -NoProfile -Command "if (Test-Path 'C:\Windows\Logs\CBS\CBS.log') { Get-Content 'C:\Windows\Logs\CBS\CBS.log' -Tail 500 | Select-String -Pattern 'Error|FAIL|corrupt' -CaseSensitive:$false | Select-Object -Last 20 | ForEach-Object { $_.Line.Trim() } } else { Write-Output '  CBS.log not found' }" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"

echo --- 0o: Last DISM.log Errors (last 20 error lines) --- >> "%LOGFILE%"
powershell -NoProfile -Command "if (Test-Path 'C:\Windows\Logs\DISM\dism.log') { Get-Content 'C:\Windows\Logs\DISM\dism.log' -Tail 500 | Select-String -Pattern 'Error|FAIL|0x800' -CaseSensitive:$false | Select-Object -Last 20 | ForEach-Object { $_.Line.Trim() } } else { Write-Output '  dism.log not found' }" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"

echo   Step 0 diagnostics complete.
call :SpinDone
echo. >> "%LOGFILE%"

:: --- Stop check: if this was the target step, go to summary ---
if /I "!_STOP_AFTER!"=="Step0" goto :StepDone

:: -----------------------------------------------
:: STEP 1: Record original service startup types
:: -----------------------------------------------
:Step1
echo [STEP 1] Recording original service configuration...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 1] Original Service Configuration - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo. >> "%LOGFILE%"
echo   (Save this section to restore original startup types if needed) >> "%LOGFILE%"
echo. >> "%LOGFILE%"

for %%s in (wuauserv cryptSvc bits msiserver appidsvc UsoSvc DoSvc TrustedInstaller) do (
    echo   --- %%s --- >> "%LOGFILE%"
    sc qc %%s 2>&1 | findstr /I "START_TYPE" >> "%LOGFILE%" 2>&1
    sc query %%s 2>&1 | findstr /I "STATE" >> "%LOGFILE%" 2>&1
    echo. >> "%LOGFILE%"
    call :Spin
)

call :SpinDone
if /I "!_STOP_AFTER!"=="Step1" goto :StepDone

:: -----------------------------------------------
:: STEP 2: Stop all Windows Update related services
:: -----------------------------------------------
:Step2
echo [STEP 2] Stopping Windows Update services...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 2] Stopping Services - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

for %%s in (wuauserv UsoSvc DoSvc cryptSvc bits msiserver appidsvc TrustedInstaller) do (
    echo   Stopping %%s... >> "%LOGFILE%"
    net stop %%s /y >> "%LOGFILE%" 2>&1
    if !errorlevel! neq 0 (
        if !errorlevel! equ 2 (
            echo     INFO: %%s was not running >> "%LOGFILE%"
        ) else (
            echo     WARNING: net stop %%s returned !errorlevel! >> "%LOGFILE%"
            set /a WARN_COUNT+=1
        )
    )
    call :Spin
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step2" goto :StepDone

:: -----------------------------------------------
:: STEP 3: Delete BITS queue data files
:: -----------------------------------------------
:Step3
echo [STEP 3] Deleting BITS queue data files...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 3] Delete BITS Queue Data - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

if exist "%ALLUSERSPROFILE%\Application Data\Microsoft\Network\Downloader\qmgr*.dat" (
    del /f /q "%ALLUSERSPROFILE%\Application Data\Microsoft\Network\Downloader\qmgr*.dat" >> "%LOGFILE%" 2>&1
    if !errorlevel! neq 0 (
        echo   WARN: Could not delete qmgr data from Application Data >> "%LOGFILE%"
        set /a WARN_COUNT+=1
    ) else (
        echo   Deleted qmgr data from Application Data >> "%LOGFILE%"
    )
) else (
    echo   No qmgr data in Application Data ^(OK^) >> "%LOGFILE%"
)
if exist "%ALLUSERSPROFILE%\Microsoft\Network\Downloader\qmgr*.dat" (
    del /f /q "%ALLUSERSPROFILE%\Microsoft\Network\Downloader\qmgr*.dat" >> "%LOGFILE%" 2>&1
    if !errorlevel! neq 0 (
        echo   WARN: Could not delete qmgr data from ProgramData >> "%LOGFILE%"
        set /a WARN_COUNT+=1
    ) else (
        echo   Deleted qmgr data from ProgramData >> "%LOGFILE%"
    )
) else (
    echo   No qmgr data in ProgramData ^(OK^) >> "%LOGFILE%"
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step3" goto :StepDone

:: -----------------------------------------------
:: STEP 4: Rename update cache folders (timestamped)
:: -----------------------------------------------
:Step4
echo [STEP 4] Renaming update cache folders...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 4] Renaming Cache Folders - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

:: Use timestamped names so previous backups are preserved
set "SD_BAK=SoftwareDistribution.%TIMESTAMP%.bak"
set "CR_BAK=catroot2.%TIMESTAMP%.bak"

:: Clear attributes before rename
if exist "%SystemRoot%\SoftwareDistribution" (
    attrib -r -s -h /s /d "%SystemRoot%\SoftwareDistribution" >> "%LOGFILE%" 2>&1
    echo   Renaming SoftwareDistribution to %SD_BAK%... >> "%LOGFILE%"
    ren "%SystemRoot%\SoftwareDistribution" "%SD_BAK%" >> "%LOGFILE%" 2>&1
    if !errorlevel! equ 0 (
        echo   SUCCESS: SoftwareDistribution renamed >> "%LOGFILE%"
    ) else (
        echo   FAIL: Could not rename SoftwareDistribution >> "%LOGFILE%"
        set /a FAIL_COUNT+=1
    )
) else (
    echo   WARNING: SoftwareDistribution folder not found >> "%LOGFILE%"
    set /a WARN_COUNT+=1
)

if exist "%SystemRoot%\System32\catroot2" (
    attrib -r -s -h /s /d "%SystemRoot%\System32\catroot2" >> "%LOGFILE%" 2>&1
    echo   Renaming catroot2 to %CR_BAK%... >> "%LOGFILE%"
    ren "%SystemRoot%\System32\catroot2" "%CR_BAK%" >> "%LOGFILE%" 2>&1
    if !errorlevel! equ 0 (
        echo   SUCCESS: catroot2 renamed >> "%LOGFILE%"
    ) else (
        echo   FAIL: Could not rename catroot2 >> "%LOGFILE%"
        set /a FAIL_COUNT+=1
    )
) else (
    echo   WARNING: catroot2 folder not found >> "%LOGFILE%"
    set /a WARN_COUNT+=1
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step4" goto :StepDone

:: -----------------------------------------------
:: STEP 5: Reset BITS transfer queue
:: -----------------------------------------------
:Step5
echo [STEP 5] Resetting BITS queue...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 5] Reset BITS Queue - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"
bitsadmin /reset /allusers >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 (
    echo   WARNING: bitsadmin reset returned !errorlevel! >> "%LOGFILE%"
    set /a WARN_COUNT+=1
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step5" goto :StepDone

:: -----------------------------------------------
:: STEP 6: Export and reset Windows Update policies
::         DISABLED by default - enable with RESET_WU_POLICIES=1
::         Risk: removes WSUS/Intune/WUfB/GPO policy config
:: -----------------------------------------------
:Step6
if "!RESET_WU_POLICIES!"=="1" (
    echo [STEP 6] Exporting and resetting Windows Update policies...
    echo ------------------------------------------------------------ >> "%LOGFILE%"
    echo [STEP 6] WU Policy Export ^& Reset - %TIME% >> "%LOGFILE%"
    echo ------------------------------------------------------------ >> "%LOGFILE%"

    set "POLICY_BACKUP_DIR=%DESKTOP%\WU_PolicyBackup_%TIMESTAMP%"
    :: Initialize flags BEFORE mkdir so they're always defined at :Step6End
    :: POLICY_BACKUP_READY = backup dir was created successfully
    :: POLICY_EXPORTED = at least one key was found and exported (never delete backup dir)
    :: POLICY_FOUND = at least one key was successfully deleted (run gpupdate)
    set "POLICY_BACKUP_READY=0"
    set "POLICY_EXPORTED=0"
    set "POLICY_FOUND=0"

    mkdir "!POLICY_BACKUP_DIR!" >> "%LOGFILE%" 2>&1
    if !errorlevel! neq 0 (
        echo   FAIL: Cannot create backup directory >> "%LOGFILE%"
        set /a FAIL_COUNT+=1
        goto :Step6End
    )
    set "POLICY_BACKUP_READY=1"

    reg query "HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   Exporting HKCU WU policy... >> "%LOGFILE%"
        reg export "HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "!POLICY_BACKUP_DIR!\HKCU_WU_Policy.reg" /y >> "%LOGFILE%" 2>&1
        if !errorlevel! equ 0 (
            reg delete "HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /f >> "%LOGFILE%" 2>&1
            if !errorlevel! equ 0 (
                set "POLICY_FOUND=1"
            ) else (
                echo   WARN: reg delete HKCU WU policy failed ^(key may still exist^) >> "%LOGFILE%"
                set /a WARN_COUNT+=1
            )
            set "POLICY_EXPORTED=1"
        ) else (
            echo   FAIL: Export failed, skipping delete for safety >> "%LOGFILE%"
            set /a FAIL_COUNT+=1
        )
    ) else (
        echo   HKCU WU policy key not present ^(OK^) >> "%LOGFILE%"
    )

    reg query "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   Exporting HKCU CV WU policy... >> "%LOGFILE%"
        reg export "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate" "!POLICY_BACKUP_DIR!\HKCU_CV_WU_Policy.reg" /y >> "%LOGFILE%" 2>&1
        if !errorlevel! equ 0 (
            reg delete "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate" /f >> "%LOGFILE%" 2>&1
            if !errorlevel! equ 0 (
                set "POLICY_FOUND=1"
            ) else (
                echo   WARN: reg delete HKCU CV WU policy failed ^(key may still exist^) >> "%LOGFILE%"
                set /a WARN_COUNT+=1
            )
            set "POLICY_EXPORTED=1"
        ) else (
            echo   FAIL: Export failed, skipping delete for safety >> "%LOGFILE%"
            set /a FAIL_COUNT+=1
        )
    ) else (
        echo   HKCU CV WU policy key not present ^(OK^) >> "%LOGFILE%"
    )

    reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   Exporting HKLM WU policy... >> "%LOGFILE%"
        reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "!POLICY_BACKUP_DIR!\HKLM_WU_Policy.reg" /y >> "%LOGFILE%" 2>&1
        if !errorlevel! equ 0 (
            reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /f >> "%LOGFILE%" 2>&1
            if !errorlevel! equ 0 (
                set "POLICY_FOUND=1"
            ) else (
                echo   WARN: reg delete HKLM WU policy failed ^(key may still exist^) >> "%LOGFILE%"
                set /a WARN_COUNT+=1
            )
            set "POLICY_EXPORTED=1"
        ) else (
            echo   FAIL: Export failed, skipping delete for safety >> "%LOGFILE%"
            set /a FAIL_COUNT+=1
        )
    ) else (
        echo   HKLM WU policy key not present ^(OK^) >> "%LOGFILE%"
    )

    reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   Exporting HKLM CV WU policy... >> "%LOGFILE%"
        reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate" "!POLICY_BACKUP_DIR!\HKLM_CV_WU_Policy.reg" /y >> "%LOGFILE%" 2>&1
        if !errorlevel! equ 0 (
            reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate" /f >> "%LOGFILE%" 2>&1
            if !errorlevel! equ 0 (
                set "POLICY_FOUND=1"
            ) else (
                echo   WARN: reg delete HKLM CV WU policy failed ^(key may still exist^) >> "%LOGFILE%"
                set /a WARN_COUNT+=1
            )
            set "POLICY_EXPORTED=1"
        ) else (
            echo   FAIL: Export failed, skipping delete for safety >> "%LOGFILE%"
            set /a FAIL_COUNT+=1
        )
    ) else (
        echo   HKLM CV WU policy key not present ^(OK^) >> "%LOGFILE%"
    )

    :Step6End
    if "!POLICY_BACKUP_READY!"=="0" (
        :: mkdir failed — already logged as FAIL, nothing more to do
        echo   Skipping policy cleanup ^(backup directory could not be created^) >> "%LOGFILE%"
    ) else if "!POLICY_FOUND!"=="1" (
        echo   Policy backups saved to: !POLICY_BACKUP_DIR! >> "%LOGFILE%"
        echo   Running gpupdate... >> "%LOGFILE%"
        gpupdate /force >> "%LOGFILE%" 2>&1
    ) else if "!POLICY_EXPORTED!"=="1" (
        :: Keys were found and exported but delete failed — keep backup dir, skip gpupdate
        echo   WARN: Policies were exported but deletion failed. Backup preserved at: !POLICY_BACKUP_DIR! >> "%LOGFILE%"
    ) else (
        echo   No WU policies found - nothing to reset >> "%LOGFILE%"
        rmdir "!POLICY_BACKUP_DIR!" >> "%LOGFILE%" 2>&1
    )
    echo. >> "%LOGFILE%"
) else (
    echo [STEP 6] SKIPPED - WU policy reset disabled ^(RESET_WU_POLICIES=0^)
    echo ------------------------------------------------------------ >> "%LOGFILE%"
    echo [STEP 6] SKIPPED - WU policy reset disabled >> "%LOGFILE%"
    if "!_CLI_MODE!"=="1" (
        echo   To enable: rerun with /policy flag >> "%LOGFILE%"
    ) else (
        echo   To enable: return to Main Menu and turn this option ON >> "%LOGFILE%"
    )
    echo ------------------------------------------------------------ >> "%LOGFILE%"
    echo. >> "%LOGFILE%"
    if "!_CLI_MODE!"=="1" if /I "!_STOP_AFTER!"=="Step6" set /a WARN_COUNT+=1
)

call :SpinDone
if /I "!_STOP_AFTER!"=="Step6" goto :StepDone

:: -----------------------------------------------
:: STEP 7: Backup and reset BITS/WU security descriptors
::         DISABLED by default - enable with RESET_SERVICE_SDDL=1
::         Risk: hardcoded SDDL may not match build/vendor ACLs
:: -----------------------------------------------
:Step7
if "!RESET_SERVICE_SDDL!"=="1" (
    echo [STEP 7] Backing up and resetting service security descriptors...
    echo ------------------------------------------------------------ >> "%LOGFILE%"
    echo [STEP 7] Service Security Descriptors - %TIME% >> "%LOGFILE%"
    echo ------------------------------------------------------------ >> "%LOGFILE%"

    echo   --- Current BITS SDDL ^(backup - save this to restore^) --- >> "%LOGFILE%"
    sc sdshow bits >> "%LOGFILE%" 2>&1
    echo. >> "%LOGFILE%"

    echo   --- Current wuauserv SDDL ^(backup - save this to restore^) --- >> "%LOGFILE%"
    sc sdshow wuauserv >> "%LOGFILE%" 2>&1
    echo. >> "%LOGFILE%"

    echo   Resetting BITS security descriptor to default... >> "%LOGFILE%"
    sc.exe sdset bits D:^(A;CI;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY^)^(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA^)^(A;;CCLCSWLOCRRC;;;IU^)^(A;;CCLCSWLOCRRC;;;SU^) >> "%LOGFILE%" 2>&1
    if !errorlevel! neq 0 (
        echo   WARNING: BITS SDDL reset failed - original preserved in log above >> "%LOGFILE%"
        set /a WARN_COUNT+=1
    )

    echo   Resetting wuauserv security descriptor to default... >> "%LOGFILE%"
    sc.exe sdset wuauserv D:^(A;;CCLCSWRPLORC;;;AU^)^(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA^)^(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY^) >> "%LOGFILE%" 2>&1
    if !errorlevel! neq 0 (
        echo   WARNING: wuauserv SDDL reset failed - original preserved in log above >> "%LOGFILE%"
        set /a WARN_COUNT+=1
    )
    echo. >> "%LOGFILE%"
) else (
    echo [STEP 7] SKIPPED - SDDL reset disabled ^(RESET_SERVICE_SDDL=0^)
    echo ------------------------------------------------------------ >> "%LOGFILE%"
    echo [STEP 7] SKIPPED - Service SDDL reset disabled >> "%LOGFILE%"
    if "!_CLI_MODE!"=="1" (
        echo   To enable: rerun with /sddl flag >> "%LOGFILE%"
    ) else (
        echo   To enable: return to Main Menu and turn this option ON >> "%LOGFILE%"
    )
    echo   Current BITS SDDL for reference: >> "%LOGFILE%"
    sc sdshow bits >> "%LOGFILE%" 2>&1
    echo   Current wuauserv SDDL for reference: >> "%LOGFILE%"
    sc sdshow wuauserv >> "%LOGFILE%" 2>&1
    echo ------------------------------------------------------------ >> "%LOGFILE%"
    echo. >> "%LOGFILE%"
    if "!_CLI_MODE!"=="1" if /I "!_STOP_AFTER!"=="Step7" set /a WARN_COUNT+=1
)

call :SpinDone
if /I "!_STOP_AFTER!"=="Step7" goto :StepDone

:: -----------------------------------------------
:: STEP 8: Re-register Windows Update DLLs
:: -----------------------------------------------
:Step8
echo [STEP 8] Re-registering Windows Update DLLs...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 8] Re-registering DLLs - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

:: Change to System32 directory to ensure DLLs are found
cd /d "%windir%\system32"

set /a DLL_OK=0
set /a DLL_SKIP=0
set /a DLL_FAIL=0

for %%d in (
    atl.dll urlmon.dll mshtml.dll shdocvw.dll browseui.dll
    jscript.dll vbscript.dll scrrun.dll msxml.dll msxml3.dll msxml6.dll
    actxprxy.dll softpub.dll wintrust.dll dssenh.dll rsaenh.dll
    gpkcsp.dll sccbase.dll slbcsp.dll cryptdlg.dll
    oleaut32.dll ole32.dll shell32.dll initpki.dll
    wuapi.dll wuaueng.dll wuaueng1.dll wucltui.dll
    wups.dll wups2.dll wuweb.dll qmgr.dll qmgrprxy.dll
    wucltux.dll muweb.dll wuwebv.dll
) do (
    if exist "%windir%\system32\%%d" (
        regsvr32.exe /s %%d
        if !errorlevel! equ 0 (
            set /a DLL_OK+=1
        ) else (
            echo   FAIL: regsvr32 %%d returned error !errorlevel! >> "%LOGFILE%"
            set /a DLL_FAIL+=1
        )
    ) else (
        echo   SKIP: %%d not found in System32 >> "%LOGFILE%"
        set /a DLL_SKIP+=1
    )
)
echo   DLL Summary: !DLL_OK! registered, !DLL_SKIP! not found, !DLL_FAIL! failed >> "%LOGFILE%"
if !DLL_FAIL! gtr 0 set /a WARN_COUNT+=!DLL_FAIL!
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step8" goto :StepDone

:: -----------------------------------------------
:: STEP 9: Reset Winsock and proxy
:: -----------------------------------------------
:Step9
echo [STEP 9] Resetting Winsock and proxy settings...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 9] Network Reset - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

echo   Resetting Winsock... >> "%LOGFILE%"
netsh winsock reset >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 (
    echo   WARNING: netsh winsock reset returned !errorlevel! >> "%LOGFILE%"
    set /a WARN_COUNT+=1
)
echo   --- Current WinHTTP proxy (backup before reset) --- >> "%LOGFILE%"
netsh winhttp show proxy >> "%LOGFILE%" 2>&1
echo   Resetting WinHTTP proxy... >> "%LOGFILE%"
netsh winhttp reset proxy >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 (
    echo   WARNING: netsh winhttp reset proxy returned !errorlevel! >> "%LOGFILE%"
    set /a WARN_COUNT+=1
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step9" goto :StepDone

:: -----------------------------------------------
:: STEP 10: Flush DNS
:: -----------------------------------------------
:Step10
echo [STEP 10] Flushing DNS cache...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 10] DNS Flush - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"
ipconfig /flushdns >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 (
    echo   WARN: DNS flush returned !errorlevel! >> "%LOGFILE%"
    set /a WARN_COUNT+=1
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step10" goto :StepDone

:: -----------------------------------------------
:: STEP 11: Restart services (original startup types preserved)
::          Not forcing auto - just starting what was stopped
:: -----------------------------------------------
:Step11
echo [STEP 11] Restarting Windows Update services...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 11] Restarting Services - %TIME% >> "%LOGFILE%"
echo   (Original startup types recorded in Step 1) >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

for %%s in (cryptSvc bits appidsvc msiserver DoSvc UsoSvc wuauserv TrustedInstaller) do (
    echo   Starting %%s... >> "%LOGFILE%"
    net start %%s >> "%LOGFILE%" 2>&1
    set "_svc_erl=!errorlevel!"
    if !_svc_erl! neq 0 if !_svc_erl! neq 2 (
        echo     WARN: net start %%s failed ^(exit !_svc_erl!^) >> "%LOGFILE%"
        set /a WARN_COUNT+=1
    ) else if !_svc_erl! equ 2 (
        echo     INFO: %%s already running >> "%LOGFILE%"
    )
    call :Spin
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step11" goto :StepDone

:: -----------------------------------------------
:: STEP 12: Capture post-reset service status
:: -----------------------------------------------
:Step12
echo [STEP 12] Capturing post-reset service status...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 12] Post-Reset Service Status - %TIME% >> "%LOGFILE%"
echo   (Some services like msiserver/TrustedInstaller may >> "%LOGFILE%"
echo    legitimately be stopped - this is normal) >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

for %%s in (wuauserv cryptSvc bits msiserver appidsvc UsoSvc DoSvc TrustedInstaller) do (
    echo   %%s: >> "%LOGFILE%"
    sc query %%s 2>&1 | findstr /I "STATE" >> "%LOGFILE%" 2>&1
    sc qc %%s 2>&1 | findstr /I "START_TYPE" >> "%LOGFILE%" 2>&1
    echo. >> "%LOGFILE%"
)

call :SpinDone
if /I "!_STOP_AFTER!"=="Step12" goto :StepDone

:: -----------------------------------------------
:: STEP 13: Check Windows Update connectivity
:: -----------------------------------------------
:Step13
echo [STEP 13] Testing Windows Update connectivity...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 13] WU Connectivity Test - %TIME% >> "%LOGFILE%"
echo   (NOTE: These are basic HTTPS reachability checks only. >> "%LOGFILE%"
echo    A pass does not guarantee WU functionality; a fail >> "%LOGFILE%"
echo    may indicate proxy, firewall, or DNS issues.) >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

set "_conn_fail=0"
echo   Testing connection to Microsoft Update... >> "%LOGFILE%"
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -Uri 'https://update.microsoft.com' -UseBasicParsing -TimeoutSec 15; Write-Output \"  Status: $($r.StatusCode) - OK\"; exit 0 } catch { Write-Output \"  FAILED: $($_.Exception.Message)\"; exit 1 }" >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 set "_conn_fail=1"

echo   Testing connection to Windows Update CDN... >> "%LOGFILE%"
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -Uri 'https://download.windowsupdate.com' -UseBasicParsing -TimeoutSec 15; Write-Output \"  Status: $($r.StatusCode) - OK\"; exit 0 } catch { Write-Output \"  FAILED: $($_.Exception.Message)\"; exit 1 }" >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 set "_conn_fail=1"

if "!_conn_fail!"=="1" (
    echo   FINDING: WU connectivity check failed >> "%LOGFILE%"
    set /a DIAG_FINDINGS+=1
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="Step13" goto :StepDone

:: -----------------------------------------------
:: STEP 14: Capture current update history
:: -----------------------------------------------
:Step14
echo [STEP 14] Capturing current update history...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [STEP 14] Recent Update History - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

powershell -NoProfile -Command "Get-HotFix | Sort-Object InstalledOn -Descending -ErrorAction SilentlyContinue | Select-Object -First 10 | Format-Table HotFixID, InstalledOn, Description -AutoSize | Out-String -Width 200" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"

call :SpinDone
goto :StepDone

:: -----------------------------------------------
:: SYSTEM FIX: DISM - Repair Component Store
:: -----------------------------------------------
:FixDISM
echo [FIX] DISM - Repairing component store...
echo   This may take 10-30 minutes. Do not interrupt.
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [FIX] DISM /Online /Cleanup-Image /RestoreHealth - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

set "_DISM_FIX_TMP=%TEMP%\rwu_dism_fix_%RANDOM%.txt"
DISM /Online /Cleanup-Image /RestoreHealth > "!_DISM_FIX_TMP!" 2>&1
set "_dism_fix_erl=!errorlevel!"
type "!_DISM_FIX_TMP!" >> "%LOGFILE%"
echo   DISM RestoreHealth exit code: !_dism_fix_erl! >> "%LOGFILE%"
if !_dism_fix_erl! neq 0 (
    echo   FAIL: DISM RestoreHealth failed ^(exit code !_dism_fix_erl!^) >> "%LOGFILE%"
    echo   TIP: If DISM failed, try running with a Windows ISO as source: >> "%LOGFILE%"
    echo   DISM /Online /Cleanup-Image /RestoreHealth /Source:D:\sources >> "%LOGFILE%"
    set /a FAIL_COUNT+=1
) else (
    echo   SUCCESS: Component store repair completed >> "%LOGFILE%"
    :: Check if repairs were actually made (use /C: for literal phrase match)
    findstr /I /C:"successfully repaired" "!_DISM_FIX_TMP!" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   FINDING: DISM repaired component store corruption >> "%LOGFILE%"
        set /a DIAG_FINDINGS+=1
    )
)
del "!_DISM_FIX_TMP!" >nul 2>&1
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="FixDISM" goto :StepDone

:: -----------------------------------------------
:: SYSTEM FIX: SFC - System File Checker
:: -----------------------------------------------
:FixSFC
echo [FIX] SFC - Scanning system files...
echo   This may take 5-15 minutes. Do not interrupt.
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [FIX] sfc /scannow - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

set "_SFC_TMP=%TEMP%\rwu_sfc_%RANDOM%.txt"
sfc /scannow > "!_SFC_TMP!" 2>&1
set "_sfc_erl=!errorlevel!"
type "!_SFC_TMP!" >> "%LOGFILE%"
echo   SFC exit code: !_sfc_erl! >> "%LOGFILE%"

:: SFC exit codes: 0=no issues, 1=found+fixed, 2=found but couldn't fix
:: Check exit code first, then parse output text for details
if !_sfc_erl! neq 0 (
    :: Non-zero exit code — SFC encountered a problem
    findstr /I /C:"found corrupt files" "!_SFC_TMP!" >nul 2>&1
    if !errorlevel! equ 0 (
        findstr /I /C:"unable to fix" "!_SFC_TMP!" >nul 2>&1
        if !errorlevel! equ 0 (
            echo   FAIL: SFC found corrupt files but could not fix all of them >> "%LOGFILE%"
            echo   TIP: Run DISM /RestoreHealth first, then re-run SFC >> "%LOGFILE%"
            set /a FAIL_COUNT+=1
        ) else (
            echo   FINDING: SFC found and repaired corrupt system files >> "%LOGFILE%"
            set /a DIAG_FINDINGS+=1
        )
    ) else (
        echo   FAIL: SFC returned exit code !_sfc_erl! >> "%LOGFILE%"
        set /a FAIL_COUNT+=1
    )
) else (
    :: Zero exit code — check output text for confirmation
    findstr /I /C:"did not find any integrity violations" "!_SFC_TMP!" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   OK: No integrity violations found >> "%LOGFILE%"
    ) else (
        findstr /I /C:"found corrupt files" "!_SFC_TMP!" >nul 2>&1
        if !errorlevel! equ 0 (
            echo   FINDING: SFC found and repaired corrupt system files >> "%LOGFILE%"
            set /a DIAG_FINDINGS+=1
        ) else (
            echo   OK: SFC completed with exit code 0 >> "%LOGFILE%"
        )
    )
)

:: Capture relevant CBS.log tail for context
echo   --- Last CBS.log entries after SFC --- >> "%LOGFILE%"
powershell -NoProfile -Command "if (Test-Path 'C:\Windows\Logs\CBS\CBS.log') { Get-Content 'C:\Windows\Logs\CBS\CBS.log' -Tail 200 | Select-String -Pattern 'Verify complete|Cannot repair|Corrupt|Hashes for' -CaseSensitive:$false | Select-Object -Last 10 | ForEach-Object { $_.Line.Trim() } } else { Write-Output '  CBS.log not found' }" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"

del "!_SFC_TMP!" >nul 2>&1

call :SpinDone
if /I "!_STOP_AFTER!"=="FixSFC" goto :StepDone

:: -----------------------------------------------
:: SYSTEM FIX: CHKDSK - Schedule Disk Check
:: -----------------------------------------------
:FixCHKDSK
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [FIX] CHKDSK - Schedule Disk Check - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

:: Interactive mode gets a confirmation prompt; CLI skips it
if "!_CLI_MODE!"=="1" goto :FixCHKDSK_Run

call :BlankScreen
echo.
echo  ================================================================
echo     WARNING: Schedule Disk Check (CHKDSK)
echo  ================================================================
echo.
echo   This will schedule a disk check on your NEXT REBOOT.
echo.
echo   - The check runs BEFORE Windows starts
echo   - It can take 30-120 minutes depending on disk size
echo   - Do NOT interrupt it or power off during the check
echo   - Your PC will reboot to Windows automatically when done
echo.
echo  ================================================================
echo.
call :Choice /C:YN /N /M "  Schedule CHKDSK on next reboot? [Y/N]: "
if not defined _AUTOKEYS set "_erl=!errorlevel!"
if !_erl!==2 (
    echo   CHKDSK scheduling cancelled by user >> "%LOGFILE%"
    echo   Cancelled.
    call :SpinDone
    goto :StepDone
)

:FixCHKDSK_Run
echo [FIX] CHKDSK - Scheduling disk check...
call :Spin

:: Log current disk health first
echo   --- Current disk status --- >> "%LOGFILE%"
powershell -NoProfile -Command "Get-Volume -DriveLetter C -ErrorAction SilentlyContinue | Select-Object DriveLetter, FileSystem, HealthStatus, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, @{N='FreeGB';E={[math]::Round($_.SizeRemaining/1GB,1)}} | Format-List" >> "%LOGFILE%" 2>&1

echo   Scheduling chkdsk C: /f /r ... >> "%LOGFILE%"
echo Y | chkdsk C: /f /r >> "%LOGFILE%" 2>&1
set "_chk_erl=!errorlevel!"
echo   CHKDSK exit code: !_chk_erl! >> "%LOGFILE%"

if !_chk_erl! neq 0 (
    :: chkdsk returns non-zero when it schedules for reboot - this is expected
    echo   INFO: CHKDSK scheduled for next reboot >> "%LOGFILE%"
    echo   Reboot your computer to begin the disk check. >> "%LOGFILE%"
) else (
    echo   INFO: CHKDSK completed or scheduled >> "%LOGFILE%"
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="FixCHKDSK" goto :StepDone

:: -----------------------------------------------
:: SYSTEM FIX: Reset Proxy Settings
:: -----------------------------------------------
:FixProxy
echo [FIX] Resetting WinHTTP proxy settings...
call :Spin
echo ------------------------------------------------------------ >> "%LOGFILE%"
echo [FIX] Reset WinHTTP Proxy - %TIME% >> "%LOGFILE%"
echo ------------------------------------------------------------ >> "%LOGFILE%"

echo   --- Current WinHTTP proxy (before reset) --- >> "%LOGFILE%"
netsh winhttp show proxy >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"

echo   Resetting WinHTTP proxy to direct... >> "%LOGFILE%"
netsh winhttp reset proxy >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 (
    echo   WARNING: netsh winhttp reset proxy returned !errorlevel! >> "%LOGFILE%"
    set /a WARN_COUNT+=1
) else (
    echo   SUCCESS: WinHTTP proxy reset to direct connection >> "%LOGFILE%"
)
echo. >> "%LOGFILE%"

call :SpinDone
if /I "!_STOP_AFTER!"=="FixProxy" goto :StepDone

:: -----------------------------------------------
:: SCREEN AND SPINNER SUBROUTINES
:: -----------------------------------------------

:BlankScreen
:: Clear viewport AND scrollback buffer using ANSI sequences.
:: Works in both conhost.exe and Windows Terminal.
<nul set /p "=!ESC![2J!ESC![3J!ESC![H"
exit /b

:Spin
:: Overwrite current console line with next spinner frame.
:: ESC[G = cursor to column 0, ESC[K = clear to end of line.
:: Skipped in CLI mode (automation should not get control sequences).
if "!_CLI_MODE!"=="1" exit /b
set /a _SP=(_SP+1) %% 4
if !_SP!==0 <nul set /p "=!ESC![G!ESC![K  Working... [|]"
if !_SP!==1 <nul set /p "=!ESC![G!ESC![K  Working... [/]"
if !_SP!==2 <nul set /p "=!ESC![G!ESC![K  Working... [-]"
if !_SP!==3 <nul set /p "=!ESC![G!ESC![K  Working... [\]"
exit /b

:SpinDone
:: End spinner line with [Done]
if "!_CLI_MODE!"=="1" (
    echo.
    exit /b
)
<nul set /p "=!ESC![G!ESC![K"
echo   Done.
exit /b

:: -----------------------------------------------
:: DONE - Summary with warning/failure counts
:: -----------------------------------------------
:StepDone
call :Trace "entering :StepDone"
if not "!_CLI_MODE!"=="1" call :BlankScreen
echo ============================================================ >> "%LOGFILE%"
if !FAIL_COUNT! gtr 0 (
    echo  COMPLETED WITH ERRORS: %DATE% %TIME% >> "%LOGFILE%"
    echo  Critical failures: !FAIL_COUNT! >> "%LOGFILE%"
    echo  Warnings: !WARN_COUNT! >> "%LOGFILE%"
) else if !WARN_COUNT! gtr 0 (
    echo  COMPLETED WITH WARNINGS: %DATE% %TIME% >> "%LOGFILE%"
    echo  Warnings: !WARN_COUNT! >> "%LOGFILE%"
) else (
    echo  COMPLETED SUCCESSFULLY: %DATE% %TIME% >> "%LOGFILE%"
)
if !DIAG_FINDINGS! gtr 0 (
    echo  Diagnostic findings: !DIAG_FINDINGS! ^(review log for FINDING lines^) >> "%LOGFILE%"
)
echo. >> "%LOGFILE%"
echo  Log: %LOGFILE% >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"

echo.
echo  ================================================================
echo  Ran: !_RUN_LABEL!
echo.
if !FAIL_COUNT! gtr 0 (
    echo  DONE - !FAIL_COUNT! ERRORS, !WARN_COUNT! WARNINGS
) else if !WARN_COUNT! gtr 0 (
    echo  DONE - !WARN_COUNT! WARNINGS
) else (
    echo  DONE - NO SCRIPT ERRORS RECORDED.
)
if !DIAG_FINDINGS! gtr 0 (
    echo  !DIAG_FINDINGS! diagnostic findings detected. Review log for details.
)
echo.
echo  Log saved to: %LOGFILE%
if /I not "!_STOP_AFTER!"=="Step0" (
    echo.
    echo  ** If repair actions were performed, reboot is recommended **
)
if /I "!_STOP_AFTER!"=="Step2" (
    if "!_CLI_MODE!"=="1" (
        echo  ** Services were stopped. Run /step finalize or reboot now **
    ) else (
        echo  ** Services were stopped. Run Finalize [A] or reboot now **
    )
)
echo.
echo  ________________________________________________________________
if /I "!_STOP_AFTER!"=="Step0" (
    echo  NEXT STEPS:
    echo  - Review the diagnostic log
    echo  - Paste the log into ChatGPT, Copilot, or Claude for
    echo    AI-powered analysis and actionable recommendations
    echo  No repair changes were made. No reboot required.
) else (
    echo  NEXT STEPS:
    echo  - Reboot the computer
    echo  - Go to Settings ^> Windows Update ^> Check for updates
    echo  - If issues persist, paste the log into ChatGPT, Copilot,
    echo    or Claude for AI-powered troubleshooting
)
echo.
echo  Note: The log may contain system, network, and license details.
echo  Review it before sharing with any external tool or service.
echo  ________________________________________________________________

:: In CLI mode, skip interactive menu and exit with code
if "!_CLI_MODE!"=="1" (
    if !FAIL_COUNT! gtr 0 (
        endlocal
        exit /b 1
    )
    if !WARN_COUNT! gtr 0 (
        endlocal
        exit /b 2
    )
    endlocal
    exit /b 0
)

echo.
echo     [1]  Return to Main Menu
echo     [0]  Exit
echo  ================================================================
echo.
call :Choice /C:10 /N /M "  Choose [1,0]: "
if not defined _AUTOKEYS set "_erl=!errorlevel!"
if !_erl!==1 (
    set /a WARN_COUNT=0
    set /a FAIL_COUNT=0
    set /a DIAG_FINDINGS=0
    goto :MainMenu
)

endlocal
exit /b 0

:: -----------------------------------------------
:: DEBUG / TRACE SUBROUTINES
:: -----------------------------------------------

:DebugInit
:: Initialize the debug log file with a header
echo. >> "!DEBUGLOG!"
echo ============================================================ >> "!DEBUGLOG!"
echo  RWU Debug Trace Log >> "!DEBUGLOG!"
echo  Started: %DATE% %TIME% >> "!DEBUGLOG!"
echo  Version: !ver! >> "!DEBUGLOG!"
echo  CLI Mode: !_CLI_MODE! >> "!DEBUGLOG!"
echo  ComSpec: %COMSPEC% >> "!DEBUGLOG!"
echo  Script: %~f0 >> "!DEBUGLOG!"
echo  CmdLine: %CMDCMDLINE% >> "!DEBUGLOG!"
echo ============================================================ >> "!DEBUGLOG!"
if "!_CLI_MODE!"=="0" (
    echo.
    echo  [DEBUG] Trace logging enabled: !DEBUGLOG!
    echo.
)
exit /b

:Trace
:: Write a timestamped trace line to the debug log.
:: Usage: call :Trace "message"
:: No-op when DEBUG=0 for zero overhead in normal mode.
if "!DEBUG!"=="0" exit /b
echo [%TIME%] %~1 >> "!DEBUGLOG!" 2>nul
exit /b

:Choice
:: Wrapper around choice.exe. In autokeys mode, pops the next value from
:: _AUTOKEYS and sets errorlevel. In normal mode, passes all args to choice.
:: Usage: call :Choice /C:123456780 /N /M "prompt"
::   Sets: _erl = errorlevel from choice (or from autokeys)
if not defined _AUTOKEYS (
    choice %*
    set "_erl=!errorlevel!"
    exit /b !_erl!
)
:: Pop next key from _autokeys sequence
set /a _AUTOKEY_POS+=1
set "_ak_cur=!_AUTOKEYS!"
set "_ak_val="
set /a _ak_idx=1
:ChoicePop
:: Extract next comma-delimited value
for /f "tokens=1* delims=." %%a in ("!_ak_cur!") do (
    if !_ak_idx! equ !_AUTOKEY_POS! (
        set "_ak_val=%%a"
        goto :ChoicePopDone
    )
    set "_ak_cur=%%b"
    set /a _ak_idx+=1
    if defined _ak_cur goto :ChoicePop
)
:ChoicePopDone
if not defined _ak_val (
    call :Trace "AUTOKEYS: sequence exhausted at pos !_AUTOKEY_POS!, defaulting to 1"
    set "_ak_val=1"
)
call :Trace "AUTOKEYS: pos=!_AUTOKEY_POS! value=!_ak_val!"
set "_erl=!_ak_val!"
exit /b
