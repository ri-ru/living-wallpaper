# Windows: stop Living Wallpaper and remove it from login. The tank and quote.txt are kept.
Get-Process LivingWallpaper -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'Living Wallpaper.lnk') -ErrorAction SilentlyContinue
Write-Host "Stopped. Your tank is still in $env:APPDATA\LivingWallpaper\tank.sqlite"
