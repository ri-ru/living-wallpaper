// Living Wallpaper: macOS host.
// Shows web/index.html behind the desktop icons on every screen and Space, and implements the host
// contract in docs/HOST_PROTOCOL.md: inject __tank/__quote, run the page's SQL, forward the mouse,
// watch quote.txt.
//
// Usage: LivingWallpaper [--page PATH] [--db PATH] [--query "fps=12"] [--quote "text"]
//                        [--snapshot DIR --at 2,6] [--eval "sec:js"] [--windowed]
import Cocoa
import WebKit
import SQLite3

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// ---------- the tank: a SQLite file; all SQL comes from the page (web/schema.sql, web/load.json, messages) ----------
final class Tank: NSObject, WKScriptMessageHandler {
    var db: OpaquePointer?

    init(path: String, schema: String) {
        super.init()
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if sqlite3_open(path, &db) != SQLITE_OK { log("db open failed: \(path)") }
        exec(schema)
    }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK { log("sql: \(String(cString: err!))") }
    }

    func bind(_ st: OpaquePointer?, _ params: [Any]) {
        for (i, a) in params.enumerated() {
            let k = Int32(i + 1)
            switch a {
            case let v as NSNumber where CFGetTypeID(v) == CFBooleanGetTypeID(): sqlite3_bind_int64(st, k, v.boolValue ? 1 : 0)
            case let v as NSNumber where !CFNumberIsFloatType(v): sqlite3_bind_int64(st, k, v.int64Value)
            case let v as NSNumber: sqlite3_bind_double(st, k, v.doubleValue)
            case let v as String: sqlite3_bind_text(st, k, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(st, k)
            }
        }
    }

    /// Runs [[sql, params], ...] in one transaction; rolls back if any statement fails.
    func transaction(_ tx: [[Any]]) {
        exec("BEGIN")
        for item in tx {
            guard let sql = item.first as? String else { continue }
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                log("prepare: \(String(cString: sqlite3_errmsg(db)))"); exec("ROLLBACK"); return
            }
            bind(st, item.count > 1 ? (item[1] as? [Any] ?? []) : [])
            let rc = sqlite3_step(st); sqlite3_finalize(st)
            if rc != SQLITE_DONE && rc != SQLITE_ROW { log("step: \(String(cString: sqlite3_errmsg(db)))"); exec("ROLLBACK"); return }
        }
        exec("COMMIT")
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

    /// Runs each query in web/load.json and returns {key: rows} as JSON.
    func load(_ queries: [String: String]) -> String {
        var obj: [String: Any] = [:]
        for (k, q) in queries { obj[k] = rows(q) }
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? String, let data = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tx = o["tx"] as? [[Any]] else { return }
        transaction(tx)
    }
}

// ---------- paths ----------
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LivingWallpaper")
let defaultQuote = "Evil is whatever distracts."

func jsString(_ s: String) -> String {
    let d = try! JSONSerialization.data(withJSONObject: [s]); let a = String(data: d, encoding: .utf8)!
    return String(a.dropFirst().dropLast())   // a JSON string literal is a valid JS string literal
}

