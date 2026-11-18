# Living Wallpaper

An ASCII-mosaic aquarium on the macOS desktop. Hammerhead and leopard shark families swim
behind the desktop icons; "Evil is whatever distracts." floats in the middle, made of fine dots
that break apart when sharks swim through and settle again.

- **Hover** over the desktop: adult sharks come and circle the cursor.
- **Click open water**: food pellets sink; hungry sharks (and babies) chase them.
- **Click a shark**: you love it. Hearts, a happy swirl, and its name tag (`name · gen · family ♥`).
- **Families**: babies follow a parent and grow up in ~15 minutes. Fed, loved adults of the same
  species (never siblings) have babies. Births, feedings and loves appear in the log at the bottom left.

## Files
- `web/index.html`: the whole scene (canvas). `web/quotes.js`: the words.
- `app/main.swift`: host app. It puts a borderless WKWebView at desktop level on every screen and Space,
  forwards the cursor and clicks, and saves the tank.
- Saved tank: `~/Library/Application Support/LivingWallpaper/tank.json`.
  Full lineage log: `~/Library/Application Support/LivingWallpaper/lineage.log`.

## Run
- `./install.sh`: builds `build/LivingWallpaper.app` and starts it at login (LaunchAgent `io.github.ri-ru.living-wallpaper`).
- `./uninstall.sh`: stops it and removes it from login.
- Restart after editing `web/`: `launchctl kickstart -k gui/$(id -u)/io.github.ri-ru.living-wallpaper`
- URL options (edit ProgramArguments to add `--query "fps=12&cell=12"`): `fps`, `cell`.
- Preview: `build/LivingWallpaper --page web/index.html --snapshot DIR --at 2,8 [--eval "6:__click(500,300)"]`
  (pause the installed one first, or it covers the test window and WebKit stops drawing).

## Cost
Measured on this Mac (2026-11-19): about 32% of one core at 15 fps while the desktop is visible.
WebKit stops drawing when windows fully cover the desktop.

## Traps
- swiftc from Command Line Tools fails with the 26.x SDK. `install.sh` picks the newest 15.x SDK.
- A relative `--page` path once made `loadFileURL` throw an exception that AppKit swallowed. The path is now made absolute.
