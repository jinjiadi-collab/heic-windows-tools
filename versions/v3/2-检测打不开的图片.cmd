@echo off
setlocal
set "HEIC_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "HEIC_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%HEIC_PS%" -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0Refresh.ps1" -Mode Diagnose
set "HEIC_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %HEIC_RESULT%