# Registers ZK fingerprint agent in the current user's Windows Startup folder.
$ErrorActionPreference = 'Stop'
$tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$bat = Join-Path $tools 'start_zk_agent.bat'
if (-not (Test-Path $bat)) { throw "Missing $bat" }

$startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
if (-not (Test-Path $startup)) { New-Item -ItemType Directory -Path $startup -Force | Out-Null }

$lnkPath = Join-Path $startup 'OfflinePOS ZK Fingerprint Agent.lnk'
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($lnkPath)
$lnk.TargetPath = $bat
$lnk.Arguments = 'silent'
$lnk.WorkingDirectory = $tools
$lnk.WindowStyle = 7  # minimized
$lnk.Description = 'ZKTeco fingerprint agent for Offline POS (port 9201)'
$lnk.Save()

Write-Host "Installed: $lnkPath"
Write-Host "Target: $bat silent"
