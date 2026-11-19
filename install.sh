#!/bin/sh
# Installs Living Wallpaper for this OS. Windows: run install.ps1 in PowerShell instead.
set -e
cd "$(dirname "$0")"
case "$(uname -s)" in
  Darwin) exec hosts/macos/install.sh "$@" ;;
  Linux)  exec hosts/linux/install.sh "$@" ;;
  *) echo "Unsupported OS: $(uname -s). On Windows, run install.ps1 in PowerShell." >&2; exit 1 ;;
esac
