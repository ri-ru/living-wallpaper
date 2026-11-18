# Living Wallpaper

A live aquarium for your macOS desktop, drawn in ASCII.

Hammerhead and leopard sharks swim behind your desktop icons. They are made of tiny monospace tiles, and they swim through a line of text: *"Evil is whatever distracts."* When a shark passes, the letters scatter and then settle back.

The sharks live in families. They have babies, grow up, get hungry, die, and sink to the sand, where they crumble into food for the others. The whole family tree is saved in a SQLite database.

![Living Wallpaper preview](docs/preview.gif)

## What you can do

| You do | What happens |
| --- | --- |
| Move the cursor over the desktop | Adult sharks swim over and circle it. |
| Click open water | Food pellets sink. Hungry sharks (babies too) race for them. |
| Click a shark | You love it. Hearts rise, it does a happy swirl, and its name tag shows: `name · gen · family · age ♥`. |
| Do nothing | Life goes on. Babies grow, adults pair up, the old ones die. |

## Life in the tank

- **Families.** The tank opens with four founding families. Every shark has a name, a generation and two parents. A few tiles along each shark's back show its family colour.
- **Babies** swim beside a parent and reach adult size in about 15 minutes. Food makes them grow faster.
- **Breeding.** Two well-fed adults of the same species can have a baby, more often if you have loved them. Siblings never pair. The tank stops breeding at 24 living sharks.
- **Death.** Each shark lives 6–12 hours of real time. Then it turns grey, sinks, rests on the sand, and falls apart tile by tile into food pellets.
- **Newcomers.** If fewer than 3 sharks are alive, a new family drifts in from the edge.
- **The log** in the bottom-left corner shows the last few births, meals, loves and deaths.

## Install

You need macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/ri-ru/living-wallpaper.git
cd living-wallpaper
./install.sh
```

`install.sh` builds a small app, `build/LivingWallpaper.app`. It also adds a LaunchAgent, so the wallpaper starts at login and restarts if it crashes. There is no Dock icon and no menu-bar item.

To remove it, run `./uninstall.sh`. It keeps your tank.

**Just want to look?** Open `web/index.html` in a browser. Everything works there except saving.

## Make it yours

| Change | Where |
| --- | --- |
| The words | `web/quotes.js` |
| Frame rate, cell size | `QUERY="fps=10&cell=12" ./install.sh` |
| Lifespan, growth time, population cap, newcomer threshold | constants at the top of `web/index.html` (`LIFE_HOURS`, `GROW_SECONDS`, `MAX_SHARKS`, `MIN_ALIVE`) |
| Sinking and decay speed | `SINK_SPEED`, `REST_MS`, `DECAY_MS` in `web/index.html` |
| Shark and tile colours, family colours | `HUES`, `FAMILY_HUES` in `web/index.html` |
| Shark shape | `width()` and `drawShark()` in `web/index.html` |

After you edit anything in `web/`, restart the wallpaper:

```sh
launchctl kickstart -k gui/$(id -u)/io.github.ri-ru.living-wallpaper
```

## The family tree (SQLite)

Everything is saved in `~/Library/Application Support/LivingWallpaper/tank.sqlite`:

| Table / view | Contents |
| --- | --- |
| `families` | `id, name, hue, founded_at` |
| `sharks` | `id, name, species, family_id → families, generation, parent_a_id → sharks, parent_b_id → sharks, born_at, lifespan_hours, died_at, length, adult_length, fullness, love` |
| `events` | `id, at, kind, shark_id → sharks, text`. The kinds are `opened`, `arrived`, `born`, `fed`, `loved`, `died` and `returned`. |
| `babies` (view) | Every shark that has parents, with the parents' names and the family name. |
| `alive` (view) | Sharks that have not died. |

```sh
DB=~/Library/Application\ Support/LivingWallpaper/tank.sqlite
sqlite3 -header -column "$DB" "select * from babies"
sqlite3 -header -column "$DB" "select at, text from events order by id desc limit 20"
```

To start a fresh tank, uninstall, move `tank.sqlite` somewhere else, then install again.

## How it works

- `app/main.swift` is the host. It puts a borderless `WKWebView` at desktop level on every screen and every Space, behind the desktop icons. It sends the cursor position and clicks to the page, because the window itself ignores the mouse. It also writes the tank to SQLite.
- `web/index.html` is the scene, drawn on a canvas:
  - Each shark has a spine of 26 points; every point follows the one in front of it, and a wave runs down the tail.
  - Each frame, the sharks are drawn into a low-resolution canvas with one pixel per grid cell. Each lit cell then becomes a monospace glyph tile, chosen by its brightness.
  - The words are a few thousand 2-px dots on springs.
  - There are three layers: a slow background (light and sand), the sharks, and the words. The words layer is only redrawn while dots are moving.

## Cost

On an M4 MacBook Air, it uses about 32% of one CPU core while any part of the desktop is visible. Most of that is in the WebKit GPU process. When windows cover the desktop completely, WebKit stops drawing. Use `fps=10` for less.

## Troubleshooting

- **Build fails with "this SDK is not supported by the compiler".** The Command Line Tools can ship an SDK that is newer than their compiler. `install.sh` then falls back to the newest macOS 15 SDK it finds. If none is installed, update the Command Line Tools.
- **Nothing shows.** Check `~/Library/Logs/living-wallpaper/err.log`.
- **Preview without installing.** Run `build/LivingWallpaper --page web/index.html --db /tmp/test.sqlite --snapshot /tmp/snaps --at 3,10`. To simulate a click, add `--eval "6:__click(500,300)"`. Uninstall first: the installed wallpaper covers the test window, and WebKit stops drawing covered windows.

## Credits

The ASCII sharks were inspired by a shark animation posted on X by [@stackedlol](https://x.com/stackedlol/status/2113123074115830201). The words are from Franz Kafka's Zürau aphorisms. All code is original and MIT-licensed.
