<#
.SYNOPSIS
  Deletes all of Offline POS's data on this computer, so it opens as a new install.

.DESCRIPTION
  Started by ResetOfflinePOS.bat.

  Everything the app keeps is in one folder: %APPDATA%\Code Solution\Offline POS.
  The database (orders, shifts, menu, staff, printers, settings, shop pairing), its
  encryption key, the cloud backup and sync settings, and any test-till copies
  (instance-N) all live there. Deleting it is a new install; the program files are
  not touched.

  A copy is kept in Documents\OfflinePOS-backups\reset-<date-time> first, unless
  -NoBackup is given. Nothing is deleted in Odoo or in the cloud.
#>
param(
  [string]$DataDir = (Join-Path $env:APPDATA 'Code Solution\Offline POS'),
  [switch]$NoBackup,
  # Skip the typed confirmation.
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Done($code) { [void](Read-Host "`nPress Enter to close"); exit $code }

Say '=== Offline POS: delete all data ===' Cyan

if (-not (Test-Path $DataDir)) {
  Say "There is no data folder at $DataDir. Offline POS is already like a new install." Green
  Done 0
}

$files = @(Get-ChildItem -Path $DataDir -Recurse -File -Force -ErrorAction SilentlyContinue)
$size = [math]::Round((($files | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
Say ''
Say "Data folder: $DataDir ($($files.Count) files, $size MB)"
Say ''
Say 'This deletes EVERYTHING Offline POS keeps on this computer:' Yellow
Say '  orders, shifts and Z reports, sales not yet sent to Odoo,' Yellow
Say '  menu, staff and PINs, printers, settings, shop network pairing, cloud settings.' Yellow
Say 'The app then opens as a new install. Nothing is deleted in Odoo or in the cloud.' Yellow
if ($NoBackup) {
  Say 'No backup will be kept (-NoBackup).' Red
} else {
  Say 'A copy is kept in Documents\OfflinePOS-backups first.'
}
if (-not $Yes) {
  Say ''
  $answer = Read-Host 'Type DELETE and press Enter to go on'
  if ($answer.Trim() -cne 'DELETE') { Say 'Cancelled. Nothing was deleted.'; Done 0 }
}

# --- Close the app ---------------------------------------------------------------
$apps = @(Get-Process -Name 'offline_pos' -ErrorAction SilentlyContinue)
if ($apps.Count -gt 0) {
  Say "`nClosing Offline POS..."
  foreach ($p in $apps) { [void]$p.CloseMainWindow() }
  foreach ($p in $apps) {
    if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
  Start-Sleep -Seconds 1
}

# --- Back up -----------------------------------------------------------------------
if (-not $NoBackup) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "OfflinePOS-backups\reset-$stamp"
  Say "Backing up to $backup ..."
  try {
    New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force | Out-Null
    Copy-Item -Path $DataDir -Destination $backup -Recurse -Force
  } catch {
    Say "The backup failed, so nothing was deleted: $($_.Exception.Message)" Red
    Done 1
  }
}

# --- Delete ------------------------------------------------------------------------
Say 'Deleting...'
$deleted = $false
for ($try = 1; $try -le 5 -and -not $deleted; $try++) {
  try {
    Remove-Item -Path $DataDir -Recurse -Force
    $deleted = $true
  } catch {
    if ($try -eq 5) {
      Say "Could not delete everything: $($_.Exception.Message)" Red
      Say 'Close Offline POS (and anything showing files from that folder) and run this again.' Red
      Done 1
    }
    Start-Sleep -Seconds 2
  }
}

Say "`nDone. Offline POS will open as a new install." Green
if (-not $NoBackup) {
  Say "Backup: $backup"
  Say 'To undo: close the app and copy the backup folder back to:'
  Say "  $DataDir"
}

$exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'offline_pos.exe'
if (Test-Path $exe) {
  $start = Read-Host "`nStart Offline POS now? (Y/N)"
  if ($start -match '^[yY]$') {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$exe`""
    exit 0
  }
}
Done 0
