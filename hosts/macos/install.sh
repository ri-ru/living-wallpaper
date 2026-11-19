#!/bin/zsh
# macOS: build LivingWallpaper.app and start it at login (LaunchAgent).
# Options for the page can be passed through:  QUERY="fps=10&cell=12" ./install.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
LABEL="io.github.ri-ru.living-wallpaper"
APP="$ROOT/build/LivingWallpaper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

build() { swiftc -O "$@" -o "$APP/Contents/MacOS/LivingWallpaper" hosts/macos/main.swift -framework Cocoa -framework WebKit -lsqlite3; }
if ! build 2>/dev/null; then
  # Command Line Tools sometimes ship an SDK newer than their compiler; fall back to the newest 15.x SDK.
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$SDK" ]] || { build; exit 1; }   # show the real error
  build -sdk "$SDK"
fi
ln -sfn "$ROOT/web" "$APP/Contents/Resources/web"      # edits to web/ show up after a restart

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>LivingWallpaper</string>
  <key>CFBundleExecutable</key><string>LivingWallpaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL

ARGS="<string>$APP/Contents/MacOS/LivingWallpaper</string>"
[[ -n "$QUERY" ]] && ARGS="$ARGS<string>--query</string><string>${QUERY//&/&amp;}</string>"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/Logs/living-wallpaper" "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>$ARGS</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/living-wallpaper/err.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for i in {1..20}; do launchctl list "$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done   # bootout finishes asynchronously
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed and running ($LABEL)"
echo "edit the words: $HOME/Library/Application Support/LivingWallpaper/quote.txt (changes show within 2 s)"
