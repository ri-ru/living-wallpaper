# Research notes: a live web page behind the desktop on macOS, Windows and Linux

This page collects what was learned while building Living Wallpaper: how each OS lets a program draw behind the desktop icons, which tools already do this, and the problems we hit. It is meant for anyone who wants to build something similar.

Status markers:

- ✅ **verified here**: we ran it and saw it work.
- 🧪 **CI**: run on a GitHub Actions runner, not on a person's desktop.
- 📚 **from sources**: we read about it but did not test it.

---

## 1. The common idea

Every OS draws the desktop in layers, roughly *wallpaper → icons → application windows*. A live wallpaper is a normal window that you push down into the gap between the wallpaper and the icons. If you push it below the wallpaper instead, it is invisible.

A web page is a convenient thing to put in that window. Canvas, WebGL and CSS work everywhere, and every OS ships an embeddable web engine:

| OS | Engine | API |
| --- | --- | --- |
| macOS | WebKit | `WKWebView` |
| Windows | Chromium (Edge) | WebView2, built into Windows 11 |
| Linux | WebKit | WebKitGTK (`WebKit2` 4.0/4.1 GIR) |

Both WebKit engines expose `window.webkit.messageHandlers.<name>.postMessage`. WebView2 exposes `window.chrome.webview.postMessage`. A ten-line bridge in the page covers all three; see [HOST_PROTOCOL.md](HOST_PROTOCOL.md).

## 2. macOS ✅

**Technique.** Create a borderless `NSWindow` and set its level to `CGWindowLevelForKey(.desktopWindow)`. The desktop icons use the higher `.desktopIconWindow` level, so they stay on top. Then:

- Set `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]` so the window is on every Space and stays put in Mission Control.
- Set `ignoresMouseEvents = true` so clicks reach the desktop.

**Mouse.** Because the window ignores the mouse, the host polls `NSEvent.mouseLocation` about 30 times a second. It catches clicks with `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)`, which needs no Accessibility permission for mouse events. The limitation is that a global monitor also sees clicks on other apps' windows. Living Wallpaper accepts this: food dropped behind a window is invisible and harmless.

**Starting at login.** A LaunchAgent with `RunAtLoad` and `KeepAlive`.

**Power.** WebKit stops `requestAnimationFrame` when a window is fully covered (occluded). So the wallpaper costs nothing while the desktop is hidden. It also means a test window covered by the real wallpaper never draws a frame.

**Problems we hit:**

- **Silent exceptions.** `loadFileURL(_:allowingReadAccessTo:)` raises an Objective-C exception if the page URL is relative, or if it is reached through a symlink. Inside `applicationDidFinishLaunching`, AppKit catches the exception and does not report it. The result is a blank window and a process that looks healthy. Fix: make the URL absolute and call `resolvingSymlinksInPath()`, and log at the very start of launch.
- **Sleep.** After the Mac wakes, the web content process may have been suspended or killed. Watch `NSWorkspace.didWakeNotification`, `screensDidWakeNotification` and `sessionDidBecomeActiveNotification`, and implement `webViewWebContentProcessDidTerminate`.
- **Compiler and SDK.** Command Line Tools can ship an SDK newer than their own `swiftc`, which gives "this SDK is not supported by the compiler". Fall back to an older installed SDK with `-sdk`.
- **Headless Chrome is no test tool here.** On macOS in a sandboxed shell it gets no display link, so `requestAnimationFrame` never fires. Use the host's own `--snapshot` mode (`WKWebView.takeSnapshot`).

