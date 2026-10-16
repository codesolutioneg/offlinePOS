# Offline POS: download the newest release and put it in place of the installed copy.
#
# Served next to the manifest on the update server, so a till that does not take
# the in-app update can be brought up to date from PowerShell with:
#   irm https://updates.91.99.195.177.sslip.io/offline-pos/update.ps1 | iex
#
# Wrapped in a script block and never calls exit: under iex an exit would close
# the window the shop typed into, taking the error message with it.
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $base = 'https://updates.91.99.195.177.sslip.io/offline-pos'

  Write-Host '=== Offline POS: download the latest version ===' -ForegroundColor Cyan
  try {
    $outer = Invoke-RestMethod "$base/manifest.json" -TimeoutSec 30
    $m = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($outer.manifest)) | ConvertFrom-Json
    Write-Host "Latest version: $($m.version)"

    $work = Join-Path $env:TEMP "OfflinePOS-update-$($m.build_number)"
    $zip = "$work.zip"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    Write-Host ("Downloading {0:N1} MB..." -f ($m.size / 1MB))
    Invoke-WebRequest -UseBasicParsing $m.url -OutFile $zip -TimeoutSec 900

    # The hash comes from the release manifest, so a cut-off or altered download
    # is refused before anything on the till is touched.
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne "$($m.sha256)".ToLower()) {
      Remove-Item $zip -Force
      throw "The download is damaged (got $hash, expected $($m.sha256)). Nothing was changed."
    }

    Write-Host 'Unpacking...'
    Expand-Archive $zip -DestinationPath $work -Force
    Remove-Item $zip -Force
    $updater = Get-ChildItem $work -Recurse -Filter 'update_offline_pos.ps1' | Select-Object -First 1
    if (-not $updater) { throw 'The download has no updater in it. Nothing was changed.' }
    $source = Split-Path (Split-Path $updater.FullName -Parent) -Parent

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater.FullName -Source $source -Yes
  } catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
  }
}
