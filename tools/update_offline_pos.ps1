<#
.SYNOPSIS
  Puts a new Offline POS build in place of the installed one, keeping the shop's data.

.DESCRIPTION
  Started by UpdateOfflinePOS.bat from the folder the new version was unzipped to.

  1. Finds the installed copy: the running app, the folder used last time,
     shortcuts, and the usual folders; or installs fresh when there is none.
  2. Closes the app (and the fingerprint agent started from that folder).
  3. Backs up the data folder and the installed program to
     Documents\OfflinePOS-backups\<date-time>.
  4. Copies the new files over the installed ones. On failure the old program is
     put back.
  5. Starts the app again.

  The data (orders, menu, settings, pairing) lives in
  %APPDATA%\Code Solution\Offline POS and is never written to. The app upgrades
  its database itself on first start.
#>
param(
  [string]$Source = (Split-Path $PSScriptRoot -Parent),
  [string]$Target,
  [string]$DataDir = (Join-Path $env:APPDATA 'Code Solution\Offline POS'),
  # Skip the confirmation question.
  [switch]$Yes,
  # Copy only; do not start the app afterwards.
  [switch]$NoStart,
  # Install into -Target, which does not hold a copy yet.
  [switch]$Fresh
)

$ErrorActionPreference = 'Stop'
$exeName = 'offline_pos.exe'
$rememberFile = 'install_dir.txt'

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Done($code) { [void](Read-Host "`nPress Enter to close"); exit $code }
function Fail($text) { Say $text Red; Done 1 }

function VersionOf($dir) {
  $exe = Join-Path $dir $exeName
  if (-not (Test-Path $exe)) { return '?' }
  $v = (Get-Item $exe).VersionInfo.ProductVersion
  if ($v) { $v } else { '?' }
}

function Test-Writable($dir) {
  try {
    $probe = Join-Path $dir ".update-probe-$PID"
    [IO.File]::WriteAllText($probe, 'x')
    Remove-Item $probe -Force
    $true
  } catch { $false }
}

function Under($path, $dir) {
  $path -and $path.StartsWith($dir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

Say '=== Offline POS update ===' Cyan

$Source = (Resolve-Path $Source).Path
if (-not (Test-Path (Join-Path $Source $exeName))) {
  Fail "There is no $exeName next to this script ($Source). Run UpdateOfflinePOS.bat from the unzipped new version."
}

# --- Find the installed copy -------------------------------------------------
# Where a copy was unzipped is up to whoever set the till up, so it is looked for:
# the running app, the folder used last time, shortcuts, and the usual places.
function Find-Installs([switch]$Quick) {
  $found = [ordered]@{}
  function Add($dir, $how) {
    if (-not $dir) { return }
    $dir = $dir.TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $dir $exeName))) { return }
    if ($dir -ieq $Source) { return }
    if ($dir -match '\\OfflinePOS-backups\\|\\build\\windows\\') { return }
    if (-not $found.Contains($dir.ToLower())) { $found[$dir.ToLower()] = [pscustomobject]@{ Dir = $dir; How = $how } }
  }
  # Folders only, a few levels down: listing every file of a big disk takes minutes.
  $noise = '^(\..*|node_modules|\$Recycle\.Bin|System Volume Information|AppData|Windows|ProgramData|Recovery|PerfLogs|Users)$'
  function Probe($dir, $levels) {
    Add $dir 'found'
    if ($levels -le 0) { return }
    Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notmatch $noise } | ForEach-Object { Probe $_.FullName ($levels - 1) }
  }

  Get-Process -Name 'offline_pos' -ErrorAction SilentlyContinue | Where-Object { $_.Path } |
    ForEach-Object { Add (Split-Path $_.Path -Parent) 'running now' }

  $remembered = Join-Path $DataDir $rememberFile
  if (Test-Path $remembered) { Add ((Get-Content $remembered -Raw).Trim()) 'updated last time' }
  if ($Quick) { return @($found.Values) }

  $shell = New-Object -ComObject WScript.Shell
  $linkDirs = @(
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('CommonDesktopDirectory'),
    [Environment]::GetFolderPath('StartMenu'),
    [Environment]::GetFolderPath('CommonStartMenu')
  ) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($d in $linkDirs) {
    Get-ChildItem -Path $d -Filter '*.lnk' -Recurse -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $t = $shell.CreateShortcut($_.FullName).TargetPath
        if ($t -and ($t -match '(?i)\\(offline_pos\.exe|RunOfflinePOS\.bat)$')) { Add (Split-Path $t -Parent) "shortcut $($_.Name)" }
      } catch {}
    }
  }

  $userRoots = @(
    [Environment]::GetFolderPath('Desktop'),
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:USERPROFILE 'Downloads'),
    [Environment]::GetFolderPath('MyDocuments')
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
  foreach ($r in $userRoots) { Probe $r 3 }
  $driveRoots = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' -and $_.Free -ne $null } | ForEach-Object { $_.Root }
  foreach ($root in $driveRoots) { Probe $root 3 }
  @($found.Values)
}

