#!/bin/sh
# Linux: check dependencies, then start Living Wallpaper now and at every login (XDG autostart).
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="$ROOT/hosts/linux/living_wallpaper.py"
chmod +x "$HOST"

if ! python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("WebKit2","4.1")' 2>/dev/null &&
   ! python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("WebKit2","4.0")' 2>/dev/null; then
  echo "Missing dependencies. Install them with one of:"
  echo "  Debian/Ubuntu: sudo apt install python3-gi gir1.2-webkit2-4.1 gir1.2-gtklayershell-0.1"
  echo "  Fedora:        sudo dnf install python3-gobject webkit2gtk4.1 gtk-layer-shell"
  echo "  Arch:          sudo pacman -S python-gobject webkit2gtk-4.1 gtk-layer-shell"
  echo "(gtk-layer-shell is optional: it is used on KDE, Sway, Hyprland and other wlroots desktops.)"
  exit 1
fi

ARGS=""
[ -n "$QUERY" ] && ARGS="--query $QUERY"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
mkdir -p "$AUTOSTART"
cat > "$AUTOSTART/living-wallpaper.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Living Wallpaper
Comment=ASCII shark aquarium behind the desktop
Exec=$HOST $ARGS
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOP

pkill -f "hosts/linux/living_wallpaper.py" 2>/dev/null || true
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/living-wallpaper"
nohup "$HOST" $ARGS >"${XDG_STATE_HOME:-$HOME/.local/state}/living-wallpaper/log.txt" 2>&1 &
echo "installed and running (autostart: $AUTOSTART/living-wallpaper.desktop)"
echo "edit the words: ${XDG_CONFIG_HOME:-$HOME/.config}/living-wallpaper/quote.txt (changes show within 2 s)"
echo "Sway/Hyprland users: autostart files are not read there; add  exec $HOST  to your compositor config."
