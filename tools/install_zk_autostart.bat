@echo off
chcp 65001 >nul
:: Register the fingerprint agent to start when Windows signs in.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_zk_autostart.ps1"
if errorlevel 1 (
  echo Failed.
  pause
  exit /b 1
)
echo.
echo Done. The agent will start on the next Windows sign-in.
echo To start it now: start_zk_agent.bat
pause
