# diagnose.ps1 , launch offlinePOS and show why it will not start.
# Put this next to offline_pos.exe (or run it from a dev checkout) and double-run,
# or in PowerShell:  powershell -ExecutionPolicy Bypass -File .\diagnose.ps1
# It kills any stuck instance, launches the app, then prints the startup log and
# the exact step that failed. Reads only step names / reasons , never keys or PINs.

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Find the executable: next to this script, else the release build in a dev checkout.
$exe = Join-Path $here 'offline_pos.exe'
if (-not (Test-Path $exe)) { $exe = Join-Path $here 'build\windows\x64\runner\Release\offline_pos.exe' }
if (-not (Test-Path $exe)) {
  Write-Host 'offline_pos.exe not found next to this script.' -ForegroundColor Red
  Read-Host 'Press Enter to close'; exit 1
}
$dir = Split-Path $exe

Write-Host 'Stopping any stuck instance (frees the single-instance lock)...' -ForegroundColor Cyan
Get-Process offline_pos -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

# The log is written next to the exe, or in %TEMP% when that folder is read-only.
$log = Join-Path $dir 'offline_pos_startup.log'
if (-not (Test-Path $log)) { $log = Join-Path $env:TEMP 'offline_pos_startup.log' }

Write-Host "Launching $exe ..." -ForegroundColor Cyan
$p = Start-Process -FilePath $exe -PassThru

# Wait for a verdict: a FAILED line, the first frame, or the process dying.
$deadline = (Get-Date).AddSeconds(20); $verdict = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  if (Test-Path $log) {
    $c = Get-Content $log
    if ($c -match 'FAILED:')     { $verdict = 'failed';  break }
    if ($c -match 'first frame') { $verdict = 'started'; break }
  }
  if ($p.HasExited) { $verdict = 'exited'; break }
}

Write-Host "`n===== last startup log lines =====" -ForegroundColor Yellow
if (Test-Path $log) { Get-Content $log -Tail 60 } else { Write-Host "No startup log found." -ForegroundColor Red }

$fail = if (Test-Path $log) { Select-String -Path $log -Pattern 'FAILED:' | Select-Object -Last 1 }
if ($fail) {
  Write-Host "`n>>> FAILED: $($fail.Line)" -ForegroundColor Red
} elseif ($verdict -eq 'started') {
  Write-Host "`n>>> Reached the first frame , the app started fine." -ForegroundColor Green
} else {
  $laststep = if (Test-Path $log) { (Get-Content $log | Where-Object { $_ -match 'step:' } | Select-Object -Last 1) }
  if ($laststep) { Write-Host "`n>>> Last step reached (likely stuck here): $laststep" -ForegroundColor Red }
}

$report = Join-Path ([Environment]::GetFolderPath('Desktop')) 'offline_pos_problem_report.txt'
if (Test-Path $report) { Write-Host "`nProblem report on Desktop: $report" -ForegroundColor Green }
Write-Host "`nLog file: $log"
Read-Host "`nPress Enter to close"
