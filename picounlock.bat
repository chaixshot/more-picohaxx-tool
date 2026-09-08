@echo off
setlocal EnableDelayedExpansion

:: Elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Requesting Administrator Privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList 'am_admin' -Verb RunAs"
    exit /b
)

:: Set Working Directory & Paths
cd /d "%~dp0"
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "TARGET_SCRIPT=%~dp0picounlock.ps1"

:: Validate target script exists
if not exist "%TARGET_SCRIPT%" (
    echo [ERROR] Could not find: "%TARGET_SCRIPT%"
    echo Please make sure 'picounlock.ps1' is in the same folder as this batch file.
    echo.
    pause
    exit /b 1
)

:: Detect PowerShell Executable (Prefer pwsh.exe over powershell.exe)
set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>&1
if %errorlevel% equ 0 (
    set "PS_EXE=pwsh.exe"
    echo [INFO] Using PowerShell 7+ (pwsh.exe)
) else (
    echo [INFO] Using Windows PowerShell (powershell.exe)
)

:: Check for Windows Terminal (wt.exe)
set "WT_EXE="
where wt.exe >nul 2>&1
if %errorlevel% equ 0 (
    set "WT_EXE=wt.exe"
) else if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe" (
    set "WT_EXE=%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe"
)

:: Launch Script
if defined WT_EXE (
    echo [LAUNCH] Starting in Windows Terminal...
    "%WT_EXE%" -d "%SCRIPT_DIR%" cmd.exe /c "!PS_EXE! -ExecutionPolicy Bypass -File "%TARGET_SCRIPT%" || pause"
) else (
    echo [WARNING] Windows Terminal not found. Falling back to default console...
    !PS_EXE! -ExecutionPolicy Bypass -File "%TARGET_SCRIPT%"
    if %errorlevel% neq 0 pause
)

exit /b 0