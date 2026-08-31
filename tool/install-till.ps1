# Sets up a till in one step. Right-click this file and pick Run with PowerShell.
# Do not start it as administrator: the app is installed into the profile of
# whoever runs it, so an elevated run puts the till in the administrator's
# profile and the cashier never sees it. One UAC prompt appears part way
# through, for the certificate step only, and everything else stays unelevated.
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
#   powershell -ExecutionPolicy Bypass -File .\install-till.ps1 -ExpectedThumbprint <thumbprint>
#
# make-signing-cert.ps1 prints that command line with the thumbprint already
# filled in. Without it the script has to stop and ask the operator to eyeball a
# certificate they have no way to recognise, so paste the printed one.
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
  [string]$CerPath = "",
  # Which certificate this till is allowed to trust. Importing into the machine's
  # root store makes that key able to vouch for anything on this computer for as
  # long as it is valid, so the whole point is to name the key up front instead of
  # trusting whatever .cer happens to be on the stick. Left empty, the script
  # prints who the certificate is and refuses to import without an answer.
  [string]$ExpectedThumbprint = "",
  # Set only by this script, on the elevated copy of itself that does the two
  # imports and nothing else. Nobody runs this by hand.
  [switch]$TrustCertOnly
)

$ErrorActionPreference = 'Stop'
$scriptPath = $MyInvocation.MyCommand.Path
$here = Split-Path -Parent $scriptPath

