// Living Wallpaper: Windows host (WinForms + WebView2 + SQLite).
// Puts web/index.html behind the desktop icons on every monitor and implements the host contract in
// docs/HOST_PROTOCOL.md: inject __tank/__quote, run the page's SQL, forward the mouse, watch quote.txt.
//
// Usage: LivingWallpaper.exe [--page PATH] [--db PATH] [--query fps=12] [--quote TEXT] [--quote-file PATH]
//                            [--windowed] [--no-layered] [--snapshot DIR --at 2,6] [--eval SEC:JS] [--log PATH]
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace LivingWallpaper;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        var o = Options.Parse(args);
        Log.Path = o.LogFile;
        using var single = new Mutex(true, o.Snapshot == null && !o.Windowed ? "LivingWallpaper.Desktop" : Guid.NewGuid().ToString(), out bool first);
        if (!first) { Log.Write("already running"); return; }
        if (o.RestoreLock) { LockScreenImage.Restore().GetAwaiter().GetResult(); return; }   // used by uninstall
        ApplicationConfiguration.Initialize();
        var host = new Host(o);
        Application.ApplicationExit += (_, _) => host.Shutdown();
        Application.Run(host.Context);
    }
}

static class Log
{
    public static string Path;
    public static void Write(string s)
    {
        var line = $"{DateTime.Now:HH:mm:ss} {s}";
        try { Console.Error.WriteLine(line); } catch { }
        if (Path != null) try { File.AppendAllText(Path, line + Environment.NewLine); } catch { }
    }
}

class Options
{
    public string Page, Db, Query = "", Quote, QuoteFile, Snapshot, LogFile;
    public double[] At = { 3 };
    public List<(double, string)> Evals = new();
    public bool Windowed, Layered = true, Lockscreen = true, RestoreLock;
    public static readonly string Data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LivingWallpaper");

    public static Options Parse(string[] a)
    {
        var o = new Options
        {
            Db = Path.Combine(Data, "tank.sqlite"),
            QuoteFile = Path.Combine(Data, "quote.txt"),
            LogFile = Path.Combine(Data, "log.txt"),
        };
        for (int i = 0; i < a.Length; i++)
        {
            string Next() => i + 1 < a.Length ? a[++i] : "";
            switch (a[i])
            {
                case "--page": o.Page = Path.GetFullPath(Next()); break;
                case "--db": o.Db = Path.GetFullPath(Next()); break;
                case "--query": o.Query = Next(); break;
                case "--quote": o.Quote = Next(); break;
                case "--quote-file": o.QuoteFile = Path.GetFullPath(Next()); break;
                case "--snapshot": o.Snapshot = Path.GetFullPath(Next()); break;
                case "--at": o.At = Next().Split(',').Select(x => double.Parse(x, CultureInfo.InvariantCulture)).ToArray(); break;
                case "--eval": var e = Next(); var c = e.IndexOf(':'); o.Evals.Add((double.Parse(e[..c], CultureInfo.InvariantCulture), e[(c + 1)..])); break;
                case "--log": o.LogFile = Path.GetFullPath(Next()); break;
                case "--windowed": o.Windowed = true; break;
                case "--no-layered": o.Layered = false; break;
                case "--no-lockscreen": o.Lockscreen = false; break;
                case "--restore-lockscreen": o.RestoreLock = true; break;
            }
        }
        // Default page: the nearest web\index.html above the exe (the repo), so edits to web\ need no rebuild.
        if (o.Page == null)
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            for (int up = 0; dir != null && up < 8; up++, dir = dir.Parent)
            {
                var p = Path.Combine(dir.FullName, "web", "index.html");
                if (File.Exists(p)) { o.Page = p; break; }
            }
        }
        if (o.Page == null) throw new FileNotFoundException("web\\index.html not found; pass --page");
        return o;
    }
}

// ---------- the tank: SQLite; all SQL comes from the page ----------
class Tank
{
    readonly SqliteConnection db;

