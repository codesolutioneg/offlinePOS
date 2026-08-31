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
  [string]$InstallDir = "$env:ProgramFiles\Code Solution\Offline POS",
  # The public half of the signing certificate. Only needed while the build is
  # signed with our own certificate rather than a bought one; with a CA
  # certificate this file does not exist and the step is skipped, which is the
  # whole reason buying one removes work from here.
  [string]$CerPath = ""
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Require-Admin {
  $me = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this as administrator: right-click the file and pick Run with PowerShell, or open an elevated terminal."
  }
}
Require-Admin

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
  # per machine, which is why a bought certificate is worth it once tills are
  # installed by anyone other than us.
  Write-Host "Trusting the signing certificate"
  Import-Certificate -FilePath $CerPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
  Import-Certificate -FilePath $CerPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
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

$shell = New-Object -ComObject WScript.Shell
foreach ($dir in @(
  [Environment]::GetFolderPath('CommonDesktopDirectory'),
  (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
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