function LastOpened($dir) {
  $log = Join-Path $dir 'offline_pos_startup.log'
  if (Test-Path $log) { (Get-Item $log).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
}

$isFresh = $Fresh.IsPresent
if (-not $Target) {
  Say 'Looking for the installed copy...'
  $installs = @(Find-Installs -Quick)
  if ($installs.Count -eq 1) {
    $Target = $installs[0].Dir
  } else {
    if ($installs.Count -eq 0) { $installs = @(Find-Installs) }
    Say ''
    if ($installs.Count -eq 0) {
      Say 'No installed copy of Offline POS was found on this computer.' Yellow
    } else {
      Say 'Installed copies found:'
      for ($i = 0; $i -lt $installs.Count; $i++) {
        $c = $installs[$i]
        Say ("  [{0}] {1}" -f ($i + 1), $c.Dir) White
        Say ("      version {0}, last opened {1}, {2}" -f (VersionOf $c.Dir), (LastOpened $c.Dir), $c.How)
      }
    }
    Say '  [N] Install it fresh (first time on this computer)'
    Say '  [B] Browse for the folder myself'
    Say '  [Q] Quit'
    $choice = (Read-Host 'Choose').Trim()
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $installs.Count) {
      $Target = $installs[[int]$choice - 1].Dir
    } elseif ($choice -match '^[nN]$') {
      $default = 'C:\OfflinePOS'
      $typed = (Read-Host "Install to which folder? Press Enter for $default").Trim()
      $Target = if ($typed) { $typed } else { $default }
      if (Test-Path (Join-Path $Target $exeName)) {
        Say "$Target already holds Offline POS, so it is updated instead." Yellow
      } else {
        $isFresh = $true
      }
    } elseif ($choice -match '^[bB]$') {
      Add-Type -AssemblyName System.Windows.Forms
      $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
      $dialog.Description = 'Choose the folder that holds offline_pos.exe (the copy in use, not the new one)'
      if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Fail 'No folder chosen. Nothing was changed.' }
      $Target = $dialog.SelectedPath
      if (-not (Test-Path (Join-Path $Target $exeName))) {
        $inside = @(Get-ChildItem -Path $Target -Filter $exeName -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
          Where-Object { $_.DirectoryName -ine $Source })
        if ($inside.Count -eq 1) { $Target = $inside[0].DirectoryName }
      }
    } else {
      Say 'Nothing was changed.'
      Done 0
    }
  }
}
if ($isFresh) {
  $Target = [IO.Path]::GetFullPath($Target).TrimEnd('\')
  if ($Target -ieq $Source) { Fail 'That is the new version''s own folder. Choose another folder to install to.' }
  try { New-Item -ItemType Directory -Path $Target -Force | Out-Null } catch {}
} else {
  $Target = (Resolve-Path $Target).Path
  if (-not (Test-Path (Join-Path $Target $exeName))) { Fail "$Target does not hold $exeName. Nothing was changed." }
  if ($Target -ieq $Source) {
    Fail 'That is the new version''s own folder, not the copy in use. Run this again and choose the other one, or [N] to install fresh.'
  }
}

# --- Administrator rights, only when the install folder needs them -----------
if ($isFresh -and -not (Test-Path $Target)) {
  try { New-Item -ItemType Directory -Path $Target -Force | Out-Null } catch {}
}
if (-not ((Test-Path $Target) -and (Test-Writable $Target))) {
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($admin) { Fail "Cannot write to $Target, even as administrator. Choose another folder." }
  Say "Writing to $Target needs administrator rights. Asking for them..." Yellow
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
    '-Source', "`"$Source`"", '-Target', "`"$Target`"", '-DataDir', "`"$DataDir`"")
  if ($Yes) { $arguments += '-Yes' }
  if ($NoStart) { $arguments += '-NoStart' }
  if ($isFresh) { $arguments += '-Fresh' }
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
  } catch {
    Fail 'Administrator rights were refused. Nothing was changed.'
  }
  exit 0
}

