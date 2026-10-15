# Clones gplay-apk-downloader into windows/third_party so CMake can bundle it as gplay_server/
# next to adbappmanager.exe. Run from repo root: powershell -ExecutionPolicy Bypass -File tools/fetch_gplay_server.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dest = Join-Path $root "windows\third_party\gplay-apk-downloader"
$url = "https://github.com/alltechdev/gplay-apk-downloader.git"

if (Test-Path $dest) {
  Write-Host "Already exists: $dest"
  Write-Host "Updating with git pull..."
  Push-Location $dest
  try { git pull } finally { Pop-Location }
  exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
git clone --depth 1 $url $dest
Write-Host "Cloned to $dest. Rebuild the Flutter Windows app to copy gplay_server into the output folder."
