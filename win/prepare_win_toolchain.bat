@echo off
rem ============================================================================
rem  prepare_win_toolchain.bat
rem  Thin launcher for prepare_win_toolchain.ps1 (forwards all arguments).
rem ============================================================================
setlocal EnableExtensions

set "SCRIPT=%~dp0prepare_win_toolchain.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Could not find "%SCRIPT%".
    exit /b 1
)

set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
