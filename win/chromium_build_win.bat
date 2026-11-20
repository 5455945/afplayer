@echo off
rem ============================================================================
rem  chromium_build_win.bat
rem  ---------------------------------------------------------------------------
rem  Entry point for the Chromium Windows build. It simply forwards every
rem  argument to chromium_build_win.ps1, which does the real work:
rem    - locates the source tree (relative to the scripts, or --dir)
rem    - repairs build\win_toolchain.json when the checkout was moved
rem    - runs gn gen + autoninja for the requested targets
rem  No network access and no gclient calls are made here; download/sync/hooks
rem  and the offline export live in chromium_download_win.bat.
rem
rem  Usage examples:
rem    chromium_build_win.bat
rem    chromium_build_win.bat --dir D:\chromium --release --targets content_shell
rem    chromium_build_win.bat --check
rem    chromium_build_win.bat --help
rem    .\init_tools\win\chromium_build_win.bat --ide vs2022 -j16 --targets chrome --args="target_os=\"win\" target_cpu=\"x64\" is_component_build=false is_debug=false is_official_build=true google_api_key=false google_default_client_id=false google_default_client_secret=false proprietary_codecs=true media_use_ffmpeg=true ffmpeg_branding=\"Chrome\" enable_mse_mpeg2ts_stream_parser=true symbol_level=1 blink_symbol_level=1 v8_symbol_level=1 "
rem ============================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT=%~dp0chromium_build_win.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Could not find "%SCRIPT%".
    exit /b 1
)

set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

rem ---- Preflight: can PowerShell actually run this script? --------------------
rem A trivial -Command is not enough: execution policy applies to script FILES.
rem Running the script with --help is fast, side-effect free and proves the file
rem is allowed to execute. Its output is captured so we can show the reason.
set "PRELOG=%TEMP%\chromium_build_win_preflight_%RANDOM%.log"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" --help >"%PRELOG%" 2>&1
set "PREERR=%ERRORLEVEL%"
if not "%PREERR%"=="0" (
    echo [ERROR] PowerShell could not run "%SCRIPT%".
    echo.
    echo --- PowerShell output ----------------------------------------------------
    type "%PRELOG%"
    echo ---------------------------------------------------------------------------
    echo.
    echo Common causes and how to fix them:
    echo.
    echo   1^) Execution policy blocks scripts
    echo        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    echo      or run manually:
    echo        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" --help
    echo.
    echo   2^) File was downloaded from the Internet ^(Mark of the Web^)
    echo        powershell -NoProfile -Command "Unblock-File -Path '%SCRIPT%'"
    echo.
    echo   3^) Managed PC with AppLocker / WDAC / Constrained Language
    echo        Scripting may be disabled by policy. Check with:
    echo          Get-AppLockerPolicy -Effective -Xml
    echo          Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
    echo        A user cannot turn this off; ask your administrator or use an
    echo        unmanaged machine.
    del "%PRELOG%" >nul 2>nul
    exit /b %PREERR%
)
del "%PRELOG%" >nul 2>nul

rem ---- Run the real build -----------------------------------------------------
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
