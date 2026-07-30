@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
    "if (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"
if not "%errorlevel%"=="0" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ^
    "%~dp0Install-VidReclaimWorker.ps1"

echo.
if not "%errorlevel%"=="0" (
    echo Setup did not complete. Review the error above.
)
pause
