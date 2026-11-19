#!/bin/zsh
# Stop the wallpaper and remove it from login. Your tank (the SQLite file) is kept.
LABEL="io.github.ri-ru.living-wallpaper"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
# put back the desktop picture that the lock-screen snapshots replaced
APP="$(cd "$(dirname "$0")/../.." && pwd)/build/LivingWallpaper.app/Contents/MacOS/LivingWallpaper"
[ -x "$APP" ] && "$APP" --restore-wallpaper
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "stopped. Your tank is still in ~/Library/Application Support/LivingWallpaper/tank.sqlite"
