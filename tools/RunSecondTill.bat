@echo off
:: A second till on this same computer, for trying the shop network without a
:: second machine. It keeps its own database (instance-2 under the app data
:: folder) and serves the network on its own port. Never use on a real till.
set "EXE=%~dp0..\build\windows\x64\runner\Release\offline_pos.exe"
if not exist "%EXE%" set "EXE=%~dp0offline_pos.exe"
if not exist "%EXE%" (
  echo offline_pos.exe not found. Build the release first.
  pause
  exit /b 1
)
set OFFLINE_POS_INSTANCE=2
start "" "%EXE%" --windowed
exit /b 0
