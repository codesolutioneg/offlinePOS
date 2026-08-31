# Creates the code-signing certificate the Windows build is signed with, and
# prints what to paste into AppVeyor. Run this ONCE, on a Windows machine, and
# keep what it produces.
#
# What this gets you: the till stops saying "Unknown publisher" and says
# Code Solution instead, on any machine that has been given the .cer by
# install-till.ps1, which trusts it as part of installing. That is the right
# trade for tills we install ourselves and it costs nothing.
#
# What it does NOT get you: a stranger downloading the app still sees the
# SmartScreen warning, because this certificate chains to itself rather than to
# a certificate authority Windows already trusts. Only a bought CA certificate
# fixes that, and the build signs with one of those through exactly the same
# step: replace the pfx, change nothing else.
#
#   .\tool\make-signing-cert.ps1 -Password (Read-Host -AsSecureString)
#
param(
  [Parameter(Mandatory = $true)][SecureString]$Password,
  [string]$Publisher = "Code Solution",
  [string]$OutDir = ".",
  # Five years. The signature outlives it anyway because the build timestamps
  # every signature, which is what keeps already-installed tills verifying after
  # the certificate itself has expired.
  [int]$Years = 5
)

$ErrorActionPreference = 'Stop'

$cert = New-SelfSignedCertificate `
  -Type CodeSigningCert `
  -Subject "CN=$Publisher, O=$Publisher, C=EG" `
  -KeyUsage DigitalSignature `
  -KeyAlgorithm RSA `
  -KeyLength 3072 `
  -HashAlgorithm SHA256 `
  -CertStoreLocation Cert:\CurrentUser\My `
  -NotAfter (Get-Date).AddYears($Years)

$pfxPath = Join-Path $OutDir "codesign-codesolution.pfx"
$cerPath = Join-Path $OutDir "codesign-codesolution.cer"

# The pfx holds the private key and is the thing that can sign as us. It goes to
# AppVeyor as an encrypted variable and nowhere else. The cer is the public half
# and is what gets installed on each till.
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $Password | Out-Null
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pfxPath))
$b64Path = Join-Path $OutDir "codesign-codesolution.pfx.base64.txt"
Set-Content -LiteralPath $b64Path -Value $base64 -NoNewline

Write-Host ""
Write-Host "Certificate created." -ForegroundColor Green
Write-Host "  Thumbprint : $($cert.Thumbprint)"
Write-Host "  Expires    : $($cert.NotAfter)"
Write-Host "  pfx        : $pfxPath   (private key, never commit, never email)"
Write-Host "  cer        : $cerPath   (public, install this on every till)"
Write-Host "  base64     : $b64Path"
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Encrypt both values at https://ci.appveyor.com/tools/encrypt"
Write-Host "     and add them to the project as secure variables:"
Write-Host "       CODESIGN_PFX_BASE64  = contents of $b64Path"
Write-Host "       CODESIGN_PASSWORD    = the password given to this script"
Write-Host "       CODESIGN_PUBLISHER   = $Publisher"
Write-Host "  2. Push. The build signs the exe and verifies the signature."
Write-Host "  3. Put the build zip and $cerPath on the same stick, and on each till"
Write-Host "     run this, as the cashier, not as administrator. It asks for"
Write-Host "     administrator itself for the certificate step only:"
Write-Host "       powershell -ExecutionPolicy Bypass -File .\install-till.ps1 -ExpectedThumbprint $($cert.Thumbprint)" -ForegroundColor Cyan
Write-Host ""
# Named up front, because a till that is told which certificate to expect can
# refuse the wrong one. Left to ask instead, all it can do is describe a
# thumbprint to somebody with nothing to compare it against.
Write-Host "     Keep that line with the stick. Without the thumbprint the till has to" -ForegroundColor Yellow
Write-Host "     stop and ask an operator to vouch for a certificate by eye." -ForegroundColor Yellow
Write-Host ""
Write-Host "Keep the pfx and its password somewhere durable. Losing them means" -ForegroundColor Yellow
Write-Host "a new certificate, and every till has to be given the new .cer." -ForegroundColor Yellow
