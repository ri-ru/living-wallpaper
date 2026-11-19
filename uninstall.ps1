# Windows: stop Living Wallpaper and remove it from login. The tank and quote.txt are kept.
Get-Process LivingWallpaper -ErrorAction SilentlyContinue | Stop-Process -Force
$exe = Join-Path $env:LOCALAPPDATA 'LivingWallpaper\app\LivingWallpaper.exe'
if (Test-Path $exe) { Start-Process $exe -ArgumentList '--restore-lockscreen', '--page', "$PSScriptRoot\web\index.html" -Wait }   # put the old lock screen back
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'Living Wallpaper.lnk') -ErrorAction SilentlyContinue
Write-Host "Stopped. Your tank is still in $env:APPDATA\LivingWallpaper\tank.sqlite"
