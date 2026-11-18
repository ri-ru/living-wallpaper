// Living Wallpaper host: shows web/index.html behind the desktop icons on every screen and Space.
// Usage: LivingWallpaper [--query "fps=12"] [--db PATH] [--snapshot DIR --at 2,6,15] [--eval "sec:js"]
import Cocoa
import WebKit

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

import SQLite3

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LivingWallpaper")
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The tank lives in one SQLite file: families, sharks (with parent links) and an event log.
final class TankDB: NSObject, WKScriptMessageHandler {
    var db: OpaquePointer?

    init(path: String) {
        super.init()
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if sqlite3_open(path, &db) != SQLITE_OK { log("db open failed: \(path)") }
        exec("""
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS families (
          id         INTEGER PRIMARY KEY,
          name       TEXT NOT NULL,
          hue        TEXT,
          founded_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
        );
        CREATE TABLE IF NOT EXISTS sharks (
          id             INTEGER PRIMARY KEY,
          name           TEXT NOT NULL,
          species        TEXT NOT NULL CHECK (species IN ('hammerhead', 'leopard')),
          family_id      INTEGER NOT NULL REFERENCES families(id),
          generation     INTEGER NOT NULL,
          parent_a_id    INTEGER REFERENCES sharks(id),
          parent_b_id    INTEGER REFERENCES sharks(id),
          born_at        TEXT NOT NULL,
          born_ms        INTEGER NOT NULL,
          lifespan_hours REAL NOT NULL,
          died_at        TEXT,
          length         REAL NOT NULL,
          adult_length   REAL NOT NULL,
          depth          REAL NOT NULL,
          fullness       REAL NOT NULL,
          love           INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS events (
          id       INTEGER PRIMARY KEY,
          at       TEXT NOT NULL DEFAULT (datetime('now', 'localtime')),
          kind     TEXT NOT NULL,          -- opened, arrived, born, fed, loved, died, returned
          shark_id INTEGER REFERENCES sharks(id),
          text     TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_shark ON events(shark_id);
        CREATE INDEX IF NOT EXISTS sharks_parents ON sharks(parent_a_id, parent_b_id);
        DROP VIEW IF EXISTS babies;
        CREATE VIEW babies AS
          SELECT s.id, s.name, s.species, f.name AS family, s.generation,
                 a.name AS parent_a, b.name AS parent_b, s.born_at, s.died_at,
                 round(s.length / s.adult_length, 2) AS grown, s.love
          FROM sharks s
          JOIN families f ON f.id = s.family_id
          LEFT JOIN sharks a ON a.id = s.parent_a_id
          LEFT JOIN sharks b ON b.id = s.parent_b_id
          WHERE s.parent_a_id IS NOT NULL;
        DROP VIEW IF EXISTS alive;
        CREATE VIEW alive AS SELECT * FROM sharks WHERE died_at IS NULL;
        """)
    }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK { log("sql error: \(String(cString: err!))") }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?]) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { log("prepare: \(String(cString: sqlite3_errmsg(db)))"); return false }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let k = Int32(i + 1)
            switch a {
            case let v as Int: sqlite3_bind_int64(st, k, Int64(v))
            case let v as Double: sqlite3_bind_double(st, k, v)
            case let v as String: sqlite3_bind_text(st, k, v, -1, SQLITE_TRANSIENT)
            case let v as NSNumber: sqlite3_bind_double(st, k, v.doubleValue)
            default: sqlite3_bind_null(st, k)
            }
        }
        let rc = sqlite3_step(st)
        if rc != SQLITE_DONE && rc != SQLITE_ROW { log("step: \(String(cString: sqlite3_errmsg(db)))"); return false }
        return true
    }

    func rows(_ sql: String) -> [[String: Any]] {
        var st: OpaquePointer?, out: [[String: Any]] = []
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, i))
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: r[name] = Int(sqlite3_column_int64(st, i))
                case SQLITE_FLOAT: r[name] = sqlite3_column_double(st, i)
                case SQLITE_TEXT: r[name] = String(cString: sqlite3_column_text(st, i))
                default: r[name] = NSNull()
                }
            }
            out.append(r)
        }
        return out
    }

    /// The page's view of the tank: families, living sharks, recent log lines.
    func snapshotJSON() -> String? {
        let sharks = rows("SELECT * FROM sharks WHERE died_at IS NULL ORDER BY id")
        if sharks.isEmpty { return nil }
        let fams = rows("SELECT id, name, hue FROM families ORDER BY id")
        let log = rows("SELECT strftime('%H:%M', at) AS t, text FROM (SELECT * FROM events ORDER BY id DESC LIMIT 120) ORDER BY id")
            .map { "\($0["t"] as? String ?? "")  \($0["text"] as? String ?? "")" }
        let s = sharks.map { r -> [String: Any] in [
            "id": r["id"]!, "name": r["name"]!, "kind": (r["species"] as? String) == "hammerhead" ? "hammer" : "leopard",
            "family": r["family_id"]!, "gen": r["generation"]!,
            "parents": [r["parent_a_id"], r["parent_b_id"]].compactMap { $0 as? Int },
            "born": r["born_ms"]!, "lifespan": ((r["lifespan_hours"] as? Double) ?? 8) * 3_600_000,
            "len": r["length"]!, "adultLen": r["adult_length"]!, "depth": r["depth"]!, "full": r["fullness"]!, "love": r["love"]!] }
        let next = (rows("SELECT max(id) + 1 AS n FROM sharks").first?["n"] as? Int) ?? 1
        let names = rows("SELECT name FROM sharks").compactMap { $0["name"] as? String }
        let obj: [String: Any] = ["families": fams, "sharks": s, "log": log, "nextId": next, "names": names]
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? String, let data = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if m.name == "save" {
            exec("BEGIN")
            for f in o["families"] as? [[String: Any]] ?? [] {
                run("INSERT INTO families (id, name, hue) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, hue = excluded.hue",
                    [f["id"], f["name"], f["hue"]])
            }
            for s in (o["sharks"] as? [[String: Any]] ?? []).sorted(by: { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }) {
                let parents = s["parents"] as? [Int] ?? []
                run("""
                INSERT INTO sharks (id, name, species, family_id, generation, parent_a_id, parent_b_id, born_at, born_ms,
                                    lifespan_hours, died_at, length, adult_length, depth, fullness, love)
                VALUES (?, ?, ?, ?, ?, ?, ?, datetime(? / 1000, 'unixepoch', 'localtime'), ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET length = excluded.length, fullness = excluded.fullness, love = excluded.love,
                  died_at = coalesce(sharks.died_at, excluded.died_at)
                """, [s["id"], s["name"], (s["kind"] as? String) == "hammer" ? "hammerhead" : "leopard", s["family"], s["gen"],
                      parents.count > 0 ? parents[0] : nil, parents.count > 1 ? parents[1] : nil, s["born"], s["born"],
                      ((s["lifespan"] as? Double) ?? 0) / 3_600_000, s["diedAt"], s["len"], s["adultLen"], s["depth"], s["full"], s["love"]])
            }
            exec("COMMIT")
        } else if m.name == "event" {
            let sid = o["shark"] as? Int
            if !run("INSERT INTO events (kind, shark_id, text) VALUES (?, ?, ?)", [o["kind"], sid, o["text"]]) {
                run("INSERT INTO events (kind, shark_id, text) VALUES (?, NULL, ?)", [o["kind"], o["text"]])   // shark not saved yet
            }
        }
    }
}

