# Windows: build Living Wallpaper, start it now and at every login (Startup folder shortcut).
# Needs the .NET 8 SDK (winget install Microsoft.DotNet.SDK.8) and the WebView2 runtime (built into Windows 11).
# Options for the page:  $env:QUERY = "fps=10"; .\install.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host "The .NET 8 SDK is needed to build. Install it with:  winget install Microsoft.DotNet.SDK.8"
    exit 1
}
$out = Join-Path $env:LOCALAPPDATA 'LivingWallpaper\app'
Get-Process LivingWallpaper -ErrorAction SilentlyContinue | Stop-Process -Force
dotnet publish "$root\hosts\windows\LivingWallpaper.csproj" -c Release -r win-x64 --self-contained false -o $out
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$exe = Join-Path $out 'LivingWallpaper.exe'
$arguments = "--page `"$root\web\index.html`""
if ($env:QUERY) { $arguments += " --query `"$env:QUERY`"" }

$startup = [Environment]::GetFolderPath('Startup')
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startup 'Living Wallpaper.lnk'))
$shortcut.TargetPath = $exe
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $out
$shortcut.Save()

Start-Process $exe -ArgumentList $arguments
Write-Host "Installed and running. It starts at every login."
Write-Host "Edit the words: $env:APPDATA\LivingWallpaper\quote.txt (changes show within 2 s)"
Write-Host "Log: $env:APPDATA\LivingWallpaper\log.txt"
