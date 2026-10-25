@echo off
setlocal EnableExtensions
title Velocity11 - Windows 11 privacy + gaming performance

rem ---------------------------------------------------------------------------
rem Single-click launcher for a portable copy of Velocity11 (USB stick, any PC).
rem
rem   * resolves Velocity11.ps1 next to THIS file, so the drive letter and the
rem     folder the stick picked up never matter
rem   * runs the powershell.exe built into Windows - nothing has to be installed
rem   * -ExecutionPolicy Bypass applies to this process only, so a downloaded or
rem     locked-down copy still runs and no system policy is changed
rem   * keeps the window open after an error so nothing disappears silently
rem
rem Whatever Velocity11 changes is written to a snapshot folder next to this file
rem BEFORE anything is touched, and [r] in the menu puts it all back.
rem ---------------------------------------------------------------------------

set "HERE=%~dp0"
set "TOOL=%HERE%Velocity11.ps1"

if not exist "%TOOL%" (
    echo.
    echo  Velocity11.ps1 was not found next to this launcher:
    echo      %TOOL%
    echo.
    echo  Keep Velocity11.cmd and Velocity11.ps1 together in the same folder.
    echo.
    pause
    exit /b 1
)

rem  -STA is required for the graphical window.
echo  Starting Velocity11 - accept the UAC prompt to get the full window.
echo.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%TOOL%" %*
set "RC=%ERRORLEVEL%"

rem 7 = Velocity11 handed off to an elevated window; that one stays on its own.
if "%RC%"=="7" exit /b 0

if not "%RC%"=="0" (
    echo.
    echo  Velocity11 exited with code %RC%.
)
echo.
pause
exit /b %RC%
