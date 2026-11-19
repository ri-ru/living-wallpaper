#!/usr/bin/env python3
"""Living Wallpaper: Linux host (GTK 3 + WebKitGTK).

Puts web/index.html behind the desktop on every monitor and implements the host contract in
docs/HOST_PROTOCOL.md: inject __tank/__quote, run the page's SQL, watch quote.txt.

How it sits behind everything:
  * Wayland with layer-shell (KDE Plasma, Sway, Hyprland, river, labwc, ...): a layer surface on
    the BACKGROUND layer.
  * X11, or Wayland without layer-shell (GNOME): a window of type _NET_WM_WINDOW_TYPE_DESKTOP,
    run through XWayland on Wayland. Desktop-type windows sit below normal windows.
In both cases the page receives real mouse events where the desktop is visible, so no forwarding.

Usage: living_wallpaper.py [--page PATH] [--db PATH] [--query fps=12] [--quote TEXT]
                           [--quote-file PATH] [--windowed] [--snapshot DIR --at 2,6] [--eval SEC:JS]
"""
import argparse
import json
import os
import sqlite3
import sys

# GNOME's Wayland compositor has no layer-shell; fall back to XWayland so the desktop window type works.
if os.environ.get("XDG_SESSION_TYPE") == "wayland" and "GDK_BACKEND" not in os.environ:
    try:
        import gi
        gi.require_version("GtkLayerShell", "0.1")
        from gi.repository import GtkLayerShell  # noqa: F401
        HAVE_LAYER_SHELL = True
    except (ImportError, ValueError):
        HAVE_LAYER_SHELL = False
    if not HAVE_LAYER_SHELL or "GNOME" in os.environ.get("XDG_CURRENT_DESKTOP", ""):
        os.environ["GDK_BACKEND"] = "x11"

import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
for v in ("4.1", "4.0"):
    try:
        gi.require_version("WebKit2", v)
        break
    except ValueError:
        continue
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

try:
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import GtkLayerShell  # noqa: E402
except (ImportError, ValueError):
    GtkLayerShell = None

DEFAULT_QUOTE = "Evil is whatever distracts."
HERE = os.path.dirname(os.path.realpath(__file__))
XDG_DATA = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
XDG_CONFIG = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")


def log(*a):
    print("living-wallpaper:", *a, file=sys.stderr, flush=True)


class Tank:
    """The SQLite tank. All SQL comes from the page: web/schema.sql, web/load.json and its messages."""

    def __init__(self, path, schema):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(schema)

    def transaction(self, tx):
        try:
            self.db.execute("BEGIN")
            for item in tx:
                self.db.execute(item[0], item[1] if len(item) > 1 else [])
            self.db.execute("COMMIT")
        except sqlite3.Error as e:
            log("sql:", e)
            self.db.execute("ROLLBACK")

    def load(self, queries):
        return {k: [dict(r) for r in self.db.execute(q)] for k, q in queries.items()}