**Existing tool.** [Plash](https://github.com/sindresorhus/Plash) by Sindre Sorhus shows any website as a macOS wallpaper. Use it if you don't need persistence or click forwarding.

## 3. Windows 🧪 📚

**Technique (WorkerW).** Explorer's `Progman` window answers an undocumented message, `0x052C`. It splits the desktop into a wallpaper layer and an icon layer by creating a `WorkerW` window between them. You then make your window a child of the right window. ([dev.to explainer](https://dev.to/codenamew/how-does-a-live-wallpaper-draw-behind-your-desktop-icons-on-windows-1193))

**Windows 11 24H2 changed where that WorkerW lives.** 📚

| Windows version | Icons (`SHELLDLL_DefView`) | The new `WorkerW` | Where to attach |
| --- | --- | --- | --- |
| Before 24H2 | in Progman or a top-level WorkerW | **top-level**, right after the window that hosts the icons | `SetParent(yourWindow, thatWorkerW)` |
| 24H2 and later | child of Progman | **child of Progman** | `SetParent(yourWindow, Progman)`, then `SetWindowPos` just below `SHELLDLL_DefView`, as a layered window with alpha 255 |

Sources: [VibingWrapper PR #7](https://github.com/youllook/VibingWrapper/pull/7), [beautiful-wallpaper PR #83](https://github.com/C0uki/beautiful-wallpaper/pull/83), [Lively issue #2074](https://github.com/lively-community/lively/issues/2074), [AutoHotkey forum thread](https://www.autohotkey.com/boards/viewtopic.php?style=7&t=135199).

- Send `0x052C` with `wParam = 0xD, lParam = 1`, which is what Lively sends. Reports say that zeros no longer create the layer on 24H2. Reports also say that sending `(0xD, 0)` after `(0xD, 1)` can remove the new layer, so send only once.
- The host ([`Program.cs`](../hosts/windows/Program.cs)) tries the 24H2 layout first, then the classic layout, then a last-resort bottom child of Progman. It logs which one it used. `--no-layered` turns off the layered style if WebView2 shows black inside a layered child on some machine.

**Mouse.** A window behind the icons gets no input. A low-level mouse hook (`WH_MOUSE_LL`) sees every move and click. The host forwards only those where `WindowFromPoint` → `GetAncestor(GA_ROOT)` is `Progman` or `WorkerW`, which means the cursor is on the desktop and not on an app.

**DPI.** The app declares PerMonitorV2, so the hook and window positions both use physical pixels. To convert to CSS pixels, divide by `DeviceDpi / 96`. Format the numbers with the invariant culture: a German or Swiss locale writes `12,5`, which is a JavaScript syntax error.

**Quitting.** Ask Explorer to repaint the normal wallpaper by setting the current wallpaper again with `SPI_SETDESKWALLPAPER`.

**SQLite.** `Microsoft.Data.Sqlite` binds parameters by name, so the host rewrites each `?` into `$p1`, `$p2` and so on.

**Existing tools.** [Lively Wallpaper](https://github.com/rocksdanister/lively) (free, open source) and Wallpaper Engine (paid) both support web wallpapers. Lively is the best reference implementation of the WorkerW technique.

**Verified on a CI desktop ✅.** On a GitHub `windows-latest` runner (Windows Server 2025, build 26100, the same base as Windows 11 24H2), the host logged `Progman child below SHELLDLL_DefView (Windows 11 24H2+ layout)`. A full-screen capture shows the aquarium grid under the desktop icons ([screenshot](ci/windows-desktop-attach.png)). WebView2 renders correctly inside the layered child; it does not show black.

**Testing.** No Windows PC was available while this was written. CI on `windows-latest` builds the host and runs it twice:

- in a normal window, with snapshots and a database check
- attached to the desktop, with a full-screen screenshot and a log of the attach mode used

A GitHub runner is a server edition of Windows, not 24H2 desktop Windows. If you try it on a real PC, please report what the log says: `%APPDATA%\LivingWallpaper\log.txt`.

## 4. Linux 🧪 ✅ (X11 in Docker)

Linux has no single desktop, so there are two techniques:

| Session | Technique | Works on |
| --- | --- | --- |
| Wayland with layer-shell | a [`zwlr_layer_shell_v1`](https://wayland.app/protocols/wlr-layer-shell-unstable-v1) surface on the `BACKGROUND` layer, anchored to all four edges, exclusive zone −1 (via `gtk-layer-shell`) | KDE Plasma, Sway, Hyprland, river, labwc, Wayfire |
| X11, or GNOME on Wayland | a window with `_NET_WM_WINDOW_TYPE_DESKTOP` (GTK `WindowTypeHint.DESKTOP`); on GNOME Wayland it runs through XWayland (`GDK_BACKEND=x11`) | GNOME/X11, Xfce, Cinnamon, MATE, most X window managers |

- GNOME's compositor (Mutter) does not implement layer-shell 📚 ([icebg notes](https://www.linuxlinks.com/icebg-wayland-wallpaper-setter/)). Native GNOME Wayland live wallpapers are made as GNOME Shell extensions instead, for example [Hanabi](https://www.linuxuprising.com/2023/04/hanabi-is-live-wallpaper-for-gnome.html) and [GNOME Live Wallpaper Engine](https://openaitx.github.io/projects/achu94/gnome-wallpaper-engine/README-en.html).
- The XWayland desktop-window fallback on GNOME Wayland is **not verified**. Reports welcome.
- In both techniques the surface gets real mouse events where the desktop is visible, so no forwarding is needed.

**Problems we hit:**

- **Sandbox in containers.** WebKitGTK's bubblewrap sandbox cannot start inside Docker or CI containers. `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` is for tests only.
- **Snapshots** (`WebView.get_snapshot`) need `python3-gi-cairo`.
- **JavaScript callbacks.** PyGObject passes three arguments to async callbacks (`source, result, user_data`).
- **Fonts.** The macOS serif (Iowan Old Style) is not there. The page falls back to Palatino Linotype on Windows and DejaVu Serif on Linux.

**Existing tools.**

- [xwinwrap](https://github.com/mmhobi7/xwinwrap) puts any X11 program on the desktop.
- [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) runs Wallpaper Engine scenes.
- KDE Plasma has wallpaper plugins that show web pages.

## 5. Lock screens

None of the three systems lets an app draw a live page on the lock screen. What each host does instead:

- **macOS ✅.** Since Sonoma, the lock screen shows the desktop picture. The host already covers that picture with its own window, so it can call `NSWorkspace.setDesktopImageURL` freely. It alternates between two file names, because macOS caches the picture by URL.
- **Windows 📚.** `LockScreen.SetImageFileAsync` from `Windows.System.UserProfile` works from a desktop app when the project targets `net8.0-windows10.0.19041.0`. Managed or education editions may block it with a policy.
- **GNOME 📚.** The `picture-uri` key in `org.gnome.desktop.screensaver`. There is no shared way across other Linux lock screens.

The page renders the picture itself with `window.__quoteImage()`, which returns a PNG data URL with only the words. So the picture doesn't depend on the window being visible.

## 6. Rendering an ASCII mosaic cheaply

- **Rasterize small.** Draw each shark as vector paths into a canvas with one pixel per grid cell (about 147×96). Read it back once per frame with `getImageData` (`willReadFrequently: true`). Then stamp one pre-rendered glyph tile per lit cell with `drawImage` from an atlas. The tile is chosen by brightness × hue × glyph.
- **Layers.** Three stacked canvases:
  - background (light and sand), redrawn at about 5 fps
  - sharks, redrawn every frame
  - the words, redrawn only while any dot is moving
- **Cost**, measured on an M4 MacBook Air with `top` on the WebKit GPU and WebContent processes:

  | Frame rate | CPU (one core) |
  | --- | --- |
  | 20 fps | ~42% |
  | 15 fps | ~32% |

  Most of the cost is in the GPU process and grows with the number of tiles drawn. A WebGL instanced renderer would be the next step. It has not been tried.

## 7. Persistence design

- The page owns all the SQL: `web/schema.sql`, `web/load.json`, and the statements it sends. Every host is a dumb "run this transaction" pipe. This keeps three hosts in three languages from drifting apart.
- Foreign keys are on. Sharks are saved parents first. Events look up their shark with `(SELECT id FROM sharks WHERE id = ?)`, so an event for a shark that isn't saved yet stores `NULL` instead of failing the whole transaction.
- Names are unique across the whole family tree, dead sharks included. The tree uses IDs, but people read names.

## 8. Open questions

- ~~Does the 24H2 layered-child attach work with WebView2?~~ Yes on a CI desktop (build 26100). Still to check: a home Windows 11 PC, and the classic pre-24H2 layout on Windows 10.
- Does the XWayland desktop-window fallback stay below normal windows on GNOME 47+?
- Multi-monitor: each monitor gets its own window. Only the first keeps the saved tank; the others show fresh tanks that are never saved. A shared tank across monitors would need one canvas over the whole virtual screen.