    public Tank(string path, string schema)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        db = new SqliteConnection($"Data Source={path}");
        db.Open();
        using var c = db.CreateCommand();
        c.CommandText = schema;
        c.ExecuteNonQuery();
    }

    // Microsoft.Data.Sqlite binds by name, so turn each ? (outside string literals) into $p1, $p2, ...
    static string Number(string sql, out int count)
    {
        var sb = new StringBuilder(); count = 0; char quote = '\0';
        foreach (var ch in sql)
        {
            if (quote != '\0') { if (ch == quote) quote = '\0'; sb.Append(ch); }
            else if (ch == '\'' || ch == '"') { quote = ch; sb.Append(ch); }
            else if (ch == '?') sb.Append("$p").Append(++count);
            else sb.Append(ch);
        }
        return sb.ToString();
    }

    static object Value(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.Number => v.TryGetInt64(out var l) ? l : v.GetDouble(),
        JsonValueKind.String => v.GetString(),
        JsonValueKind.True => 1L,
        JsonValueKind.False => 0L,
        _ => DBNull.Value,
    };

    /// {"tx": [[sql, [params]], ...]} in one transaction; rolled back if any statement fails.
    public void Run(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("tx", out var tx)) return;
            using var t = db.BeginTransaction();
            try
            {
                foreach (var item in tx.EnumerateArray())
                {
                    using var c = db.CreateCommand();
                    c.Transaction = t;
                    c.CommandText = Number(item[0].GetString(), out _);
                    if (item.GetArrayLength() > 1)
                    {
                        int k = 0;
                        foreach (var p in item[1].EnumerateArray()) c.Parameters.AddWithValue("$p" + (++k), Value(p));
                    }
                    c.ExecuteNonQuery();
                }
                t.Commit();
            }
            catch (Exception e) { t.Rollback(); Log.Write("sql: " + e.Message); }
        }
        catch (Exception e) { Log.Write("bad message: " + e.Message); }
    }

    /// Runs each query in web\load.json; returns {key: rows} as JSON.
    public string Load(Dictionary<string, string> queries)
    {
        var obj = new Dictionary<string, List<Dictionary<string, object>>>();
        foreach (var (key, sql) in queries)
        {
            var rows = new List<Dictionary<string, object>>();
            using var c = db.CreateCommand();
            c.CommandText = sql;
            using var r = c.ExecuteReader();
            while (r.Read())
            {
                var row = new Dictionary<string, object>();
                for (int i = 0; i < r.FieldCount; i++) row[r.GetName(i)] = r.IsDBNull(i) ? null : r.GetValue(i);
                rows.Add(row);
            }
            obj[key] = rows;
        }
        return JsonSerializer.Serialize(obj);
    }
}

// ---------- putting a window behind the desktop icons ----------
static class Desktop
{
    // Explorer's undocumented message 0x052C asks Progman to create a WorkerW layer between the wallpaper
    // and the icons. Windows 11 24H2 changed where that WorkerW lives:
    //   before 24H2: a separate top-level WorkerW, right after the window that hosts SHELLDLL_DefView (the icons);
    //   24H2 and later: a child of Progman; the icons (SHELLDLL_DefView) are also a child of Progman.
    // On 24H2 we parent ourselves to Progman directly below the icons, as a layered child (alpha 255).
    public static string Attach(IntPtr h, Rectangle screenBounds, bool layered)
    {
        IntPtr progman = W.FindWindow("Progman", null);
        if (progman == IntPtr.Zero) return "no Progman (is Explorer running?)";
        W.SendMessageTimeout(progman, 0x052C, new IntPtr(0xD), new IntPtr(1), W.SMTO_NORMAL, 1000, out _);

        var vs = SystemInformation.VirtualScreen;   // parents span the whole virtual screen
        int x = screenBounds.X - vs.X, y = screenBounds.Y - vs.Y;

        IntPtr defView = W.FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        IntPtr childWorker = W.FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
        if (defView != IntPtr.Zero && childWorker != IntPtr.Zero)
        {
            MakeChild(h, progman, layered);
            W.SetWindowPos(h, defView, x, y, screenBounds.Width, screenBounds.Height, W.SWP_NOACTIVATE | W.SWP_SHOWWINDOW);
            return "Progman child below SHELLDLL_DefView (Windows 11 24H2+ layout)";
        }

        IntPtr worker = IntPtr.Zero;
        W.EnumWindows((top, _) =>
        {
            if (W.FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
                worker = W.FindWindowEx(IntPtr.Zero, top, "WorkerW", null);
            return true;
        }, IntPtr.Zero);
        if (worker != IntPtr.Zero)
        {
            MakeChild(h, worker, false);
            W.SetWindowPos(h, IntPtr.Zero, x, y, screenBounds.Width, screenBounds.Height, W.SWP_NOACTIVATE | W.SWP_NOZORDER | W.SWP_SHOWWINDOW);
            return "child of the WorkerW behind the icons (classic layout)";
        }

        MakeChild(h, progman, false);
        W.SetWindowPos(h, W.HWND_BOTTOM, x, y, screenBounds.Width, screenBounds.Height, W.SWP_NOACTIVATE | W.SWP_SHOWWINDOW);
        return "fallback: bottom child of Progman";
    }

    static void MakeChild(IntPtr h, IntPtr parent, bool layered)
    {
        long style = W.GetWindowLongPtr(h, W.GWL_STYLE).ToInt64();
        style = (style & ~(W.WS_POPUP | W.WS_CAPTION | W.WS_THICKFRAME)) | W.WS_CHILD;
        W.SetWindowLongPtr(h, W.GWL_STYLE, new IntPtr(style));
        if (layered)
        {
            long ex = W.GetWindowLongPtr(h, W.GWL_EXSTYLE).ToInt64() | W.WS_EX_LAYERED;
            W.SetWindowLongPtr(h, W.GWL_EXSTYLE, new IntPtr(ex));
            W.SetLayeredWindowAttributes(h, 0, 255, W.LWA_ALPHA);
        }
        W.SetParent(h, parent);
    }

    /// Asks Explorer to repaint the normal wallpaper (used when we quit).
    public static void Repaint()
    {
        var sb = new StringBuilder(520);
        W.SystemParametersInfo(W.SPI_GETDESKWALLPAPER, (uint)sb.Capacity, sb, 0);
        W.SystemParametersInfo(W.SPI_SETDESKWALLPAPER, 0, sb, 0);
    }

    /// True if the point is over the desktop (icons or wallpaper), not over an app window.
    public static bool IsDesktopAt(W.POINT pt)
    {
        IntPtr root = W.GetAncestor(W.WindowFromPoint(pt), W.GA_ROOT);
        var cls = new StringBuilder(64);
        W.GetClassName(root, cls, cls.Capacity);
        var c = cls.ToString();
        return c == "Progman" || c == "WorkerW";
    }
}

// ---------- the host ----------
class Host
{
    public readonly ApplicationContext Context = new();
    readonly Options o;
    readonly Tank tank;
    readonly Dictionary<string, string> queries;
    readonly List<(Form form, WebView2 view, Screen screen)> wins = new();
    readonly string web;
    DateTime quoteStamp;
    IntPtr hook;
    W.LowLevelMouseProc hookProc;   // keep a reference so the GC does not collect the callback
    W.POINT? pendingMove;
    const string DefaultQuote = "Evil is whatever distracts.";

