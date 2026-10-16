@echo off
:: Lets the other tills in the shop reach this one. Run once per computer, from
:: the folder that holds offline_pos.exe. Asks for administrator rights.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "EXE=%~dp0offline_pos.exe"
if not exist "%EXE%" set "EXE=%~dp0..\build\windows\x64\runner\Release\offline_pos.exe"
if not exist "%EXE%" (
  echo offline_pos.exe not found next to this file.
  pause
  exit /b 1
)
powershell -NoProfile -Command ^
  "$exe = (Resolve-Path '%EXE%').Path;" ^
  "Get-NetFirewallApplicationFilter | Where-Object { $_.Program -eq $exe } | Get-NetFirewallRule | Where-Object { $_.Action -eq 'Block' } | Remove-NetFirewallRule;" ^
  "Get-NetFirewallRule -DisplayName 'Dishflow LAN' -ErrorAction SilentlyContinue | Remove-NetFirewallRule;" ^
  "New-NetFirewallRule -DisplayName 'Dishflow LAN' -Direction Inbound -Program $exe -Action Allow -Profile Any | Out-Null;" ^
  "Write-Host ('Allowed: ' + $exe)"
pause
