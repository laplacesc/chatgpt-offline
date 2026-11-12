@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions DisableDelayedExpansion
title Install ChatGPT Desktop

rem ---- Appx requires Windows PowerShell, even when pwsh is installed ----
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

cd /d "%~dp0"
set "NO_PAUSE="
set "FORWARD_ARGS="
rem Normalize only a drive root before crossing the native powershell.exe boundary.
rem CMD keeps the trailing backslash, but the native argument parser can escape its closing quote.
:parse_args
if "%~1"=="" goto args_ready
if /I "%~1"=="-InstallDrive" goto parse_drive
if /I "%~1"=="-NoPause" set "NO_PAUSE=1"
set FORWARD_ARGS=%FORWARD_ARGS% "%~1"
shift /1
goto parse_args
:parse_drive
set "DRIVE=%~2"
if "%DRIVE:~1%"==":\" set "DRIVE=%DRIVE:~0,2%"
set FORWARD_ARGS=%FORWARD_ARGS% "-InstallDrive" "%DRIVE%"
shift /1
shift /1
goto parse_args
:args_ready
set "RESULT=%TEMP%\chatgpt-install-%RANDOM%-%RANDOM%-%RANDOM%.json"
if exist "%RESULT%" del /q "%RESULT%" >nul 2>&1
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\launch-chatgpt-desktop.ps1" -Operation install -ResultPath "%RESULT%" %FORWARD_ARGS%
set "RC=%errorlevel%"
if not exist "%RESULT%" (
    echo [X] Could not confirm task completion. The launcher may have been interrupted.
    echo     Retry, or right-click this file and choose "Run as administrator".
    echo     Check the log folder for details.
    set "RC=1"
)
if not "%RC%"=="0" echo [X] Installation did not complete successfully. Check the messages and log folder.
if exist "%RESULT%" del /q "%RESULT%" >nul 2>&1
if not defined NO_PAUSE pause
endlocal & exit /b %RC%
