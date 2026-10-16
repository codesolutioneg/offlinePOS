@echo off
:: Install ZK Fingerprint USB driver (libusb0) — requires Administrator
chcp 65001 >nul
cd /d "%~dp0"

set "NOPAUSE="
if /I "%~1"=="nopause" set "NOPAUSE=1"
if /I "%~1"=="/nopause" set "NOPAUSE=1"

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting Administrator to install ZK USB driver...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'nopause' -Verb RunAs -Wait"
  exit /b %ERRORLEVEL%
)

echo ============================================================
echo  Offline POS - Install ZK Fingerprint USB Driver
echo ============================================================
echo.

set "DRV=%~dp0zk_driver"
if not exist "%DRV%\zkusbdevices.inf" (
  echo [X] Missing %DRV%\zkusbdevices.inf
  pause
  exit /b 1
)

echo [..] Adding driver package...
pnputil /add-driver "%DRV%\zkusbdevices.inf" /install
set "RC=%ERRORLEVEL%"
echo.

echo [..] Rescanning PnP devices...
pnputil /scan-devices >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$d=Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_1B55' }; ^
   if(-not $d){ Write-Host '[!] No VID_1B55 device present — plug in the ZK9500 then re-run.'; exit 2 }; ^
   foreach($x in $d){ ^
     Write-Host ('Device: ' + $x.FriendlyName + '  Status=' + $x.Status); ^
     if($x.Status -ne 'OK'){ ^
       try { Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1; Enable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {} ^
     } ^
   }; ^
   Start-Sleep -Seconds 2; ^
   $d2=Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_1B55' }; ^
   foreach($x in $d2){ Write-Host ('After restart: ' + $x.FriendlyName + '  Status=' + $x.Status) }; ^
   if(($d2 | Where-Object Status -eq 'OK').Count -gt 0){ exit 0 } else { exit 3 }"

set "PSRC=%ERRORLEVEL%"
if "%PSRC%"=="0" (
  echo.
  echo [OK] ZK USB driver looks healthy.
  mkdir "%LOCALAPPDATA%\OfflinePOS" >nul 2>&1
  echo ok>"%LOCALAPPDATA%\OfflinePOS\zk_driver_ok.flag"
) else (
  echo.
  echo [!] Driver install finished but device Status is not OK yet.
  echo     1^) Unplug ZK9500, wait 3s, plug again
  echo     2^) Re-run this bat as Administrator
  echo     3^) Or Device Manager ^> ZK9500 ^> Update driver ^> Browse to:
  echo        %DRV%
)

echo.
if not defined NOPAUSE pause
exit /b %RC%
