@echo off
rem ============================================================================
rem  bootstrap_depot_tools.bat
rem  Thin launcher for bootstrap_depot_tools.ps1 (forwards all arguments).
rem ============================================================================
setlocal EnableExtensions

set "SCRIPT=%~dp0bootstrap_depot_tools.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Could not find "%SCRIPT%".
    exit /b 1
)

set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
