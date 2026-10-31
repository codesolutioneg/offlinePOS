# Download official embeddable Python 3.11 into tools\.py311\
# Does NOT require any system Python (avoids Microsoft Store "python" alias).
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$PyDir = Join-Path $Tools ".py311"
$PyExe = Join-Path $PyDir "python.exe"
$EmbedUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip"
$GetPipUrl = "https://bootstrap.pypa.io/get-pip.py"

function Write-Info([string]$Msg) {
  [Console]::Error.WriteLine($Msg)
}

if (Test-Path -LiteralPath $PyExe) {
  Write-Info "[OK] Bundled Python already present: $PyExe"
  Write-Output $PyExe
  exit 0
}

New-Item -ItemType Directory -Force -Path $PyDir | Out-Null
$ZipPath = Join-Path $PyDir "python311-embed.zip"

Write-Info "[..] Downloading Python 3.11.9 embeddable (~10 MB)..."
try {
  # TLS 1.2 for older Windows PowerShell
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $EmbedUrl -OutFile $ZipPath -UseBasicParsing
} catch {
  Write-Info "[X] Download failed: $_"
  Write-Info "    Manual: $EmbedUrl"
  exit 1
}

Write-Info "[..] Extracting..."
Expand-Archive -Path $ZipPath -DestinationPath $PyDir -Force
Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $PyExe)) {
  Write-Info "[X] python.exe missing after extract in $PyDir"
  exit 1
}

# Enable site-packages for embeddable distro
Get-ChildItem -LiteralPath $PyDir -Filter "*._pth" | ForEach-Object {
  $lines = Get-Content -LiteralPath $_.FullName
  $out = @()
  $hasSite = $false
  foreach ($line in $lines) {
    if ($line -match '^\s*#\s*import site\s*$') {
      $out += "import site"
      $hasSite = $true
    } elseif ($line -match '^\s*import site\s*$') {
      $out += "import site"
      $hasSite = $true
    } else {
      $out += $line
    }
  }
  if (-not $hasSite) { $out += "import site" }
  Set-Content -LiteralPath $_.FullName -Value ($out -join "`n") -Encoding ASCII
}

$GetPip = Join-Path $PyDir "get-pip.py"
Write-Info "[..] Installing pip..."
try {
  Invoke-WebRequest -Uri $GetPipUrl -OutFile $GetPip -UseBasicParsing
  & $PyExe $GetPip --no-warn-script-location
  if ($LASTEXITCODE -ne 0) { throw "get-pip exit $LASTEXITCODE" }
} catch {
  Write-Info "[X] pip install failed: $_"
  exit 1
}

Write-Info "[OK] Bundled Python ready: $PyExe"
Write-Output $PyExe
exit 0
