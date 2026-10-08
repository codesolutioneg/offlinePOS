@echo off
:: Gives this computer a second address on the printers' range (e.g. 192.168.0.x)
:: next to the one the router hands out, so it can reach printers with a fixed IP
:: on that range. Run once per computer. Asks for administrator rights.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "IP="
set /p "IP=Address for THIS computer on the printers' range (e.g. 192.168.0.41): "
if "%IP%"=="" exit /b 1
powershell -NoProfile -Command ^
  "$if = (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1).InterfaceAlias;" ^
  "Write-Host ('Network card: ' + $if);" ^
  "netsh interface ipv4 set interface $if dhcpstaticipcoexistence=enabled | Out-Null;" ^
  "Remove-NetIPAddress -IPAddress '%IP%' -Confirm:$false -ErrorAction SilentlyContinue;" ^
  "netsh interface ipv4 add address $if '%IP%' 255.255.255.0;" ^
  "Get-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 | Format-Table IPAddress,PrefixLength,PrefixOrigin -AutoSize"
pause
