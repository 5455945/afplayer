@echo off
rem ============================================================================
rem  chromium_download_win.bat
rem  ---------------------------------------------------------------------------
rem  Entry point for downloading/preparing Chromium on Windows. It forwards every
rem  argument to chromium_download_win.ps1, which does the network work:
rem    - downloads git (portable) / depot_tools / Chromium source + deps
rem    - runs gclient sync + gclient runhooks (complete Windows toolchain)
rem    - with --make-offline-repo: folds everything into <src>\init_tools and
rem      commits it, producing a self-contained repo (build it afterwards with
rem      chromium_build_win.bat, which needs no network). The download workspace
rem      is kept by default (--cleanup deletes it) and a completion marker makes
rem      an identical later run skip all network work.
rem
rem  Usage examples:
rem    chromium_download_win.bat --dir D:\chromium --version 7871
rem    chromium_download_win.bat --dir D:\offline --version 7871 --make-offline-repo
rem    chromium_download_win.bat --dir D:\offline --version 7871 --make-offline-repo --cleanup
rem   .\chromium_download_win.bat --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive"
rem   .\chromium_download_win.bat --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --dest-name chromium150
rem   .\chromium_download_win.bat --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --make-offline-repo
rem   .\chromium_download_win.bat --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --make-offline-repo --cleanup
rem    chromium_download_win.bat --help
rem ============================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT=%~dp0chromium_download_win.ps1"
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
set "PRELOG=%TEMP%\chromium_download_win_preflight_%RANDOM%.log"
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

rem ---- Run the real download --------------------------------------------------
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