final class Host: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let store = TankDB(path: dbPath)
    var windows: [(NSWindow, WKWebView)] = []
    var lastMouse = NSPoint(x: -1, y: -1)
    let page: URL
    let query: String
    let snapDir: String?
    let snapTimes: [Double]

    init(page: URL, query: String, snapDir: String?, snapTimes: [Double]) {
        self.page = page.absoluteURL; self.query = query; self.snapDir = snapDir; self.snapTimes = snapTimes
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        log("launched, page=\(page.path)")
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(build),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // The window ignores clicks, so feed the cursor position to the page ourselves.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pollMouse() }
        // Clicks: feeding time. Global mouse-down monitors need no extra permission.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.sendClick(NSEvent.mouseLocation) }
        if let dir = snapDir { scheduleSnapshots(dir) }
        for (t, js) in evals {   // test hook: --eval "seconds:javascript"
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.windows.forEach { $0.1.evaluateJavaScript(js, completionHandler: nil) } }
        }
    }

    func sendClick(_ p: NSPoint) {
        for (w, v) in windows where w.frame.contains(p) {
            v.evaluateJavaScript("window.__click && window.__click(\(p.x - w.frame.minX), \(w.frame.maxY - p.y))", completionHandler: nil)
        }
    }

    @objc func build() {
        for (w, _) in windows { w.orderOut(nil) }
        windows.removeAll()
        let screens = snapDir == nil ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        for screen in screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            let cfg = WKWebViewConfiguration()
            cfg.suppressesIncrementalRendering = true
            // Only the main screen keeps the persistent tank; other screens get their own fresh one.
            if screen == screens.first && (snapDir == nil || dbFlag != nil) {
                cfg.userContentController.add(store, name: "save")
                cfg.userContentController.add(store, name: "event")
                if let saved = store.snapshotJSON() {
                    cfg.userContentController.addUserScript(WKUserScript(source: "window.__saved = \(saved);",
                        injectionTime: .atDocumentStart, forMainFrameOnly: true))
                }
            }
            let v = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: cfg)
            v.autoresizingMask = [.width, .height]
            v.navigationDelegate = self
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            var comps = URLComponents(url: page, resolvingAgainstBaseURL: false)!
            comps.query = query.isEmpty ? nil : query
            v.loadFileURL(comps.url!, allowingReadAccessTo: page.deletingLastPathComponent())
            w.orderBack(nil)
            windows.append((w, v))
        }
    }

    func pollMouse() {
        let p = NSEvent.mouseLocation
        if p == lastMouse { return }
        lastMouse = p
        for (w, v) in windows {
            let f = w.frame
            let inside = f.contains(p)
            let x = inside ? p.x - f.minX : -10000, y = inside ? f.maxY - p.y : -10000
            v.evaluateJavaScript("window.__mouse && window.__mouse(\(x), \(y))", completionHandler: nil)
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { log("page loaded") }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { log("fail \(e)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { log("fail \(e)") }

    func scheduleSnapshots(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for t in snapTimes {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let v = self?.windows.first?.1 else { return }
                log("snapshot \(t)")
                v.evaluateJavaScript("JSON.stringify([window.__errs, window.__frames && window.__frames()])") { r, _ in log("errs \(r ?? "nil")") }
                v.takeSnapshot(with: nil) { img, err in
                    if let err = err { log("snap error \(err)") }
                    guard let img = img, let tiff = img.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/snap_\(String(format: "%05.1f", t)).png"))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (snapTimes.max() ?? 0) + 1.5) { NSApp.terminate(nil) }
    }
}

// ---- arguments ----
var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
// Default page: <bundle>/Contents/Resources/web/index.html, else ../web/index.html next to the binary.
let bundled = Bundle.main.resourceURL?.appendingPathComponent("web/index.html")
let fallback = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web/index.html")
let pagePath = take("--page").map { URL(fileURLWithPath: $0).standardizedFileURL.absoluteURL }
    ?? (bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? fallback)
let query = take("--query") ?? ""
let dbFlag = take("--db")   // tests point this at a scratch database
let dbPath = dbFlag ?? support.appendingPathComponent("tank.sqlite").path
let snapDir = take("--snapshot")
var evals: [(Double, String)] = []
while let e = take("--eval"), let i = e.firstIndex(of: ":") { evals.append((Double(e[..<i]) ?? 0, String(e[e.index(after: i)...]))) }
let times = (take("--at") ?? "3").split(separator: ",").compactMap { Double($0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = Host(page: pagePath, query: query, snapDir: snapDir, snapTimes: times)
app.delegate = host
app.run()
