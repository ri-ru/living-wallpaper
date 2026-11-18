#!/bin/zsh
# Build LivingWallpaper.app and start it at login. Re-run after editing app/main.swift.
set -e
cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/LivingWallpaper.app"
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk 2>/dev/null | sort -V | tail -1)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O ${SDK:+-sdk} ${SDK:+"$SDK"} -o "$APP/Contents/MacOS/LivingWallpaper" app/main.swift -framework Cocoa -framework WebKit -lsqlite3
ln -sfn "$ROOT/web" "$APP/Contents/Resources/web"      # edits to web/ show up after a restart
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.ri-ru.living-wallpaper</string>
  <key>CFBundleName</key><string>LivingWallpaper</string>
  <key>CFBundleExecutable</key><string>LivingWallpaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
PLIST="$HOME/Library/LaunchAgents/io.github.ri-ru.living-wallpaper.plist"
mkdir -p "$HOME/Library/Logs/living-wallpaper"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.github.ri-ru.living-wallpaper</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/LivingWallpaper</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/living-wallpaper/err.log</string>
</dict></plist>
PL
launchctl bootout gui/$(id -u)/io.github.ri-ru.living-wallpaper 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "running: $(launchctl list | grep living-wallpaper)"
