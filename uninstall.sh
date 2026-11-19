#!/bin/sh
# Removes Living Wallpaper from login. The tank (SQLite) and quote.txt are kept.
set -e
cd "$(dirname "$0")"
case "$(uname -s)" in
  Darwin) exec hosts/macos/uninstall.sh ;;
  Linux)  exec hosts/linux/uninstall.sh ;;
  *) echo "On Windows, run uninstall.ps1 in PowerShell." >&2; exit 1 ;;
esac
