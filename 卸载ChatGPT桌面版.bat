@echo off
chcp 65001 >nul 2>&1
setlocal DisableDelayedExpansion
title Uninstall ChatGPT Desktop

rem ---- Appx requires Windows PowerShell, even when pwsh is installed ----
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

cd /d "%~dp0"
set "NO_PAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "NO_PAUSE=1"
set "RESULT=%TEMP%\chatgpt-uninstall-%RANDOM%-%RANDOM%-%RANDOM%.json"
if exist "%RESULT%" del /q "%RESULT%" >nul 2>&1
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\launch-chatgpt-desktop.ps1" -Operation uninstall -ResultPath "%RESULT%" %*
set "RC=%errorlevel%"
if not exist "%RESULT%" (
    echo [X] Could not confirm task completion. The launcher may have been interrupted.
    echo     Retry, or right-click this file and choose "Run as administrator".
    echo     Check the log folder for details.
    set "RC=1"
)
if not "%RC%"=="0" echo [X] Uninstallation did not complete successfully. Check the messages and log folder.
if exist "%RESULT%" del /q "%RESULT%" >nul 2>&1
if not defined NO_PAUSE pause
endlocal & exit /b %RC%
