@echo off
chcp 65001 >nul
title Offline POS - ZK Fingerprint Agent (local)
cd /d "%~dp0"

set "SILENT="
if /I "%~1"=="silent" set "SILENT=1"
if /I "%~1"=="/silent" set "SILENT=1"

if not defined SILENT (
  echo ============================================================
  echo  Offline POS - ZK Fingerprint Agent  ^(127.0.0.1:9201^)
  echo  Auto-setup + local only
  echo ============================================================
  echo.
  echo  NOTE: Needs Python 3.10 / 3.11 / 3.12  ^(NOT 3.13 or 3.14^)
  echo        If missing, this script downloads embeddable 3.11
  echo        ^(no Microsoft Store Python required^).
  echo.
)

set "STATUS_DIR=%LOCALAPPDATA%\OfflinePOS"
mkdir "%STATUS_DIR%" >nul 2>&1

for /f "tokens=5" %%a in ('netstat -ano 2^>nul ^| findstr ":9201 " ^| findstr "LISTENING"') do (
  taskkill /PID %%a /F >nul 2>&1
)

:: Already have bundled 3.11 from a previous run?
set "PY="
if exist "%~dp0.py311\python.exe" set "PY=%~dp0.py311\python.exe"
if exist "%~dp0.venv311\Scripts\python.exe" set "PY=%~dp0.venv311\Scripts\python.exe"

:: Prefer real system 3.11 / 3.12 / 3.10 via py launcher (not Store alias)
if not defined PY (
  where py >nul 2>&1 && for /f "delims=" %%P in ('py -3.11 -c "import sys; print(sys.executable)" 2^>nul') do set "PY=%%P"
)
if not defined PY (
  where py >nul 2>&1 && for /f "delims=" %%P in ('py -3.12 -c "import sys; print(sys.executable)" 2^>nul') do set "PY=%%P"
)
if not defined PY (
  where py >nul 2>&1 && for /f "delims=" %%P in ('py -3.10 -c "import sys; print(sys.executable)" 2^>nul') do set "PY=%%P"
)

:: No good system Python: PowerShell downloads embeddable 3.11 (no python.exe needed)
if not defined PY (
  if not defined SILENT echo [..] No Python 3.10-3.12 — downloading embeddable 3.11 via PowerShell...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zk_bootstrap_python.ps1" 1>"%TEMP%\zk_py_path.txt" 2>&1
  type "%TEMP%\zk_py_path.txt" 2>nul
  if exist "%~dp0.py311\python.exe" set "PY=%~dp0.py311\python.exe"
)

if not defined PY if exist "%~dp0.py311\python.exe" set "PY=%~dp0.py311\python.exe"

if not defined PY (
  echo [X] Could not resolve Python 3.11
  echo     Check internet, or install from:
  echo     https://www.python.org/downloads/release/python-3119/
  if not defined SILENT pause
  exit /b 1
)

if not defined SILENT echo [OK] Python: %PY%

:: If ZK9500 USB is in Error and we have zk_driver, offer elevated install once
if exist "%~dp0zk_driver\zkusbdevices.inf" if not exist "%STATUS_DIR%\zk_driver_ok.flag" (
  if not defined SILENT echo [..] ZK USB driver may need Administrator install...
  call "%~dp0install_zk_driver.bat" nopause
)

if not defined SILENT echo [..] Checking / installing fingerprint libraries...
"%PY%" "%~dp0zk_setup_check.py"
if errorlevel 1 (
  if not defined SILENT (
    echo [X] Setup blocked — %STATUS_DIR%\zk_setup_status.json
    type "%STATUS_DIR%\zk_setup_status.json" 2>nul
    pause
  )
  exit /b 1
)

if exist "%~dp0zk_sdk\libzkfp.dll" set "PATH=%~dp0zk_sdk;%~dp0;%PATH%"
if not exist "%~dp0zk_sdk\libzkfp.dll" if exist "%~dp0libzkfp.dll" set "PATH=%~dp0;%PATH%"

if not defined SILENT echo Starting ZK Fingerprint Agent...
"%PY%" "%~dp0zk_fingerprint_agent.py"
set "EXITCODE=%ERRORLEVEL%"
if not defined SILENT (
  echo.
  echo [Agent stopped]
  pause
)
exit /b %EXITCODE%
