#!/bin/zsh
# Stop the wallpaper and remove it from login.
launchctl bootout gui/$(id -u)/io.github.ri-ru.living-wallpaper 2>/dev/null
mkdir -p ~/to-delete && mv ~/Library/LaunchAgents/io.github.ri-ru.living-wallpaper.plist ~/to-delete/ 2>/dev/null && \
  echo "io.github.ri-ru.living-wallpaper.plist | ~/Library/LaunchAgents | $(date +%F) | living wallpaper uninstalled" >> ~/to-delete/manifest.txt
echo stopped