function Test-Admin {
  $me = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
  return $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$isAdmin = Test-Admin

# Run with PowerShell closes the window the moment the script ends, so a reason
# nobody can read is the same as no reason at all. Every stop waits to be read.
function Stop-Install([string]$message) {
  Write-Host ""
  Write-Host $message -ForegroundColor Red
  Write-Host ""
  Read-Host "Press Enter to close" | Out-Null
  exit 1
}

# Hex only and one case, because a thumbprint copied out of the Windows
# certificate dialog arrives with spaces in it and one pasted from this script's
# own output does not.
function Format-Thumbprint([string]$value) {
  return ($value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

function Read-Certificate([string]$path) {
  # .NET resolves a relative path against the process directory rather than the
  # shell's, so it is made absolute before anything reads it.
  $full = (Resolve-Path -LiteralPath $path).ProviderPath
  return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
    -ArgumentList $full
}

# Trusted Root so the chain validates at all, Trusted Publisher so Windows stops
# asking about a publisher this machine has already accepted. Both are per
# machine, so this is the one step that needs administrator, and the one step a
# bought certificate would remove entirely.
function Import-TrustAnchor([string]$path) {
  $full = (Resolve-Path -LiteralPath $path).ProviderPath
  Import-Certificate -FilePath $full -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
  Import-Certificate -FilePath $full -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
}

# The elevated copy of this script: it imports the certificate the unelevated
# copy already showed the operator, and does nothing else. The thumbprint is
# re-checked here rather than taken on trust, so what lands in the machine store
# is the certificate that was agreed to and not whatever the file says today.
if ($TrustCertOnly) {
  try {
    $cert = Read-Certificate $CerPath
    if ((Format-Thumbprint $cert.Thumbprint) -ne (Format-Thumbprint $ExpectedThumbprint)) { exit 2 }
    Import-TrustAnchor $CerPath
    exit 0
  } catch {
    exit 3
  }
}

if ($isAdmin) {
  Write-Host ""
  Write-Host "This is running as administrator, which is not how a till is installed." -ForegroundColor Yellow
  Write-Host "Everything below lands in the administrator's profile: the app, the desktop" -ForegroundColor Yellow
  Write-Host "shortcut and the Start Menu entry. The cashier signed in at this machine will" -ForegroundColor Yellow
  Write-Host "not see any of it, and the till would run elevated." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Close this, sign in as the cashier, and run it with a plain Run with PowerShell." -ForegroundColor Yellow
  Write-Host "The certificate step asks for administrator on its own when it needs it." -ForegroundColor Yellow
  Write-Host ""
  $answer = Read-Host "Type yes to install into the administrator's profile anyway"
  if ($answer.Trim().ToLowerInvariant() -ne 'yes') {
    Stop-Install "Nothing was changed."
  }
}

if (-not $Zip) {
  $found = Get-ChildItem -Path $here -Filter "offlinePOS-windows*.zip" |
           Sort-Object LastWriteTime | Select-Object -Last 1
  if (-not $found) { Stop-Install "No offlinePOS-windows zip found next to this script. Pass -Zip <path>." }
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

$certTrusted = $false
if ($CerPath -and (Test-Path -LiteralPath $CerPath)) {
  $cert = Read-Certificate $CerPath
  $thumb = Format-Thumbprint $cert.Thumbprint
  $trustIt = $true

  if ($ExpectedThumbprint) {
    if ($thumb -ne (Format-Thumbprint $ExpectedThumbprint)) {
      Stop-Install (@(
        "The certificate next to this script is not the one you asked for.",
        "  expected : $(Format-Thumbprint $ExpectedThumbprint)",
        "  found    : $thumb",
        "  file     : $CerPath",
        "Nothing was trusted and nothing was installed. Get a clean copy of the",
        "stick before running this again."
      ) -join [Environment]::NewLine)
    }
  } else {
    # Nobody said which certificate this is, so the operator is the only check
    # left between a stick and a permanent machine-wide trust anchor. Say plainly
    # what is about to be trusted and make them answer for it.
    Write-Host ""
    Write-Host "About to trust this certificate on this machine, permanently:" -ForegroundColor Yellow
    Write-Host "  Subject    : $($cert.Subject)"
    Write-Host "  Thumbprint : $thumb"
    Write-Host "  Expires    : $($cert.NotAfter)"
    Write-Host "  File       : $CerPath"
    Write-Host ""
    Write-Host "Anything signed with this key will be trusted here until it expires." -ForegroundColor Yellow
    Write-Host "If that thumbprint is not the one we published, answer no." -ForegroundColor Yellow
    Write-Host ""
    $answer = Read-Host "Type yes to trust it, anything else to install without it"
    $trustIt = ($answer.Trim().ToLowerInvariant() -eq 'yes')
  }

  if ($trustIt) {
    Write-Host "Trusting the signing certificate"
    if ($isAdmin) {
      Import-TrustAnchor $CerPath
      $certTrusted = $true
    } else {
      # The only part of this that needs administrator, so it is the only part
      # that gets it: a second copy of this script that imports and exits, while
      # the install carries on in the cashier's own profile. The thumbprint goes
      # across so the elevated copy trusts exactly what was shown above.
      try {
        $elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
          -WindowStyle Hidden -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $scriptPath),
            '-TrustCertOnly',
            '-CerPath', ('"{0}"' -f $CerPath),
            '-ExpectedThumbprint', $thumb
          )
        if ($elevated.ExitCode -eq 0) {
          $certTrusted = $true
        } elseif ($elevated.ExitCode -eq 2) {
          Stop-Install (@(
            "The certificate changed between being shown and being imported, so it",
            "was not trusted and nothing was installed. Get a clean copy of the",
            "stick before running this again."
          ) -join [Environment]::NewLine)
        } else {
          Write-Host "The certificate could not be imported, so it was not trusted." -ForegroundColor Yellow
        }
      } catch {
        # Declining the administrator prompt lands here, and that is a fair answer.
        Write-Host "Administrator was refused, so the certificate was not trusted." -ForegroundColor Yellow
      }
    }
  }

  if (-not $certTrusted) {
    Write-Host "The app still installs and runs; Windows will just call the publisher unknown." -ForegroundColor Yellow
  }
} else {
  Write-Host "No certificate alongside, skipping the trust step" -ForegroundColor Yellow
}

$exe = Join-Path $InstallDir "offline_pos.exe"
if (Test-Path -LiteralPath $exe) {
  # An upgrade over a running till fails part way through and leaves a mix of two
  # builds behind, so the till has to be gone before anything is unpacked or
  # copied. Asking to close can fail and the wait can time out, and either way the
  # answer is the same one the in-app updater gives: still running means the
  # install is not touched at all, so the machine keeps the build it has.
  $stuck = @()
  foreach ($proc in @(Get-Process -Name "offline_pos" -ErrorAction SilentlyContinue)) {
    $asked = $proc.CloseMainWindow()
    if (-not $proc.WaitForExit(30000)) {
      if ($asked) {
        $stuck += "  process $($proc.Id) was asked to close and did not"
      } else {
        $stuck += "  process $($proc.Id) would not even take the close, so it is busy or has no window"
      }
    }
  }
  if ($stuck.Count -gt 0) {
    $lines = @("Offline POS is still running, so nothing was changed.")
    $lines += $stuck
    $lines += "Close the till on this machine, then run this again."
    Stop-Install ($lines -join [Environment]::NewLine)
  }
}

# Unpacked beside the install first, for the same reason the in-app updater does
# it: a truncated zip must not half replace a till that was working.
$stage = Join-Path $env:TEMP "offlinepos-install-stage"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
Expand-Archive -LiteralPath $Zip -DestinationPath $stage -Force

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
if ($certTrusted) {
  Write-Host "It will open without a publisher warning on this machine."
}
Start-Process -FilePath $exe -WorkingDirectory $InstallDir