// ---------- the host ----------
final class Host: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var windows: [(NSWindow, WKWebView)] = []
    var lastMouse = NSPoint(x: -1, y: -1)
    var tank: Tank!
    var quoteStamp: Date?
    let opts: Options

    init(_ o: Options) { opts = o }

    func applicationDidFinishLaunching(_ note: Notification) {
        log("starting: page=\(opts.page.path)")
        let web = opts.page.deletingLastPathComponent()
        let schema = (try? String(contentsOf: web.appendingPathComponent("schema.sql"), encoding: .utf8)) ?? ""
        tank = Tank(path: opts.db, schema: schema)
        ensureQuoteFile()
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(build),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // The window ignores the mouse (so the desktop stays usable); forward the cursor and clicks ourselves.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pollMouse() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.sendClick(NSEvent.mouseLocation) }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.watchQuote() }
        // Sleep and wake: save before sleeping; after waking (or unlocking, or switching users back) the web
        // content process may have been suspended or killed, so rebuild the windows from the saved tank.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.windows.forEach { $0.1.evaluateJavaScript("window.__save && window.__save()", completionHandler: nil) } }
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                log("\(note.name.rawValue): rebuilding")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.build() } }
        }
        if let dir = opts.snapDir { scheduleSnapshots(dir) }
        for (t, js) in opts.evals {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.windows.forEach { $0.1.evaluateJavaScript(js, completionHandler: nil) } }
        }
        log("living wallpaper: page=\(opts.page.path) db=\(opts.db) quote=\(opts.quoteFile.path)")
    }

    // quote.txt: created with the default text on first run so people can find and edit it.
    func ensureQuoteFile() {
        if opts.quote == nil && !FileManager.default.fileExists(atPath: opts.quoteFile.path) {
            try? FileManager.default.createDirectory(at: opts.quoteFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (defaultQuote + "\n").write(to: opts.quoteFile, atomically: true, encoding: .utf8)
        }
    }
    func currentQuote() -> String {
        if let q = opts.quote { return q }
        let t = (try? String(contentsOf: opts.quoteFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? defaultQuote : t
    }
    func watchQuote() {
        guard opts.quote == nil else { return }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: opts.quoteFile.path))?[.modificationDate] as? Date
        if stamp == quoteStamp { return }
        let first = quoteStamp == nil; quoteStamp = stamp
        if first { return }
        let js = "window.__setQuote && window.__setQuote(\(jsString(currentQuote())))"
        windows.forEach { $0.1.evaluateJavaScript(js, completionHandler: nil) }
    }

    @objc func build() {
        for (w, _) in windows { w.orderOut(nil) }
        windows.removeAll()
        let web = opts.page.deletingLastPathComponent()
        let queries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: web.appendingPathComponent("load.json")))) as? [String: String] ?? [:]
        let screens = (opts.snapDir != nil || opts.windowed) ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let frame = opts.windowed ? NSRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 1280, height: 800) : screen.frame
            let w = NSWindow(contentRect: frame, styleMask: opts.windowed ? [.titled, .closable, .resizable] : .borderless,
                             backing: .buffered, defer: false)
            if !opts.windowed {
                w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
                w.ignoresMouseEvents = true
                w.hasShadow = false
            }
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            let cfg = WKWebViewConfiguration()
            cfg.suppressesIncrementalRendering = true
            var boot = "window.__host = 'macos'; window.__quote = \(jsString(currentQuote()));"
            if i == 0 {   // only the main screen keeps the persistent tank; other screens get their own fresh one
                cfg.userContentController.add(tank, name: "sql")
                boot += "window.__tank = \(tank.load(queries));"
            }
            cfg.userContentController.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let v = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
            v.autoresizingMask = [.width, .height]
            v.navigationDelegate = self
            w.contentView = v
            w.setFrame(frame, display: true)
            var comps = URLComponents(url: opts.page, resolvingAgainstBaseURL: false)!
            comps.query = opts.query.isEmpty ? nil : opts.query
            v.loadFileURL(comps.url!, allowingReadAccessTo: web)
            if opts.windowed { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
            windows.append((w, v))
        }
    }

    func pollMouse() {
        if opts.windowed { return }   // a normal window gets real mouse events
        let p = NSEvent.mouseLocation
        if p == lastMouse { return }
        lastMouse = p
        for (w, v) in windows {
            let f = w.frame, inside = f.contains(p)
            let x = inside ? p.x - f.minX : -10000, y = inside ? f.maxY - p.y : -10000
            v.evaluateJavaScript("window.__mouse && window.__mouse(\(x), \(y))", completionHandler: nil)
        }
    }
    func sendClick(_ p: NSPoint) {
        if opts.windowed { return }
        for (w, v) in windows where w.frame.contains(p) {
            v.evaluateJavaScript("window.__click && window.__click(\(p.x - w.frame.minX), \(w.frame.maxY - p.y))", completionHandler: nil)
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { log("page loaded") }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { log("web content process ended: reloading"); w.reload() }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { log("fail \(e)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { log("fail \(e)") }

    func scheduleSnapshots(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for t in opts.snapTimes {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let v = self?.windows.first?.1 else { return }
                v.evaluateJavaScript("JSON.stringify([window.__errs, window.__frames && window.__frames()])") { r, _ in log("snapshot \(t): errors+frames \(r ?? "nil")") }
                v.takeSnapshot(with: nil) { img, _ in
                    guard let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/snap_\(String(format: "%05.1f", t)).png"))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (opts.snapTimes.max() ?? 0) + 1.5) { NSApp.terminate(nil) }
    }
}

// ---------- options ----------
struct Options {
    var page: URL, db: String, query: String, quote: String?, quoteFile: URL
    var snapDir: String?, snapTimes: [Double], evals: [(Double, String)], windowed: Bool
}
var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func flag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }
let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
// Default page: <bundle>/Contents/Resources/web/index.html, else ../../web/index.html from the binary.
let bundled = Bundle.main.resourceURL?.appendingPathComponent("web/index.html")
let fallback = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web/index.html")
// Resolve symlinks: WKWebView's loadFileURL throws (and AppKit swallows it) if the page is reached through a link.
let page = (take("--page").map { URL(fileURLWithPath: $0) }
    ?? (bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? fallback))
    .standardizedFileURL.resolvingSymlinksInPath().absoluteURL
var evals: [(Double, String)] = []
while let e = take("--eval"), let i = e.firstIndex(of: ":") { evals.append((Double(e[..<i]) ?? 0, String(e[e.index(after: i)...]))) }
let opts = Options(page: page,
                   db: take("--db") ?? support.appendingPathComponent("tank.sqlite").path,
                   query: take("--query") ?? "",
                   quote: take("--quote"),
                   quoteFile: take("--quote-file").map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("quote.txt"),
                   snapDir: take("--snapshot"),
                   snapTimes: (take("--at") ?? "3").split(separator: ",").compactMap { Double($0) },
                   evals: evals, windowed: flag("--windowed"))

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = Host(opts)
app.delegate = host
app.run()