    public Host(Options opts)
    {
        o = opts;
        web = Path.GetDirectoryName(o.Page);
        tank = new Tank(o.Db, File.ReadAllText(Path.Combine(web, "schema.sql")));
        queries = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(web, "load.json")));
        if (o.Quote == null && !File.Exists(o.QuoteFile))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(o.QuoteFile));
            File.WriteAllText(o.QuoteFile, DefaultQuote + Environment.NewLine);
        }
        quoteStamp = File.Exists(o.QuoteFile) ? File.GetLastWriteTimeUtc(o.QuoteFile) : default;
        Log.Write($"page={o.Page} db={o.Db} quote={o.QuoteFile}");

        var screens = (o.Windowed || o.Snapshot != null) ? new[] { Screen.PrimaryScreen } : Screen.AllScreens.OrderByDescending(s => s.Primary).ToArray();
        for (int i = 0; i < screens.Length; i++) _ = Open(screens[i], i == 0);

        Every(2000, WatchQuote);
        // Sleep and wake: save before suspend; reload after resume (the GPU or web process may have been reset).
        Microsoft.Win32.SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == Microsoft.Win32.PowerModes.Suspend && o.Lockscreen && !o.Windowed) _ = UpdateLockScreen();
            if (e.Mode == Microsoft.Win32.PowerModes.Suspend)
                foreach (var w in wins) if (w.view.CoreWebView2 != null) _ = w.view.ExecuteScriptAsync("window.__save && window.__save()");
            if (e.Mode == Microsoft.Win32.PowerModes.Resume)
                After(2, () => { Log.Write("resumed: reloading"); foreach (var w in wins) w.view.CoreWebView2?.Reload(); });
        };
        if (!o.Windowed)
        {
            hookProc = OnMouse;
            hook = W.SetWindowsHookEx(W.WH_MOUSE_LL, hookProc, W.GetModuleHandle(null), 0);
            Every(33, FlushMove);
        }
        foreach (var (sec, js) in o.Evals) After(sec, () => wins.ForEach(w => _ = w.view.ExecuteScriptAsync(js)));
        if (o.Snapshot != null) ScheduleSnapshots();
        // Lock screen: Windows cannot run a live page there, so keep its picture set to the page's words-only picture.
        if (o.Lockscreen && !o.Windowed && o.Snapshot == null)
        {
            After(10, () => _ = UpdateLockScreen());
            Every(300_000, () => _ = UpdateLockScreen());
            Microsoft.Win32.SystemEvents.SessionSwitch += (_, e) => { if (e.Reason == Microsoft.Win32.SessionSwitchReason.SessionLock) _ = UpdateLockScreen(); };
        }
    }

    bool lockFlip;
    async Task UpdateLockScreen()
    {
        var v = wins.Count > 0 ? wins[0].view : null;
        if (v?.CoreWebView2 == null) return;
        lockFlip = !lockFlip;   // alternate names: the lock screen caches by path
        var path = Path.Combine(Options.Data, lockFlip ? "lockscreen-a.png" : "lockscreen-b.png");
        try
        {
            // ExecuteScriptAsync returns JSON, so the data URL arrives as a quoted string.
            var json = await v.ExecuteScriptAsync("window.__quoteImage && window.__quoteImage()");
            var dataUrl = JsonSerializer.Deserialize<string>(json);
            if (string.IsNullOrEmpty(dataUrl)) return;
            File.WriteAllBytes(path, Convert.FromBase64String(dataUrl[(dataUrl.IndexOf(',') + 1)..]));
            await LockScreenImage.Set(path);
        }
        catch (Exception e) { Log.Write("lock screen update failed: " + e.Message); }
    }

    async Task Open(Screen screen, bool persist)
    {
        var f = new Form
        {
            Text = "Living Wallpaper", BackColor = Color.Black, StartPosition = FormStartPosition.Manual,
            FormBorderStyle = o.Windowed ? FormBorderStyle.Sizable : FormBorderStyle.None, ShowInTaskbar = o.Windowed,
            Bounds = o.Windowed ? new Rectangle(screen.WorkingArea.X + 80, screen.WorkingArea.Y + 80, 1280, 800) : screen.Bounds,
        };
        var view = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.Black };
        f.Controls.Add(view);
        f.FormClosed += (_, _) => { if (wins.All(w => w.form.IsDisposed)) Application.Exit(); };
        f.Show();
        if (!o.Windowed) Log.Write($"screen {screen.DeviceName}: " + Desktop.Attach(f.Handle, screen.Bounds, o.Layered));
        wins.Add((f, view, screen));

        var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Options.Data, "WebView2"));
        await view.EnsureCoreWebView2Async(env);
        var cw = view.CoreWebView2;
        cw.Settings.AreDefaultContextMenusEnabled = false;
        cw.Settings.IsZoomControlEnabled = false;
        cw.Settings.IsStatusBarEnabled = false;
        // Serve web\ from a virtual https origin, so the canvas is never "tainted" and file access stays scoped.
        cw.SetVirtualHostNameToFolderMapping("tank.local", web, CoreWebView2HostResourceAccessKind.Allow);
        var boot = $"window.__host = 'windows'; window.__quote = {JsonSerializer.Serialize(CurrentQuote())};";
        if (persist)
        {
            boot += $"window.__tank = {tank.Load(queries)};";
            cw.WebMessageReceived += (_, e) => { try { tank.Run(e.TryGetWebMessageAsString()); } catch (Exception x) { Log.Write("message: " + x.Message); } };
        }
        await cw.AddScriptToExecuteOnDocumentCreatedAsync(boot);
        cw.NavigationCompleted += (_, e) => Log.Write($"page loaded: {e.IsSuccess}");
        cw.ProcessFailed += (_, e) => { Log.Write($"web process failed ({e.ProcessFailedKind}): reloading"); try { cw.Reload(); } catch { } };
        cw.Navigate("https://tank.local/" + Path.GetFileName(o.Page) + (o.Query.Length > 0 ? "?" + o.Query : ""));
    }

    string CurrentQuote()
    {
        if (o.Quote != null) return o.Quote;
        try { var t = File.ReadAllText(o.QuoteFile).Trim(); return t.Length > 0 ? t : DefaultQuote; } catch { return DefaultQuote; }
    }

    void WatchQuote()
    {
        if (o.Quote != null || !File.Exists(o.QuoteFile)) return;
        var stamp = File.GetLastWriteTimeUtc(o.QuoteFile);
        if (stamp == quoteStamp) return;
        quoteStamp = stamp;
        var js = $"window.__setQuote && window.__setQuote({JsonSerializer.Serialize(CurrentQuote())})";
        foreach (var w in wins) if (w.view.CoreWebView2 != null) _ = w.view.ExecuteScriptAsync(js);
    }

    // ---- mouse: the window is behind the icons and gets no input, so a low-level hook forwards it ----
    IntPtr OnMouse(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            int msg = wParam.ToInt32();
            var info = Marshal.PtrToStructure<W.MSLLHOOKSTRUCT>(lParam);
            if (msg == W.WM_MOUSEMOVE) pendingMove = info.pt;
            else if (msg == W.WM_LBUTTONDOWN && Desktop.IsDesktopAt(info.pt)) Send("__click", info.pt);
        }
        return W.CallNextHookEx(hook, code, wParam, lParam);
    }

    void FlushMove()
    {
        if (pendingMove is not W.POINT pt) return;
        pendingMove = null;
        if (Desktop.IsDesktopAt(pt)) Send("__mouse", pt);
    }

    void Send(string fn, W.POINT pt)
    {
        foreach (var (form, view, screen) in wins)
        {
            if (!screen.Bounds.Contains(pt.X, pt.Y) || view.CoreWebView2 == null) continue;
            double scale = form.DeviceDpi / 96.0;   // physical pixels -> CSS pixels
            double x = (pt.X - screen.Bounds.X) / scale, y = (pt.Y - screen.Bounds.Y) / scale;
            var inv = CultureInfo.InvariantCulture;   // never "12,5": that is not a JS number
            _ = view.ExecuteScriptAsync($"window.{fn} && window.{fn}({x.ToString("0.#", inv)}, {y.ToString("0.#", inv)})");
        }
    }

    // ---- test mode ----
    void ScheduleSnapshots()
    {
        Directory.CreateDirectory(o.Snapshot);
        foreach (var t in o.At) After(t, async () =>
        {
            var v = wins[0].view;
            if (v.CoreWebView2 == null) { Log.Write($"snapshot {t}: webview not ready"); return; }
            var r = await v.ExecuteScriptAsync("JSON.stringify([window.__errs, window.__frames && window.__frames()])");
            Log.Write($"snapshot {t}: errors+frames {r}");
            using var fs = File.Create(Path.Combine(o.Snapshot, "snap_" + t.ToString("000.0", CultureInfo.InvariantCulture) + ".png"));
            await v.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs);
        });
        After(o.At.Max() + 2, Application.Exit);
    }

    static void Every(int ms, Action a) { var t = new System.Windows.Forms.Timer { Interval = ms }; t.Tick += (_, _) => a(); t.Start(); }
    static void After(double sec, Action a)
    {
        var t = new System.Windows.Forms.Timer { Interval = Math.Max(1, (int)(sec * 1000)) };
        t.Tick += (_, _) => { t.Stop(); t.Dispose(); a(); };
        t.Start();
    }

    public void Shutdown()
    {
        if (hook != IntPtr.Zero) W.UnhookWindowsHookEx(hook);
        if (!o.Windowed) Desktop.Repaint();
    }
}

