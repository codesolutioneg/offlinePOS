@echo off
chcp 65001 >nul
:: Install Microsoft Visual C++ 2015-2022 x64 if VCRUNTIME140_1.dll is missing.
:: Silent when possible; needs admin once on a fresh Windows PC.

set "REDIST=%~dp0vcredist\VC_redist.x64.exe"
set "FLAG=%LOCALAPPDATA%\OfflinePOS\vcredist_ok.flag"

if exist "%SystemRoot%\System32\VCRUNTIME140_1.dll" (
  mkdir "%LOCALAPPDATA%\OfflinePOS" >nul 2>&1
  echo ok>"%FLAG%"
  exit /b 0
)

if not exist "%REDIST%" (
  echo [X] Missing %REDIST%
  echo     Download: https://aka.ms/vs/17/release/vc_redist.x64.exe
  exit /b 1
)

echo [..] Installing Visual C++ Redistributable x64 ...
"%REDIST%" /install /quiet /norestart
set "EC=%ERRORLEVEL%"
if exist "%SystemRoot%\System32\VCRUNTIME140_1.dll" (
  mkdir "%LOCALAPPDATA%\OfflinePOS" >nul 2>&1
  echo ok>"%FLAG%"
  echo [OK] VC++ runtime installed.
  exit /b 0
)

:: 3010 = success, reboot required
if "%EC%"=="0" exit /b 0
if "%EC%"=="3010" exit /b 0

echo [X] VC++ install failed ^(exit %EC%^). Right-click this bat -^> Run as administrator.
echo     Or install manually: %REDIST%
exit /b %EC%
