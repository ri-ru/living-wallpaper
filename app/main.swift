// Living Wallpaper host: shows web/index.html behind the desktop icons on every screen and Space.
// Usage: LivingWallpaper [--query "theme=paper&cell=6"] [--snapshot DIR --at 2,6,15]
import Cocoa
import WebKit

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LivingWallpaper")
let stateFile = support.appendingPathComponent("tank.json")
let lineageFile = support.appendingPathComponent("lineage.log")

/// Receives tank state and lineage lines from the page and writes them to disk.
final class Store: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? String else { return }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if m.name == "save" {
            try? body.data(using: .utf8)?.write(to: stateFile, options: .atomic)
        } else if m.name == "log" {
            let line = (body + "\n").data(using: .utf8)!
            if let h = try? FileHandle(forWritingTo: lineageFile) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: lineageFile) }
        }
    }
}

final class Host: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let store = Store()
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
            if screen == screens.first && snapDir == nil {
                cfg.userContentController.add(store, name: "save")
                cfg.userContentController.add(store, name: "log")
                if let saved = try? String(contentsOf: stateFile, encoding: .utf8), !saved.isEmpty {
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
let snapDir = take("--snapshot")
var evals: [(Double, String)] = []
while let e = take("--eval"), let i = e.firstIndex(of: ":") { evals.append((Double(e[..<i]) ?? 0, String(e[e.index(after: i)...]))) }
let times = (take("--at") ?? "3").split(separator: ",").compactMap { Double($0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = Host(page: pagePath, query: query, snapDir: snapDir, snapTimes: times)
app.delegate = host
app.run()