class Host:
    def __init__(self, o):
        self.o = o
        web = os.path.dirname(o.page)
        with open(os.path.join(web, "schema.sql")) as f:
            self.tank = Tank(o.db, f.read())
        with open(os.path.join(web, "load.json")) as f:
            self.queries = json.load(f)
        self.views = []
        self.quote_mtime = None
        self.ensure_quote_file()
        self.build()
        GLib.timeout_add_seconds(2, self.watch_quote)
        if o.snapshot:
            self.schedule_snapshots()
        for sec, js in o.evals:
            GLib.timeout_add(int(sec * 1000), lambda js=js: [self.run_js(v, js) for v in self.views] and False)
        log(f"page={o.page} db={o.db} quote={o.quote_file}")

    # ---- quote.txt: created on first run so people can find it; watched for changes ----
    def ensure_quote_file(self):
        if self.o.quote is None and not os.path.exists(self.o.quote_file):
            os.makedirs(os.path.dirname(self.o.quote_file), exist_ok=True)
            with open(self.o.quote_file, "w") as f:
                f.write(DEFAULT_QUOTE + "\n")

    def current_quote(self):
        if self.o.quote is not None:
            return self.o.quote
        try:
            with open(self.o.quote_file) as f:
                return f.read().strip() or DEFAULT_QUOTE
        except OSError:
            return DEFAULT_QUOTE

    def watch_quote(self):
        if self.o.quote is None:
            try:
                m = os.path.getmtime(self.o.quote_file)
            except OSError:
                m = None
            if self.quote_mtime is not None and m != self.quote_mtime:
                for v in self.views:
                    self.run_js(v, f"window.__setQuote && window.__setQuote({json.dumps(self.current_quote())})")
            self.quote_mtime = m
        return True

    # ---- windows ----
    def build(self):
        display = Gdk.Display.get_default()
        monitors = [display.get_monitor(i) for i in range(display.get_n_monitors())]
        if self.o.windowed or self.o.snapshot:
            monitors = monitors[:1]
        layer = (GtkLayerShell is not None and not self.o.windowed and os.environ.get("GDK_BACKEND") != "x11"
                 and (GtkLayerShell.is_supported() if hasattr(GtkLayerShell, "is_supported") else True))
        for i, mon in enumerate(monitors):
            geo = mon.get_geometry()
            win = Gtk.Window()
            win.set_title("Living Wallpaper")
            if self.o.windowed:
                win.set_default_size(1280, 800)
            elif layer:
                GtkLayerShell.init_for_window(win)
                GtkLayerShell.set_layer(win, GtkLayerShell.Layer.BACKGROUND)
                GtkLayerShell.set_monitor(win, mon)
                for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM, GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
                    GtkLayerShell.set_anchor(win, edge, True)
                GtkLayerShell.set_exclusive_zone(win, -1)
                GtkLayerShell.set_namespace(win, "living-wallpaper")
            else:
                win.set_type_hint(Gdk.WindowTypeHint.DESKTOP)
                win.set_decorated(False)
                win.set_skip_taskbar_hint(True)
                win.set_skip_pager_hint(True)
                win.set_keep_below(True)
                win.stick()
                win.move(geo.x, geo.y)
                win.set_default_size(geo.width, geo.height)

            ucm = WebKit2.UserContentManager()
            boot = f"window.__host = 'linux'; window.__quote = {json.dumps(self.current_quote())};"
            if i == 0:   # only the first monitor keeps the persistent tank
                ucm.register_script_message_handler("sql")
                ucm.connect("script-message-received::sql", self.on_sql)
                boot += f"window.__tank = {json.dumps(self.tank.load(self.queries))};"
            ucm.add_script(WebKit2.UserScript.new(boot, WebKit2.UserContentInjectedFrames.TOP_FRAME,
                                                  WebKit2.UserScriptInjectionTime.START, None, None))
            view = WebKit2.WebView.new_with_user_content_manager(ucm)
            s = view.get_settings()
            s.set_allow_file_access_from_file_urls(True)
            s.set_enable_developer_extras(True)
            view.set_background_color(Gdk.RGBA(0, 0, 0, 1))
            uri = "file://" + self.o.page + (("?" + self.o.query) if self.o.query else "")
            view.load_uri(uri)
            win.add(view)
            win.connect("destroy", Gtk.main_quit)
            win.show_all()
            self.views.append(view)
        log("mode:", "windowed" if self.o.windowed else ("layer-shell" if layer else f"desktop window ({os.environ.get('GDK_BACKEND', 'auto')})"))

    def on_sql(self, _ucm, result):
        try:
            value = result.get_js_value() if hasattr(result, "get_js_value") else result
            msg = json.loads(value.to_string())
            self.tank.transaction(msg.get("tx", []))
        except Exception as e:  # never let a bad message kill the wallpaper
            log("bad message:", e)

    @staticmethod
    def run_js(view, js, cb=None):
        if hasattr(view, "evaluate_javascript"):        # WebKitGTK >= 2.40
            view.evaluate_javascript(js, -1, None, None, None, cb, None)
        else:
            view.run_javascript(js, None, cb, None)

    # ---- test mode: PNG snapshots of the first view at given seconds ----
    def schedule_snapshots(self):
        os.makedirs(self.o.snapshot, exist_ok=True)
        for t in self.o.at:
            GLib.timeout_add(int(t * 1000), self.snap, t)
        GLib.timeout_add(int((max(self.o.at) + 1.5) * 1000), Gtk.main_quit)

    def snap(self, t):
        view = self.views[0]

        def done(v, res, *_):
            try:
                surface = v.get_snapshot_finish(res)
                surface.write_to_png(os.path.join(self.o.snapshot, f"snap_{t:05.1f}.png"))
            except Exception as e:
                log("snapshot failed:", e)

        def report(v, res, *_):
            try:
                r = v.evaluate_javascript_finish(res) if hasattr(v, "evaluate_javascript_finish") else v.run_javascript_finish(res).get_js_value()
                log(f"snapshot {t}: errors+frames {r.to_string()}")
            except Exception as e:
                log("report failed:", e)

        self.run_js(view, "JSON.stringify([window.__errs, window.__frames && window.__frames()])", report)
        view.get_snapshot(WebKit2.SnapshotRegion.VISIBLE, WebKit2.SnapshotOptions.NONE, None, done)
        return False


def main():
    p = argparse.ArgumentParser(description="Living Wallpaper (Linux host)")
    p.add_argument("--page", default=os.path.join(HERE, "..", "..", "web", "index.html"))
    p.add_argument("--db", default=os.path.join(XDG_DATA, "living-wallpaper", "tank.sqlite"))
    p.add_argument("--query", default="")
    p.add_argument("--quote")
    p.add_argument("--quote-file", default=os.path.join(XDG_CONFIG, "living-wallpaper", "quote.txt"))
    p.add_argument("--windowed", action="store_true", help="a normal window, for trying it out")
    p.add_argument("--snapshot", help="test mode: write PNGs to this folder, then quit")
    p.add_argument("--at", default="3", help="snapshot times in seconds, comma separated")
    p.add_argument("--eval", action="append", default=[], help="SEC:JS, run JS after SEC seconds")
    o = p.parse_args()
    o.page = os.path.realpath(o.page)
    o.at = [float(x) for x in o.at.split(",")]
    o.evals = [(float(e.split(":", 1)[0]), e.split(":", 1)[1]) for e in o.eval]
    Host(o)
    Gtk.main()


if __name__ == "__main__":
    main()
