# Sets up a till in one step. Right-click this file, Run with PowerShell, accept
# the administrator prompt. That is the whole client-side procedure.
#
# It does the four things that were otherwise four manual jobs on every machine:
# clears the downloaded-from-the-internet mark that makes SmartScreen shout,
# trusts the Code Solution signing certificate so the app shows a publisher
# instead of "Unknown publisher", installs the build, and puts shortcuts where a
# cashier will find them.
#
# Run it again to upgrade a till by hand. It is safe to repeat: the certificate
# is only imported once and the files are overwritten in place. Normally nobody
# has to, because the app updates itself.
#
#   powershell -ExecutionPolicy Bypass -File .\install-till.ps1
#
param(
  # The zip as downloaded from the build. Defaults to the one sitting next to
  # this script, which is how it arrives on a USB stick.
  [string]$Zip = "",
  # Under the user's own profile, not Program Files, and that is deliberate. The
  # till updates itself, the app runs unelevated, and a detached updater inherits
  # that token: an install under Program Files means every future update dies on
  # access denied, or prompts for administrator on a machine nobody is watching.
  # Here the app can replace its own files forever with no prompt.
  [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Code Solution\Offline POS",
  # The public half of the signing certificate. Only needed while the build is
  # signed with our own certificate rather than a bought one; with a CA
  # certificate this file does not exist and the step is skipped, which is the
  # whole reason buying one removes work from here.
  [string]$CerPath = ""
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-Admin {
  $me = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
  return $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$isAdmin = Test-Admin

if (-not $Zip) {
  $found = Get-ChildItem -Path $here -Filter "offlinePOS-windows*.zip" |
           Sort-Object LastWriteTime | Select-Object -Last 1
  if (-not $found) { throw "No offlinePOS-windows zip found next to this script. Pass -Zip <path>." }
  $Zip = $found.FullName
}
if (-not $CerPath) {
  $cer = Get-ChildItem -Path $here -Filter "*.cer" | Select-Object -First 1
  if ($cer) { $CerPath = $cer.FullName }
}

Write-Host "Installing from $Zip" -ForegroundColor Cyan

# A zip that came through a browser carries the mark of the web, and every file
# unpacked from it inherits it. That mark is what makes Windows refuse to open
# the app on first run, so it goes before anything is unpacked.
Unblock-File -LiteralPath $Zip -ErrorAction SilentlyContinue

if ($CerPath -and (Test-Path -LiteralPath $CerPath)) {
  # Trusted Root so the chain validates at all, Trusted Publisher so Windows
  # stops asking about a publisher this machine has already accepted. Both are
  # per machine, so this is the one step that needs administrator, and the one
  # step a bought certificate would remove entirely.
  if ($isAdmin) {
    Write-Host "Trusting the signing certificate"
    Import-Certificate -FilePath $CerPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath $CerPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
  } else {
    Write-Host "Not running as administrator, so the certificate was not trusted." -ForegroundColor Yellow
    Write-Host "The app still installs and runs; Windows will just call the publisher unknown." -ForegroundColor Yellow
    Write-Host "To fix it, right-click this file and pick Run with PowerShell." -ForegroundColor Yellow
  }
} else {
  Write-Host "No certificate alongside, skipping the trust step" -ForegroundColor Yellow
}

# Unpacked beside the install first, for the same reason the in-app updater does
# it: a truncated zip must not half replace a till that was working.
$stage = Join-Path $env:TEMP "offlinepos-install-stage"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
Expand-Archive -LiteralPath $Zip -DestinationPath $stage -Force

$exe = Join-Path $InstallDir "offline_pos.exe"
if (Test-Path -LiteralPath $exe) {
  # An upgrade over a running till would fail on locked files part way through.
  Get-Process -Name "offline_pos" -ErrorAction SilentlyContinue |
    ForEach-Object { $_.CloseMainWindow() | Out-Null; $_.WaitForExit(30000) | Out-Null }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -Path (Join-Path $stage '*') -Destination $InstallDir -Recurse -Force
Remove-Item -LiteralPath $stage -Recurse -Force

# Per user, to match where the app is installed. A shortcut for everybody
# pointing into one user's profile is a shortcut that is broken for everybody
# else.
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in @(
  [Environment]::GetFolderPath('Desktop'),
  (Join-Path $env:AppData 'Microsoft\Windows\Start Menu\Programs')
)) {
  $lnk = $shell.CreateShortcut((Join-Path $dir 'Offline POS.lnk'))
  $lnk.TargetPath = $exe
  $lnk.WorkingDirectory = $InstallDir
  $lnk.Description = 'Offline POS'
  $lnk.Save()
}

Write-Host ""
Write-Host "Done. Offline POS is installed and on the desktop." -ForegroundColor Green
if ($CerPath) {
  Write-Host "It will open without a publisher warning on this machine."
}
Start-Process -FilePath $exe -WorkingDirectory $InstallDir
