<#
.SYNOPSIS
  Builds the Windows release and packs it as a zip ready to take to a shop.

.DESCRIPTION
  Run from anywhere:  powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Version 1.1.1

  -Version   Sets the version in pubspec.yaml and bumps the build number. Without
             it the version already in pubspec.yaml is built.
  -Test      Runs the whole test suite before building (about 4 minutes).
  -SkipAnalyze  Skips flutter analyze.
  -Publish   Uploads the zip to the update server (tools\publish_update.ps1).

  The zip lands in dist\ and carries UpdateOfflinePOS.bat, which is what the shop
  runs to put it in place of the installed version.
#>
param(
  [string]$Version,
  [switch]$Test,
  [switch]$SkipAnalyze,
  [switch]$Publish
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host $text -ForegroundColor Red; exit 1 }
function Run($what) {
  & $what[0] $what[1..($what.Length - 1)]
  if ($LASTEXITCODE -ne 0) { Fail "Failed: $($what -join ' ')" }
}

$pubspec = Join-Path $root 'pubspec.yaml'
$match = Select-String -Path $pubspec -Pattern '^version:\s*(\S+)'
if (-not $match) { Fail 'No version line in pubspec.yaml.' }
$current = $match.Matches[0].Groups[1].Value
$parts = $current -split '\+'
$name = $parts[0]
$number = if ($parts.Length -gt 1) { [int]$parts[1] } else { 0 }

if ($Version) {
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "Version must look like 1.2.3, not '$Version'." }
  $name = $Version
  $number += 1
  $text = [IO.File]::ReadAllText($pubspec)
  $text = [regex]::Replace($text, '(?m)^version:\s*\S+', "version: $name+$number")
  [IO.File]::WriteAllText($pubspec, $text)
  Write-Host "pubspec.yaml: $current -> $name+$number"
}
$appVersion = "$name+$number"

$sha = (git rev-parse --short HEAD).Trim()
$dirty = git status --porcelain --untracked-files=no
if ($dirty) {
  $sha = "$sha-dirty"
  Write-Host 'Warning: there are uncommitted changes. They are in this build, and the zip name says so.' -ForegroundColor Yellow
}

Step 'flutter pub get'
Run @('flutter', 'pub', 'get')
if (-not $SkipAnalyze) {
  Step 'flutter analyze'
  Run @('flutter', 'analyze')
}
if ($Test) {
  Step 'flutter test'
  Run @('flutter', 'test')
}

Step "flutter build windows $appVersion"
Run @('flutter', 'build', 'windows', '--release',
  "--build-name=$name", "--build-number=$number",
  "--dart-define=APP_VERSION=$appVersion")

$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'offline_pos.exe'))) { Fail "No offline_pos.exe in $release." }
if (-not (Test-Path (Join-Path $release 'UpdateOfflinePOS.bat'))) {
  Fail 'UpdateOfflinePOS.bat is missing from the build. Check windows\CMakeLists.txt.'
}

Step 'Packing'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zip = Join-Path $dist "offlinePOS-windows-$name-$sha.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
# A release run on this machine leaves its startup log beside the exe; it is not
# part of the app.
$items = Get-ChildItem -Path $release -Exclude '*.log' | ForEach-Object { $_.FullName }
Compress-Archive -Path $items -DestinationPath $zip -Force

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "`nReady: $zip ($size MB), version $appVersion" -ForegroundColor Green
Write-Host 'At the shop: unzip it anywhere (not over the installed folder), then run UpdateOfflinePOS.bat from the unzipped folder.'
if ($Version) { Write-Host "Commit pubspec.yaml so $appVersion is recorded." -ForegroundColor Yellow }
if ($Publish) {
  & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'publish_update.ps1') -Zip $zip -Version $appVersion
  if ($LASTEXITCODE -ne 0) { Fail 'Publishing failed.' }
}