// ---------- lock screen picture (WinRT); the first time, the current picture is saved so uninstall can restore it ----------
static class LockScreenImage
{
    static readonly string Original = Path.Combine(Options.Data, "original-lockscreen.img");

    public static async Task Set(string png)
    {
        if (!File.Exists(Original))
        {
            try
            {
                using var src = Windows.System.UserProfile.LockScreen.GetImageStream().AsStreamForRead();
                using var dst = File.Create(Original);
                await src.CopyToAsync(dst);
            }
            catch (Exception e) { Log.Write("could not save the current lock screen: " + e.Message); }
        }
        var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(png);
        await Windows.System.UserProfile.LockScreen.SetImageFileAsync(file);
    }

    public static async Task Restore()
    {
        if (!File.Exists(Original)) return;
        var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(Original);
        await Windows.System.UserProfile.LockScreen.SetImageFileAsync(file);
        File.Delete(Original);
    }
}

// ---------- Win32 ----------
static class W
{
    public const int GWL_STYLE = -16, GWL_EXSTYLE = -20, GA_ROOT = 2, WH_MOUSE_LL = 14;
    public const int WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201;
    public const long WS_CHILD = 0x40000000L, WS_POPUP = 0x80000000L, WS_CAPTION = 0x00C00000L, WS_THICKFRAME = 0x00040000L, WS_EX_LAYERED = 0x00080000L;
    public const uint SWP_NOACTIVATE = 0x0010, SWP_NOZORDER = 0x0004, SWP_SHOWWINDOW = 0x0040, SMTO_NORMAL = 0, LWA_ALPHA = 2;
    public const uint SPI_GETDESKWALLPAPER = 0x0073, SPI_SETDESKWALLPAPER = 0x0014;
    public static readonly IntPtr HWND_BOTTOM = new(1);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr dwExtraInfo; }
    public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int index, IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SystemParametersInfo(uint action, uint param, StringBuilder v, uint winIni);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int id, LowLevelMouseProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string name);
}
