@echo off
chcp 65001 >nul
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\OfflinePOS ZK Fingerprint Agent.lnk"
if exist "%LNK%" (
  del /f /q "%LNK%"
  echo Removed from Windows Startup.
) else (
  echo Was not installed.
)
pause
