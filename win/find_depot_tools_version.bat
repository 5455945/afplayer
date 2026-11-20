@echo off
rem ============================================================================
rem  find_depot_tools_version.bat
rem  Thin launcher for find_depot_tools_version.ps1 (forwards all arguments).
rem ============================================================================
setlocal EnableExtensions

set "SCRIPT=%~dp0find_depot_tools_version.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Could not find "%SCRIPT%".
    exit /b 1
)

set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
