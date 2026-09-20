@echo off
chcp 65001 >nul
title Offline POS
cd /d "%~dp0"

:: First-run: Visual C++ runtime (fixes VCRUNTIME140_1.dll missing)
if exist "%~dp0tools\install_vcredist.bat" (
  call "%~dp0tools\install_vcredist.bat"
  if errorlevel 1 (
    echo.
    echo Could not install Visual C++ Redistributable.
    echo Open tools\vcredist\VC_redist.x64.exe and install, then try again.
    pause
    exit /b 1
  )
)

if not exist "%~dp0offline_pos.exe" (
  echo offline_pos.exe not found next to this script.
  pause
  exit /b 1
)

start "" "%~dp0offline_pos.exe"
exit /b 0
