#!/bin/zsh
# Stop the wallpaper and remove it from login. Your tank (the SQLite file) is kept.
LABEL="io.github.ri-ru.living-wallpaper"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "stopped. Your tank is still in ~/Library/Application Support/LivingWallpaper/tank.sqlite"