# --- Confirm -----------------------------------------------------------------
Say ''
if ($isFresh) {
  Say "Install to: $Target"
} else {
  Say "Installed : $Target  (version $(VersionOf $Target))"
}
Say "New       : $Source  (version $(VersionOf $Source))"
Say "Data      : $DataDir$(if (Test-Path $DataDir) { '' } else { '  (none yet)' })"
Say ''
if (-not $isFresh) {
  Say 'Before you go on: close the shift on this till and make sure every sale has reached Odoo.' Yellow
  Say 'If this shop has more than one till, update all of them now, the primary first.' Yellow
}
if (-not $Yes) {
  $verb = if ($isFresh) { 'install' } else { 'update' }
  $answer = Read-Host "Type Y and press Enter to $verb"
  if ($answer -notmatch '^[yY]$') { Say 'Cancelled. Nothing was changed.'; Done 0 }
}

# --- Close the app -----------------------------------------------------------
if (-not $isFresh) { Say "`nClosing Offline POS..." }
$apps = @(Get-Process -Name 'offline_pos' -ErrorAction SilentlyContinue | Where-Object { Under $_.Path $Target })
foreach ($p in $apps) { [void]$p.CloseMainWindow() }
foreach ($p in $apps) {
  if (-not $p.WaitForExit(20000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
# Anything else started from the install folder (the fingerprint agent) holds its
# files open too.
Get-CimInstance Win32_Process | Where-Object {
  $_.ProcessId -ne $PID -and (
    (Under $_.ExecutablePath $Target) -or
    ($_.CommandLine -and $_.CommandLine.IndexOf($Target, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
      $_.Name -notmatch '^(powershell|pwsh|cmd)\.exe$'))
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# --- Back up -----------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "OfflinePOS-backups\$stamp"
Say "Backing up to $backup ..."
New-Item -ItemType Directory -Path $backup -Force | Out-Null
try {
  if (Test-Path $DataDir) {
    Copy-Item -Path $DataDir -Destination (Join-Path $backup 'data') -Recurse -Force
  } else {
    Say "No data folder at $DataDir, so there is no data to back up." Yellow
  }
  if (-not $isFresh) {
    Copy-Item -Path $Target -Destination (Join-Path $backup 'program') -Recurse -Force
  }
} catch {
  Fail "The backup failed, so nothing was changed: $($_.Exception.Message)"
}

# --- Copy the new version in ---------------------------------------------------
Say 'Copying the new version...'
& robocopy $Source $Target /E /R:3 /W:2 /NFL /NDL /NJH /NP /XF '*.log' $rememberFile | Out-Host
if ($LASTEXITCODE -ge 8) {
  if ($isFresh) { Fail "Copying failed. Close anything using $Target and run this again." }
  Say 'Copying failed. Putting the old version back...' Red
  & robocopy (Join-Path $backup 'program') $Target /E /R:3 /W:2 /NFL /NDL /NJH /NP | Out-Host
  Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$(Join-Path $Target $exeName)`""
  Fail "The old version is back and running. Backup: $backup"
}

# A zip downloaded from the internet marks every file it holds, and Windows then
# warns before running each one. These came from the release, so the mark goes.
Get-ChildItem -Path $Target -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# Remembered in the data folder, so the next update finds this copy without asking.
# The app has not created that folder yet on a fresh install, so it is made here.
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
Set-Content -Path (Join-Path $DataDir $rememberFile) -Value $Target -Encoding UTF8

# One shortcut, to this install. Old ones to other copies would open last
# week's build.
try {
  $shell = New-Object -ComObject WScript.Shell
  $desktops = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) |
    Where-Object { $_ -and (Test-Path $_) }
  foreach ($desk in $desktops) {
    Get-ChildItem -LiteralPath $desk -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $t = $shell.CreateShortcut($_.FullName).TargetPath
        if ($t -match '(?i)\\(offline_pos\.exe|RunOfflinePOS\.bat)$') {
          Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
          Say "Removed old shortcut $($_.Name)"
        }
      } catch {}
    }
  }
  $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Offline POS.lnk'))
  $link.TargetPath = Join-Path $Target $exeName
  $link.WorkingDirectory = $Target
  $link.IconLocation = "$(Join-Path $Target $exeName),0"
  $link.Save()
  Say 'A shortcut "Offline POS" is on the Desktop.'
} catch {
  Say "Could not make a Desktop shortcut: $($_.Exception.Message)" Yellow
}

# Started through Explorer so it runs as the signed-in user, not as administrator.
if (-not $NoStart) {
  Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$(Join-Path $Target $exeName)`""
}

if ($isFresh) {
  Say "`nInstalled version $(VersionOf $Target) in $Target." Green
  Say 'Next time, run UpdateOfflinePOS.bat from a newer unzipped version and it will find this copy.'
} else {
  Say "`nUpdated to version $(VersionOf $Target)." Green
  Say "Backup: $backup"
  Say 'To go back: close the app and copy the backup''s program folder over the installed one.'
}
Done 0
