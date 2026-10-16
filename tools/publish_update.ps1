<#
.SYNOPSIS
  Puts a built release on the update server, where every till picks it up.

.DESCRIPTION
  powershell -ExecutionPolicy Bypass -File tools\publish_update.ps1 -Zip dist\offlinePOS-windows-1.1.1+8.zip -Version 1.1.1+8

  -Zip       The release zip. Defaults to the newest one in dist\.
  -Version   The build in it, like 1.1.1+8. Read from the zip name when left out.

  Signs the release with the key in %USERPROFILE%\.offlinepos (see
  tools\release_sign.dart), uploads the zip, then the manifest. The manifest goes
  last so a till never sees a version whose zip is not there yet.
#>
param(
  [string]$Zip,
  [string]$Version,
  [string]$Server = 'root@91.99.195.177',
  [string]$RemoteDir = '/opt/offline-pos-updates/offline-pos',
  [string]$BaseUrl = 'https://updates.91.99.195.177.sslip.io/offline-pos'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

function Fail($text) { Write-Host $text -ForegroundColor Red; exit 1 }

if (-not $Zip) {
  $newest = Get-ChildItem (Join-Path $root 'dist') -Filter 'offlinePOS-windows-*.zip' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { Fail 'No release zip in dist\. Build one first.' }
  $Zip = $newest.FullName
}
if (-not (Test-Path $Zip)) { Fail "No such zip: $Zip" }
$Zip = (Resolve-Path $Zip).Path

if (-not $Version) {
  $m = [regex]::Match([IO.Path]::GetFileName($Zip), '(\d+\.\d+\.\d+\+\d+)')
  if (-not $m.Success) { Fail 'Cannot read the version from the zip name. Pass -Version 1.2.3+N.' }
  $Version = $m.Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+\+\d+$') { Fail "Version must look like 1.2.3+N, not '$Version'." }

$remoteName = "offlinePOS-$($Version -replace '\+', '-').zip"
$url = "$BaseUrl/$remoteName"
$manifest = Join-Path $env:TEMP 'offline-pos-manifest.json'

Write-Host "Signing $Version..." -ForegroundColor Cyan
& dart run tools/release_sign.dart sign $Zip $Version $url $manifest
if ($LASTEXITCODE -ne 0) { Fail 'Signing failed.' }

$size = [math]::Round((Get-Item $Zip).Length / 1MB, 1)
Write-Host "Uploading $remoteName ($size MB)..." -ForegroundColor Cyan
& scp -o ConnectTimeout=30 $Zip "${Server}:$RemoteDir/$remoteName.partial"
if ($LASTEXITCODE -ne 0) { Fail 'Upload failed.' }
& ssh -o ConnectTimeout=30 $Server "mv -f '$RemoteDir/$remoteName.partial' '$RemoteDir/$remoteName'"
if ($LASTEXITCODE -ne 0) { Fail 'Could not put the zip in place.' }

Write-Host 'Publishing the manifest...' -ForegroundColor Cyan
& scp -o ConnectTimeout=30 $manifest "${Server}:$RemoteDir/manifest.json.partial"
if ($LASTEXITCODE -ne 0) { Fail 'Manifest upload failed.' }
# Keeps the published zip and the one before it; older ones only fill the disk.
& ssh -o ConnectTimeout=30 $Server "cd '$RemoteDir' && mv -f manifest.json.partial manifest.json && ls -t offlinePOS-*.zip | tail -n +3 | xargs -r rm -f && ls -la"
if ($LASTEXITCODE -ne 0) { Fail 'Could not put the manifest in place.' }

$check = Invoke-WebRequest -UseBasicParsing "$BaseUrl/manifest.json" -TimeoutSec 30
Write-Host "`nPublished $Version. Every till with internet offers it within ten minutes." -ForegroundColor Green
Write-Host "Manifest: $BaseUrl/manifest.json ($($check.StatusCode))"
