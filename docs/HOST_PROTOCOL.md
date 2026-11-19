# The host contract

The scene in `web/` is one HTML file. It does not know which operating system it runs on. A **host** is the small native program that puts the scene behind the desktop. There are three hosts:

| Host | Language | Web engine | Lines |
| --- | --- | --- | --- |
| [`hosts/macos/main.swift`](../hosts/macos/main.swift) | Swift | WKWebView (WebKit) | ~300 |
| [`hosts/windows/Program.cs`](../hosts/windows/Program.cs) | C# (.NET 8) | WebView2 (Chromium) | ~400 |
| [`hosts/linux/living_wallpaper.py`](../hosts/linux/living_wallpaper.py) | Python 3 | WebKitGTK | ~250 |

To port the scene to another platform, or to put a different page behind your desktop, write a host that does the six things below (a seventh, the lock screen, is optional). The host never contains scene logic or SQL of its own.

## 1. Show the page behind the desktop

- Open `web/index.html` with a borderless window on each monitor, sized to the monitor.
- Put the window below all application windows and, if the platform has desktop icons, below the icons.
- How to do this differs completely per OS. See [RESEARCH.md](RESEARCH.md).
- The page reads options from its URL query string, for example `?fps=10&cell=12&quote=...`. Pass `--query` through.

## 2. Inject start-up values

Before the page's own scripts run (WKUserScript at document start, `AddScriptToExecuteOnDocumentCreatedAsync`, or WebKitGTK `UserScript` at `START`), set:

| Global | Value |
| --- | --- |
| `window.__host` | `'macos'`, `'windows'` or `'linux'` |
| `window.__quote` | the contents of `quote.txt` (see 5) |
| `window.__tank` | first monitor only: `{key: rows}` from running each query in `web/load.json` |

The rows are plain objects, column name to value, and they're serialized as JSON. Monitors other than the first get no `__tank`. They show a fresh tank that is never saved.

## 3. Keep the tank in SQLite

- At start-up, open the database file and run `web/schema.sql`. The script is idempotent.
- The page sends one kind of message: a JSON string `{"tx": [[sql, [params...]], ...]}`. Run all the statements in **one transaction**, and roll back if any of them fails.
- Parameters are positional `?`. Values are JSON numbers, strings or null. Bind whole numbers as integers.

| Engine | How the page sends | How the host receives |
| --- | --- | --- |
| WKWebView, WebKitGTK | `window.webkit.messageHandlers.sql.postMessage(str)` | message handler named `sql` |
| WebView2 | `window.chrome.webview.postMessage(str)` | `WebMessageReceived` and `TryGetWebMessageAsString()` |

In a plain browser there is no host, so nothing is saved, and the scene still runs.

## 4. Feed it the mouse, if the window cannot get input itself

If the wallpaper window ignores the mouse (macOS) or sits behind the icons (Windows), forward input yourself. Call these in CSS pixels relative to that monitor's window:

```js
window.__mouse(x, y)   // the cursor moved (about 30 times a second at most)
window.__click(x, y)   // left button pressed
```

- Only forward input when the cursor is over the desktop. Windows checks this with `WindowFromPoint`.
- On Linux the wallpaper surface gets real mouse events wherever the desktop is visible, so it needs no forwarding.

## 5. The quote file

- Each OS has a `quote.txt` in its data folder (below). If the file doesn't exist, create it with the default text, so people can find it.
- Every 2 seconds, check the file's modification time. When it changes, call `window.__setQuote(text)`. Line breaks in the file are kept.
- `--quote "text"` overrides the file.

## 6. Survive sleep and crashes

- Before the computer sleeps, call `window.__save()`.
- After it wakes, the screen unlocks, or the user switches back, reload the page or rebuild the windows. The page restores itself from SQLite.
- If the web content process dies (`webViewWebContentProcessDidTerminate`, `ProcessFailed`, `web-process-terminated`), reload it.

## 7. Optional: the lock screen

`window.__quoteImage()` returns a PNG data URL with only the words. A host can save it as the system lock-screen picture now and then: at lock, at sleep, and every few minutes. Before the first change, save the current picture so that uninstalling can restore it.

## Files and folders

| | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Tank | `~/Library/Application Support/LivingWallpaper/tank.sqlite` | `%APPDATA%\LivingWallpaper\tank.sqlite` | `~/.local/share/living-wallpaper/tank.sqlite` |
| Quote | `~/Library/Application Support/LivingWallpaper/quote.txt` | `%APPDATA%\LivingWallpaper\quote.txt` | `~/.config/living-wallpaper/quote.txt` |
| Log | `~/Library/Logs/living-wallpaper/err.log` | `%APPDATA%\LivingWallpaper\log.txt` | `~/.local/state/living-wallpaper/log.txt` |
| Starts at login via | LaunchAgent | Startup folder shortcut | `~/.config/autostart/*.desktop` |

## Test flags (all hosts)

| Flag | Meaning |
| --- | --- |
| `--page PATH` | the HTML file to show |
| `--db PATH` | the SQLite file (use a scratch file in tests) |
| `--query Q` | URL query passed to the page |
| `--quote TEXT`, `--quote-file PATH` | override the quote, or where it is read from |
| `--windowed` | a normal window instead of a wallpaper |
| `--snapshot DIR --at 3,8` | save PNGs of the page at those seconds, then quit |
| `--eval "SEC:JS"` | run JavaScript after SEC seconds (for example `"6:__click(400,300)"`) |

The CI workflow ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) uses these flags to run every host on a real machine. During the run it clicks once and changes `quote.txt`. [`tests/check_tank.py`](../tests/check_tank.py) then checks the database.
