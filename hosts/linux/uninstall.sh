#!/bin/sh
# Linux: stop Living Wallpaper and remove it from autostart. The tank and quote.txt are kept.
pkill -f "hosts/linux/living_wallpaper.py" 2>/dev/null || true
python3 "$(dirname "$0")/living_wallpaper.py" --restore-lockscreen 2>/dev/null || true   # put back GNOME's lock screen picture
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/living-wallpaper.desktop"
echo "stopped. Your tank is still in ${XDG_DATA_HOME:-$HOME/.local/share}/living-wallpaper/tank.sqlite"
