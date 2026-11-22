// PDF Studio for Windows: a native app window around the single-file web app (PDF-Studio.html).
// It is the Windows counterpart of macos/PDFStudio.swift. Microsoft WebView2 (the Edge engine built
// into Windows) runs the app unchanged. This file supplies what a browser or macOS would otherwise
// provide: document tabs, Explorer "Open with", native open/save dialogs, JavaScript dialogs,
// a print preview window for the edited PDF and an unsaved-changes guard.
// Build with windows/build.ps1. It is written for the C# 5 compiler that ships with Windows
// (.NET Framework 4.8), so no Visual Studio or SDK is needed.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace PdfStudio {

static class Program {
  public const string AppName = "PDF Studio";
  // The app is served from a private virtual host, so it runs in a secure context with a stable origin
  // (saved signatures and settings live in localStorage for that origin). Nothing is fetched from the network.
  public const string Host = "pdfstudio.example";
  public static readonly string AppUrl = "https://" + Host + "/PDF-Studio.html";
  public static readonly string AppDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app");
  public static readonly string HtmlPath = Path.Combine(AppDir, "PDF-Studio.html");
#if DEBUG
  const string Flavor = "-debug";
#else
  const string Flavor = "";
#endif
  public static readonly string DataDir = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PDF Studio" + (Flavor.Length > 0 ? " (Debug)" : ""));
  static readonly string InstanceId = "PDFStudio" + Flavor + "-" + WindowsIdentity.GetCurrent().User.Value + "-" + Process.GetCurrentProcess().SessionId;
  public static readonly string PipeName = InstanceId;
  public static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
  public static Icon AppIcon;

  [STAThread]
  static void Main(string[] args) {
    var files = new List<string>();
    foreach (var a in args) {
      try { var p = Path.GetFullPath(a); if (File.Exists(p)) files.Add(p); } catch (Exception) { }
    }
    bool first;
    using (var mutex = new Mutex(true, @"Local\" + InstanceId, out first)) {
      // Already running: hand the files to that copy, which opens them as tabs.
      if (!first && Forward(files)) return;

      Application.EnableVisualStyles();
      Application.SetCompatibleTextRenderingDefault(false);
      if (!File.Exists(HtmlPath)) {
        MessageBox.Show("PDF-Studio.html is missing from " + AppDir + ".\n\nReinstall PDF Studio.", AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
        return;
      }
      try { AppIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch (Exception) { }
      Application.ThreadException += (s, e) => Dialogs.Error(null, "Something went wrong.\n\n" + e.Exception.Message);
      var app = new App();
      app.Start(files, first);
      Application.Run(app);
      GC.KeepAlive(mutex);
    }
  }

  /// Sends file paths to the copy of PDF Studio that is already running. An empty list just brings it to the front.
  static bool Forward(List<string> files) {
    var data = Encoding.UTF8.GetBytes(string.Join("\n", files.ToArray()) + "\n");
    for (int attempt = 0; attempt < 10; attempt++) {
      try {
        using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out)) {
          pipe.Connect(500);
          Native.AllowSetForegroundWindow(-1); // let the running copy come to the front
          pipe.Write(data, 0, data.Length);
          pipe.Flush();
          pipe.WaitForPipeDrain();
          return true;
        }
      } catch (TimeoutException) {
      } catch (IOException) {
        Thread.Sleep(150);
      }
    }
    return false;
  }

  public static string Str(IDictionary<string, object> m, string key) {
    object v; return m != null && m.TryGetValue(key, out v) && v != null ? Convert.ToString(v) : null;
  }
  public static bool Bool(IDictionary<string, object> m, string key) {
    object v; return m != null && m.TryGetValue(key, out v) && v is bool && (bool)v;
  }
  public static string JsonString(string s) { return Json.Serialize(s); }

  public static void OpenExternal(string uri) {
    Uri u;
    if (!Uri.TryCreate(uri, UriKind.Absolute, out u)) return;
    var scheme = u.Scheme.ToLowerInvariant();
    if (scheme != "http" && scheme != "https" && scheme != "mailto") return;
    try { Process.Start(new ProcessStartInfo(u.AbsoluteUri) { UseShellExecute = true }); } catch (Exception) { }
  }

  static readonly string[] MdExts = { ".md", ".markdown", ".mdown", ".mkd", ".mkdn", ".mdwn", ".mdtxt", ".mdtext", ".rmd" };
  static readonly Dictionary<string, string> ImageTypes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
    { ".png", "image/png" }, { ".jpg", "image/jpeg" }, { ".jpeg", "image/jpeg" }, { ".gif", "image/gif" },
    { ".webp", "image/webp" }, { ".svg", "image/svg+xml" }, { ".bmp", "image/bmp" }, { ".avif", "image/avif" },
  };
  public static bool IsPdf(string p) { return string.Equals(Path.GetExtension(p), ".pdf", StringComparison.OrdinalIgnoreCase); }
  public static bool IsMd(string p) { return MdExts.Contains(Path.GetExtension(p).ToLowerInvariant()); }
  public static bool IsImage(string p) { return ImageTypes.ContainsKey(Path.GetExtension(p)); }
  public static string MimeType(string p) {
    if (IsPdf(p)) return "application/pdf";
    if (IsMd(p)) return "text/markdown";
    string t; return ImageTypes.TryGetValue(Path.GetExtension(p), out t) ? t : "";
  }
  public const string OpenFilter =
    "PDF and Markdown files|*.pdf;*.md;*.markdown;*.mdown;*.mkd;*.mkdn;*.mdwn;*.mdtxt;*.mdtext;*.rmd" +
    "|PDF, Markdown and pictures for Markdown|*.pdf;*.md;*.markdown;*.mdown;*.mkd;*.mkdn;*.mdwn;*.mdtxt;*.mdtext;*.rmd;*.png;*.jpg;*.jpeg;*.gif;*.webp;*.svg" +
    "|All files|*.*";
}

static class Native {
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll")] static extern uint GetDpiForSystem();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public const int WM_DPICHANGED = 0x02E0;

  /// The scaling of the monitor a window is on (96 = 100%). Asked of Windows directly, because WinForms on
  /// .NET Framework reports 96 for windows of a per-monitor-aware process.
  public static int Dpi(Control c) {
    try {
      uint dpi = c != null && c.IsHandleCreated ? GetDpiForWindow(c.Handle) : GetDpiForSystem();
      return dpi >= 96 ? (int)dpi : 96;
    } catch (Exception) { return 96; }
  }
}

/// Colors from src/app.css, so the tab strip blends with the app's toolbar. Follows the Windows light/dark setting.
static class Theme {
  public static bool Dark { get; private set; }
  public static event EventHandler Changed;
  static Theme() {
    Refresh();
    SystemEvents.UserPreferenceChanged += (s, e) => {
      bool was = Dark; Refresh();
      if (was != Dark && Changed != null) Changed(null, EventArgs.Empty);
    };
  }
  static void Refresh() {
    try {
      using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) {
        var v = k == null ? null : k.GetValue("AppsUseLightTheme");
        Dark = v is int && (int)v == 0;
      }
    } catch (Exception) { Dark = false; }
  }
  static Color Hex(int v) { return Color.FromArgb(255, (v >> 16) & 255, (v >> 8) & 255, v & 255); }
  public static Color Bg { get { return Dark ? Hex(0x17191d) : Hex(0xf3f4f6); } }
  public static Color Panel { get { return Dark ? Hex(0x1f2227) : Hex(0xffffff); } }
  public static Color Border { get { return Dark ? Hex(0x33373e) : Hex(0xe3e5e9); } }
  public static Color Text { get { return Dark ? Hex(0xe7e9ec) : Hex(0x1f2328); } }
  public static Color Muted { get { return Dark ? Hex(0x9aa1ab) : Hex(0x6b7280); } }
  public static Color Hover { get { return Dark ? Hex(0x2c3037) : Hex(0xe9ebef); } }
  public static Color Accent { get { return Dark ? Hex(0xef5a43) : Hex(0xd6402b); } }
  public static void ApplyTitleBar(Form f) {
    int on = Dark ? 1 : 0;
    try { Native.DwmSetWindowAttribute(f.Handle, 20, ref on, 4); } catch (Exception) { } // DWMWA_USE_IMMERSIVE_DARK_MODE
  }
}

// MARK: - Application (one process, any number of windows)

sealed class App : ApplicationContext {
  public static App Current;
  readonly List<MainForm> forms = new List<MainForm>();
  MainForm front;
  Control invoker;
  public Task<CoreWebView2Environment> Environment { get; private set; }

  public void Start(List<string> files, bool listen) {
    Current = this;
    invoker = new Control();
    var unusedHandle = invoker.Handle; // creates the window used to run work on this thread
    var dataDir = Path.Combine(Program.DataDir, "WebView2");
    var options = new CoreWebView2EnvironmentOptions();
#if DEBUG
    // Automated checks (debug builds only): PDFSTUDIO_DEBUG_PORT=9333 opens the Chromium DevTools protocol
    // on 127.0.0.1, so a script can drive and inspect each tab.
    var port = System.Environment.GetEnvironmentVariable("PDFSTUDIO_DEBUG_PORT");
    int portNumber;
    if (int.TryParse(port, out portNumber)) options.AdditionalBrowserArguments = "--remote-debugging-port=" + portNumber;
#endif
    Environment = CoreWebView2Environment.CreateAsync(null, dataDir, options);
    var form = NewWindow();
    if (files.Count > 0) form.OpenPaths(files, null);
    if (listen) StartListening();
  }

  public MainForm Front { get { return front ?? forms.LastOrDefault(); } }
  public IEnumerable<MainForm> Forms { get { return forms; } }

  public MainForm NewWindow() {
    var form = new MainForm(this, Front);
    forms.Add(form);
    form.Activated += (s, e) => front = form;
    form.FormClosed += (s, e) => {
      forms.Remove(form);
      if (front == form) front = forms.LastOrDefault();
      if (forms.Count == 0) ExitThread();
    };
    front = form;
    form.Show();
    return form;
  }

  void Received(List<string> files) {
    var form = Front ?? NewWindow();
    if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
    form.Activate();
    if (files.Count > 0) form.OpenPaths(files, null);
  }

  /// Later launches (Explorer "Open with", a shortcut) send their files here through a per-user pipe.
  void StartListening() {
    var thread = new Thread(() => {
      int failures = 0;
      while (failures < 20) {
        try {
          using (var pipe = new NamedPipeServerStream(Program.PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte)) {
            pipe.WaitForConnection();
            string text;
            using (var reader = new StreamReader(pipe, Encoding.UTF8)) text = reader.ReadToEnd();
            var files = text.Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0 && File.Exists(x)).ToList();
            invoker.BeginInvoke((Action)(() => Received(files)));
            failures = 0;
          }
        } catch (Exception) {
          failures++;
          Thread.Sleep(500);
        }
      }
    });
    thread.IsBackground = true;
    thread.Start();
  }
}

// MARK: - Window with document tabs

sealed class MainForm : Form {
  readonly App app;
  readonly TabStrip strip;
  readonly Panel content;
  readonly List<DocTab> tabs = new List<DocTab>();
  DocTab selected;
  bool closeConfirmed, asking;

  public IList<DocTab> Tabs { get { return tabs; } }
  public DocTab Selected { get { return selected; } }
  public Panel Content { get { return content; } }

  public MainForm(App app, MainForm cascadeFrom) {
    this.app = app;
    Text = Program.AppName;
    if (Program.AppIcon != null) Icon = Program.AppIcon;
    BackColor = Theme.Bg;
    KeyPreview = true;
    StartPosition = FormStartPosition.Manual;
    MinimumSize = new Size(Px(640), Px(420));
    PlaceWindow(cascadeFrom);

    content = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Panel };
    strip = new TabStrip(this) { Dock = DockStyle.Top };
    Controls.Add(content);
    Controls.Add(strip);
    content.BringToFront();
    Theme.Changed += OnThemeChanged;
    AddTab(true);
  }

  int Px(int v) { return (int)Math.Round(v * Native.Dpi(this) / 96.0); }

  /// Moved to a monitor with different scaling: take the size Windows suggests and redraw the tab strip.
  protected override void WndProc(ref Message m) {
    base.WndProc(ref m);
    if (m.Msg == Native.WM_DPICHANGED) {
      var r = (Native.RECT)Marshal.PtrToStructure(m.LParam, typeof(Native.RECT));
      Bounds = new Rectangle(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
      MinimumSize = new Size(Px(640), Px(420));
      strip.UpdateMetrics();
    }
  }

  void OnThemeChanged(object sender, EventArgs e) {
    if (IsDisposed) return;
    BeginInvoke((Action)(() => { BackColor = Theme.Bg; content.BackColor = Theme.Panel; Theme.ApplyTitleBar(this); strip.Invalidate(); }));
  }

  protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Theme.ApplyTitleBar(this); }

  // MARK: Window size and place (the last window closed is remembered, like the Mac app's autosave)

  static string BoundsFile { get { return Path.Combine(Program.DataDir, "window.txt"); } }

  void PlaceWindow(MainForm cascadeFrom) {
    if (cascadeFrom != null && cascadeFrom.WindowState == FormWindowState.Normal) {
      Bounds = new Rectangle(cascadeFrom.Left + Px(24), cascadeFrom.Top + Px(24), cascadeFrom.Width, cascadeFrom.Height);
      return;
    }
    try {
      var parts = File.ReadAllText(BoundsFile).Split(',').Select(int.Parse).ToArray();
      var r = new Rectangle(parts[0], parts[1], parts[2], parts[3]);
      if (r.Width >= 300 && r.Height >= 200 && Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(r))) {
        Bounds = r;
        if (parts.Length > 4 && parts[4] == 1) WindowState = FormWindowState.Maximized;
        return;
      }
    } catch (Exception) { }
    var area = Screen.PrimaryScreen.WorkingArea;
    var size = new Size(Math.Min(Px(1280), (int)(area.Width * 0.9)), Math.Min(Px(880), (int)(area.Height * 0.9)));
    Bounds = new Rectangle(area.Left + (area.Width - size.Width) / 2, area.Top + (area.Height - size.Height) / 2, size.Width, size.Height);
  }

  void SaveBounds() {
    try {
      var r = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
      Directory.CreateDirectory(Program.DataDir);
      File.WriteAllText(BoundsFile, string.Join(",", new[] { r.X, r.Y, r.Width, r.Height, WindowState == FormWindowState.Maximized ? 1 : 0 }));
    } catch (Exception) { }
  }

  // MARK: Tabs

  public DocTab AddTab(bool select) {
    var tab = new DocTab(this);
    tabs.Add(tab);
    if (select || selected == null) SelectTab(tab);
    strip.Invalidate();
    tab.Start(app.Environment);
    return tab;
  }

  public void SelectTab(DocTab tab) {
    if (tab == null || !tabs.Contains(tab)) return;
    if (selected != null && selected != tab) selected.Web.Visible = false;
    selected = tab;
    tab.Web.Visible = true;
    tab.Web.BringToFront();
    tab.Web.Focus();
    UpdateTitle();
    strip.Invalidate();
  }

  public void SelectIndex(int index) { if (index >= 0 && index < tabs.Count) SelectTab(tabs[index]); }

  public void Cycle(int step) {
    if (tabs.Count < 2 || selected == null) return;
    int i = (tabs.IndexOf(selected) + step + tabs.Count) % tabs.Count;
    SelectTab(tabs[i]);
  }

  public void TabChanged(DocTab tab) {
    if (tab == selected) UpdateTitle();
    strip.Invalidate();
  }

  void UpdateTitle() {
    if (selected == null || selected.Name.Length == 0) { Text = Program.AppName; return; }
    Text = (selected.Dirty ? "• " : "") + selected.Name + " — " + Program.AppName;
  }

  /// Closes a tab, asking first if it has unsaved changes. Closing the last tab closes the window.
  public async void CloseTab(DocTab tab) {
    if (asking || !tabs.Contains(tab)) return;
    asking = true;
    try {
      var state = await tab.GetState();
      if (state.Dirty) {
        SelectTab(tab);
        var label = tab.Name.Length > 0 ? tab.Name : "this document";
        if (!Dialogs.ConfirmDiscard(this, "Close “" + label + "” without saving?\n\nYour changes will be lost.")) return;
      }
    } finally { asking = false; }
    RemoveTab(tab);
  }

  void RemoveTab(DocTab tab) {
    int i = tabs.IndexOf(tab);
    if (i < 0) return;
    tabs.RemoveAt(i);
    if (tabs.Count == 0) { selected = null; closeConfirmed = true; Close(); tab.Dispose(); return; }
    if (selected == tab) { selected = null; SelectTab(tabs[Math.Min(i, tabs.Count - 1)]); }
    tab.Dispose();
    strip.Invalidate();
  }

  // MARK: Opening files

  public void ShowOpenDialog(DocTab requester) {
    using (var d = new OpenFileDialog()) {
      d.Title = "Open";
      d.Multiselect = true;
      d.Filter = Program.OpenFilter;
      var folder = requester != null ? requester.Folder : null;
      if (folder != null && Directory.Exists(folder)) d.InitialDirectory = folder;
      if (d.ShowDialog(this) == DialogResult.OK) OpenPaths(d.FileNames.ToList(), requester);
    }
  }

  /// Each PDF and each Markdown file gets its own tab (a Markdown file takes the chosen pictures with it).
  /// The first one goes into the requesting tab if nothing is open there yet.
  public async void OpenPaths(List<string> paths, DocTab requester) {
    var md = paths.Where(Program.IsMd).ToList();
    var pdf = paths.Where(Program.IsPdf).ToList();
    var images = paths.Where(Program.IsImage).ToList();
    var docs = new List<List<string>>();
    foreach (var m in md) { var d = new List<string> { m }; d.AddRange(images); docs.Add(d); }
    foreach (var p in pdf) docs.Add(new List<string> { p });
    var target = requester ?? selected;
    if (docs.Count == 0) {
      if (images.Count > 0 && target != null) { target.Send(images); return; } // pictures for the open Markdown file
      Dialogs.Error(this, "Please choose a PDF or Markdown (.md) file.");
      return;
    }
    bool first = true;
    foreach (var doc in docs) {
      DocTab tab = null;
      if (first && target != null && tabs.Contains(target) && !target.HasReceivedFile) {
        target.HasReceivedFile = true; // claim it before the check, so a second file can't take it too
        var state = await target.GetState();
        if (!state.HasDoc) tab = target;
      }
      first = false;
      if (tab == null) tab = AddTab(true); else SelectTab(tab);
      tab.Send(doc);
    }
    if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
    Activate();
  }

  // MARK: Keyboard shortcuts (also forwarded by WebView2 while the page has focus)

  protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
    if (RunShortcut(keyData)) return true;
    return base.ProcessCmdKey(ref msg, keyData);
  }

  public bool RunShortcut(Keys keyData) {
    switch (keyData) {
      case Keys.Control | Keys.T: AddTab(true); return true;
      case Keys.Control | Keys.N: app.NewWindow(); return true;
      case Keys.Control | Keys.O: ShowOpenDialog(selected); return true;
      case Keys.Control | Keys.W:
      case Keys.Control | Keys.F4: if (selected != null) CloseTab(selected); return true;
      case Keys.Control | Keys.Tab:
      case Keys.Control | Keys.PageDown: Cycle(1); return true;
      case Keys.Control | Keys.Shift | Keys.Tab:
      case Keys.Control | Keys.PageUp: Cycle(-1); return true;
    }
    if ((keyData & Keys.Modifiers) == Keys.Control) {
      var k = keyData & Keys.KeyCode;
      if (k >= Keys.D1 && k <= Keys.D9) { SelectIndex(k == Keys.D9 ? tabs.Count - 1 : k - Keys.D1); return true; }
    }
    return false;
  }

  /// The same shortcuts, reported by the page script when WebView2 doesn't forward them.
  public void RunShortcut(string name, DocTab from) {
    switch (name) {
      case "open": ShowOpenDialog(from); break;
      case "newTab": AddTab(true); break;
      case "newWindow": app.NewWindow(); break;
      case "closeTab": CloseTab(from); break;
      case "nextTab": Cycle(1); break;
      case "prevTab": Cycle(-1); break;
      default:
        int n;
        if (name != null && name.StartsWith("tab") && int.TryParse(name.Substring(3), out n) && n >= 1 && n <= 9)
          SelectIndex(n == 9 ? tabs.Count - 1 : n - 1);
        break;
    }
  }

  // MARK: Closing the window

  protected override void OnFormClosing(FormClosingEventArgs e) {
    if (closeConfirmed || e.CloseReason == CloseReason.WindowsShutDown) {
      SaveBounds();
      base.OnFormClosing(e);
      return;
    }
    e.Cancel = true;
    ConfirmClose();
  }

  async void ConfirmClose() {
    if (asking) return;
    asking = true;
    try {
      var dirty = new List<DocTab>();
      foreach (var tab in tabs.ToArray()) if ((await tab.GetState()).Dirty) dirty.Add(tab);
      if (dirty.Count > 0) {
        SelectTab(dirty[0]);
        string what = dirty.Count == 1
          ? "“" + (dirty[0].Name.Length > 0 ? dirty[0].Name : "A document") + "” has unsaved changes."
          : dirty.Count + " documents in this window have unsaved changes.";
        if (!Dialogs.ConfirmDiscard(this, what + "\n\nClose the window anyway? Your changes will be lost.")) return;
      }
      closeConfirmed = true;
    } finally { asking = false; }
    Close();
  }

  protected override void OnFormClosed(FormClosedEventArgs e) {
    Theme.Changed -= OnThemeChanged;
    foreach (var tab in tabs.ToArray()) tab.Dispose();
    tabs.Clear();
    base.OnFormClosed(e);
  }
}

// MARK: - Tab strip

sealed class TabStrip : Control {
  readonly MainForm form;
  readonly ToolTip tip = new ToolTip();
  int hover = -1;
  bool hoverClose, hoverPlus;
  string tipText = "";

  public TabStrip(MainForm form) {
    this.form = form;
    SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    SetStyle(ControlStyles.Selectable, false);
    AllowDrop = true;
    UpdateMetrics();
  }

  int S(int v) { return (int)Math.Round(v * Native.Dpi(this) / 96.0); }

  public void UpdateMetrics() {
    Height = S(38);
    Font = new Font("Segoe UI", 12f * Native.Dpi(this) / 96f, GraphicsUnit.Pixel);
    Invalidate();
  }

  protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); UpdateMetrics(); }

  Rectangle TabRect(int i) {
    int n = Math.Max(1, form.Tabs.Count);
    int avail = Width - S(12) - S(40);
    int w = Math.Max(S(56), Math.Min(S(230), avail / n));
    return new Rectangle(S(6) + i * w, S(6), w, Height - S(6));
  }

  Rectangle CloseRect(Rectangle r) {
    int size = S(20);
    return new Rectangle(r.Right - S(6) - size, r.Top + (r.Height - size) / 2, size, size);
  }

  Rectangle PlusRect {
    get {
      int n = form.Tabs.Count;
      int x = n == 0 ? S(6) : TabRect(n - 1).Right + S(4);
      int size = S(28);
      return new Rectangle(x, S(6) + (Height - S(6) - size) / 2, size, size);
    }
  }

  static string TabLabel(DocTab t) { return t.Name.Length > 0 ? t.Name : "New tab"; }

  protected override void OnPaint(PaintEventArgs e) {
    var g = e.Graphics;
    g.Clear(Theme.Bg);
    g.SmoothingMode = SmoothingMode.AntiAlias;
    using (var border = new Pen(Theme.Border)) g.DrawLine(border, 0, Height - 1, Width, Height - 1);
    var tabs = form.Tabs;
    for (int i = 0; i < tabs.Count; i++) {
      var t = tabs[i];
      var r = TabRect(i);
      bool sel = t == form.Selected;
      if (sel || i == hover) {
        using (var path = RoundedTop(r, S(8)))
        using (var fill = new SolidBrush(sel ? Theme.Panel : Theme.Hover)) g.FillPath(fill, path);
        if (sel) using (var pen = new Pen(Theme.Border)) using (var path = RoundedTop(r, S(8))) g.DrawPath(pen, path);
        if (sel) using (var fill = new SolidBrush(Theme.Panel)) g.FillRectangle(fill, r.Left + 1, r.Bottom - 2, r.Width - 1, 3);
      } else if (i + 1 < tabs.Count && tabs[i + 1] != form.Selected && i + 1 != hover) {
        using (var pen = new Pen(Theme.Border)) g.DrawLine(pen, r.Right, r.Top + S(8), r.Right, r.Bottom - S(8));
      }
      var close = CloseRect(r);
      int left = r.Left + S(12);
      if (t.Dirty) {
        int d = S(7);
        using (var dot = new SolidBrush(Theme.Accent)) g.FillEllipse(dot, left, r.Top + (r.Height - d) / 2, d, d);
        left += d + S(6);
      }
      var textRect = new Rectangle(left, r.Top, Math.Max(0, close.Left - S(4) - left), r.Height);
      TextRenderer.DrawText(g, TabLabel(t), Font, textRect, sel ? Theme.Text : Theme.Muted,
        TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
      if (sel || i == hover) {
        if (i == hover && hoverClose) using (var b = new SolidBrush(Theme.Dark ? Color.FromArgb(60, 255, 255, 255) : Color.FromArgb(28, 0, 0, 0))) g.FillEllipse(b, close);
        DrawCross(g, close, Theme.Muted, S(4));
      }
    }
    var plus = PlusRect;
    if (hoverPlus) using (var b = new SolidBrush(Theme.Hover)) g.FillEllipse(b, plus);
    using (var pen = new Pen(Theme.Muted, Math.Max(1f, S(15) / 10f))) {
      int c = S(5), cx = plus.Left + plus.Width / 2, cy = plus.Top + plus.Height / 2;
      g.DrawLine(pen, cx - c, cy, cx + c, cy);
      g.DrawLine(pen, cx, cy - c, cx, cy + c);
    }
  }

  void DrawCross(Graphics g, Rectangle r, Color color, int inset) {
    using (var pen = new Pen(color, Math.Max(1f, S(14) / 10f))) {
      int a = inset + S(2);
      g.DrawLine(pen, r.Left + a, r.Top + a, r.Right - a, r.Bottom - a);
      g.DrawLine(pen, r.Right - a, r.Top + a, r.Left + a, r.Bottom - a);
    }
  }

  static GraphicsPath RoundedTop(Rectangle r, int radius) {
    var p = new GraphicsPath();
    int d = radius * 2;
    p.AddLine(r.Left, r.Bottom, r.Left, r.Top + radius);
    p.AddArc(r.Left, r.Top, d, d, 180, 90);
    p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
    p.AddLine(r.Right, r.Top + radius, r.Right, r.Bottom);
    return p;
  }

  int HitTab(Point p) {
    for (int i = 0; i < form.Tabs.Count; i++) if (TabRect(i).Contains(p)) return i;
    return -1;
  }

  protected override void OnMouseMove(MouseEventArgs e) {
    base.OnMouseMove(e);
    int h = HitTab(e.Location);
    bool hc = h >= 0 && CloseRect(TabRect(h)).Contains(e.Location);
    bool hp = PlusRect.Contains(e.Location);
    if (h != hover || hc != hoverClose || hp != hoverPlus) { hover = h; hoverClose = hc; hoverPlus = hp; Invalidate(); }
    string text = hp ? "New tab (Ctrl+T)" : hc ? "Close tab (Ctrl+W)" : h >= 0 ? TabLabel(form.Tabs[h]) : "";
    if (text != tipText) { tipText = text; tip.SetToolTip(this, text); }
  }

  protected override void OnMouseLeave(EventArgs e) {
    base.OnMouseLeave(e);
    hover = -1; hoverClose = hoverPlus = false; Invalidate();
  }

  protected override void OnMouseDown(MouseEventArgs e) {
    base.OnMouseDown(e);
    int h = HitTab(e.Location);
    if (e.Button == MouseButtons.Left) {
      if (PlusRect.Contains(e.Location)) { form.AddTab(true); return; }
      if (h < 0) return;
      var tab = form.Tabs[h];
      if (CloseRect(TabRect(h)).Contains(e.Location)) form.CloseTab(tab); else form.SelectTab(tab);
    }
  }

  protected override void OnMouseUp(MouseEventArgs e) {
    base.OnMouseUp(e);
    int h = HitTab(e.Location);
    if (e.Button == MouseButtons.Middle && h >= 0) form.CloseTab(form.Tabs[h]);
  }

  protected override void OnMouseDoubleClick(MouseEventArgs e) {
    base.OnMouseDoubleClick(e);
    if (e.Button == MouseButtons.Left && HitTab(e.Location) < 0 && !PlusRect.Contains(e.Location)) form.AddTab(true);
  }

  // Files dropped on the tab strip open in tabs (dropped on the page, the page handles them itself).
  protected override void OnDragEnter(DragEventArgs e) {
    base.OnDragEnter(e);
    e.Effect = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
  }

  protected override void OnDragDrop(DragEventArgs e) {
    base.OnDragDrop(e);
    var files = e.Data.GetData(DataFormats.FileDrop) as string[];
    if (files != null && files.Length > 0) form.OpenPaths(files.Where(File.Exists).ToList(), form.Selected);
  }
}

// MARK: - One document (a WebView2 running the app)

struct PageState { public bool HasDoc, Dirty; }

sealed class DocTab : IDisposable {
  public readonly WebView2 Web;
  readonly MainForm form;
  public string Name = "";
  public bool Dirty;
  /// Set once a file has been sent to this tab, so a batch of files gets one tab each.
  public bool HasReceivedFile;
  public string Folder;
  bool loaded, disposed;
  readonly List<List<string>> pending = new List<List<string>>();
  readonly Dictionary<string, string> saveTargets = new Dictionary<string, string>(); // token -> file picked in a Save dialog

  public DocTab(MainForm form) {
    this.form = form;
    Web = new WebView2 { Dock = DockStyle.Fill, Visible = false, DefaultBackgroundColor = Theme.Panel };
    form.Content.Controls.Add(Web);
    var unused = Web.Handle; // create the window now, so background tabs load too
  }

  CoreWebView2 Core { get { return disposed ? null : Web.CoreWebView2; } }

  public async void Start(Task<CoreWebView2Environment> environment) {
    try {
      var env = await environment;
      if (disposed) return;
      await Web.EnsureCoreWebView2Async(env);
    } catch (Exception ex) {
      if (disposed) return;
      Dialogs.Error(form, "PDF Studio needs the Microsoft Edge WebView2 Runtime, which is part of Windows 11 and most Windows 10 PCs.\n\n" +
        ex.Message + "\n\nYou can get it from https://go.microsoft.com/fwlink/p/?LinkId=2124703");
      return;
    }
    if (disposed) return;
    var core = Web.CoreWebView2;
    var s = core.Settings;
#if DEBUG
    s.AreDevToolsEnabled = true;
#else
    s.AreDevToolsEnabled = false;
#endif
    s.AreDefaultScriptDialogsEnabled = false;   // native dialogs instead (see OnScriptDialog)
    s.AreBrowserAcceleratorKeysEnabled = false; // no reload, browser find or browser zoom: the app has its own
    s.IsZoomControlEnabled = false;
    s.IsPinchZoomEnabled = false;
    s.IsSwipeNavigationEnabled = false;
    s.IsStatusBarEnabled = false;
    s.IsPasswordAutosaveEnabled = false;
    s.IsGeneralAutofillEnabled = false;
    core.SetVirtualHostNameToFolderMapping(Program.Host, Program.AppDir, CoreWebView2HostResourceAccessKind.DenyCors);
    await core.AddScriptToExecuteOnDocumentCreatedAsync(Bridge.Script);
    if (disposed) return;
    core.NavigationStarting += OnNavigationStarting;
    core.NavigationCompleted += OnNavigationCompleted;
    core.NewWindowRequested += OnNewWindowRequested;
    core.DocumentTitleChanged += OnTitleChanged;
    core.WebMessageReceived += OnWebMessage;
    core.ScriptDialogOpening += OnScriptDialog;
    core.ContextMenuRequested += OnContextMenu;
    core.ProcessFailed += OnProcessFailed;
    core.Navigate(Program.AppUrl);
  }

  static bool IsAppUrl(string uri) {
    if (uri == null) return false;
    int hash = uri.IndexOf('#');
    var bare = hash < 0 ? uri : uri.Substring(0, hash);
    return string.Equals(bare, Program.AppUrl, StringComparison.OrdinalIgnoreCase);
  }

  // MARK: Opening files

  public void Send(List<string> paths) {
    HasReceivedFile = true;
    if (loaded) Deliver(paths); else pending.Add(paths);
  }

  void Deliver(List<string> paths) {
    var core = Core;
    if (core == null) return;
    var sb = new StringBuilder("{\"type\":\"open\",\"files\":[");
    int count = 0;
    foreach (var p in paths) {
      byte[] bytes;
      try { bytes = File.ReadAllBytes(p); } catch (Exception ex) {
        Dialogs.Error(form, "Could not open “" + Path.GetFileName(p) + "”.\n\n" + ex.Message);
        continue;
      }
      if (count++ > 0) sb.Append(',');
      sb.Append("{\"name\":").Append(Program.JsonString(Path.GetFileName(p)))
        .Append(",\"mime\":").Append(Program.JsonString(Program.MimeType(p)))
        .Append(",\"data\":\"").Append(Convert.ToBase64String(bytes)).Append("\"}");
    }
    if (count == 0) return;
    sb.Append("]}");
    Folder = Path.GetDirectoryName(paths[0]);
    core.PostWebMessageAsJson(sb.ToString());
  }

  /// Asks the page whether it shows a document and whether it has unsaved changes.
  public async Task<PageState> GetState() {
    var state = new PageState { Dirty = Dirty };
    var core = Core;
    if (core == null || !loaded) return state;
    try {
      var task = core.ExecuteScriptAsync("window.__pdfstudioNative ? window.__pdfstudioNative.state() : null");
      if (await Task.WhenAny(task, Task.Delay(3000)) != task) return state; // page busy: go by the title's unsaved marker
      var d = Program.Json.Deserialize<Dictionary<string, object>>(task.Result);
      if (d != null) { state.HasDoc = Program.Bool(d, "hasDoc"); state.Dirty = Program.Bool(d, "dirty"); }
    } catch (Exception) { }
    return state;
  }

  // MARK: WebView2 events

  void OnNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs e) {
    if (IsAppUrl(e.Uri)) return;
    // The app itself (including #anchors inside it) may load; web links open in the default browser.
    e.Cancel = true;
    Program.OpenExternal(e.Uri);
  }

  void OnNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e) {
    var core = Core;
    if (core == null || !e.IsSuccess || !IsAppUrl(core.Source)) return;
    loaded = true;
    var files = pending.ToList();
    pending.Clear();
    foreach (var f in files) Deliver(f);
  }

  async void OnNewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs e) {
    // The app opens the edited PDF as a blob: URL for printing. Show it in a print preview window.
    if (e.Uri.StartsWith("blob:https://" + Program.Host + "/", StringComparison.OrdinalIgnoreCase)) {
      var deferral = e.GetDeferral();
      try {
        var preview = new PreviewForm(Name.Length > 0 ? Name : "Document", form);
        preview.Show();
        var core = await preview.Init(await App.Current.Environment);
        e.NewWindow = core;
        e.Handled = true;
      } catch (Exception ex) {
        e.Handled = true;
        Dialogs.Error(form, "Could not open the print preview.\n\n" + ex.Message);
      } finally {
        deferral.Complete();
      }
      return;
    }
    e.Handled = true;
    Program.OpenExternal(e.Uri);
  }

  /// The page shows "• name — PDF Studio" while there are unsaved changes.
  void OnTitleChanged(object sender, object e) {
    var core = Core;
    if (core == null) return;
    var text = core.DocumentTitle ?? "";
    bool edited = text.StartsWith("• ");
    if (edited) text = text.Substring(2);
    const string suffix = " — PDF Studio";
    if (text.EndsWith(suffix)) text = text.Substring(0, text.Length - suffix.Length);
    else if (text == Program.AppName || text.StartsWith("https://")) text = "";
    Name = text;
    Dirty = edited;
    form.TabChanged(this);
  }

  void OnProcessFailed(object sender, CoreWebView2ProcessFailedEventArgs e) {
    var core = Core;
    if (core == null) return;
    if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.RenderProcessExited ||
        e.ProcessFailedKind == CoreWebView2ProcessFailedKind.RenderProcessUnresponsive) {
      loaded = false;
      core.Navigate(Program.AppUrl);
    }
  }

  void OnContextMenu(object sender, CoreWebView2ContextMenuRequestedEventArgs e) {
    // Keep the editing items (cut, copy, paste, spelling…); drop browser items that would reload or leave the app.
    var drop = new HashSet<string> { "back", "forward", "reload", "saveAs", "print", "createQrCode", "share", "webCapture",
      "openLinkInNewWindow", "saveLinkAs", "saveImageAs", "copyImageLocation", "openImageInNewTab", "saveMediaAs",
#if !DEBUG
      "inspectElement",
#endif
    };
    var items = e.MenuItems;
    for (int i = items.Count - 1; i >= 0; i--) if (drop.Contains(items[i].Name)) items.RemoveAt(i);
    for (int i = items.Count - 1; i >= 0; i--) {
      bool sep = items[i].Kind == CoreWebView2ContextMenuItemKind.Separator;
      if (sep && (i == 0 || i == items.Count - 1 || items[i - 1].Kind == CoreWebView2ContextMenuItemKind.Separator)) items.RemoveAt(i);
    }
    if (items.Count == 0) e.Handled = true;
  }

  void OnScriptDialog(object sender, CoreWebView2ScriptDialogOpeningEventArgs e) {
    var deferral = e.GetDeferral();
    form.BeginInvoke((Action)(() => {
      try {
        switch (e.Kind) {
          case CoreWebView2ScriptDialogKind.Alert:
            Dialogs.Info(form, e.Message); e.Accept(); break;
          case CoreWebView2ScriptDialogKind.Confirm:
            if (Dialogs.Confirm(form, e.Message)) e.Accept(); break;
          case CoreWebView2ScriptDialogKind.Prompt:
            var text = Dialogs.Prompt(form, e.Message, e.DefaultText);
            if (text != null) { e.ResultText = text; e.Accept(); }
            break;
          default:
            e.Accept(); break;
        }
      } finally { deferral.Complete(); }
    }));
  }

  // MARK: Messages from the page

  void OnWebMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e) {
    if (!IsAppUrl(e.Source)) return;
    string raw = null;
    try { raw = e.TryGetWebMessageAsString(); } catch (ArgumentException) { }
    if (raw != null) {
      // "saveWrite\n<id>\n<token>\n<base64>": a string, so a large document isn't parsed as JSON.
      var parts = raw.Split(new[] { '\n' }, 4);
      if (parts.Length == 4 && parts[0] == "saveWrite") SaveWrite(parts[1], parts[2], parts[3]);
      return;
    }
    Dictionary<string, object> m;
    try { m = Program.Json.Deserialize<Dictionary<string, object>>(e.WebMessageAsJson); } catch (Exception) { return; }
    if (m == null) return;
    switch (Program.Str(m, "type")) {
      case "shortcut": form.RunShortcut(Program.Str(m, "name"), this); break;
      case "savePanel":
        var id = Program.Str(m, "id");
        var exts = new List<string>();
        var list = m.ContainsKey("exts") ? m["exts"] as IEnumerable : null;
        if (list != null) foreach (var x in list) if (x != null) exts.Add(Convert.ToString(x));
        var name = Program.Str(m, "name") ?? "Untitled";
        var description = Program.Str(m, "description") ?? "";
        form.BeginInvoke((Action)(() => SavePanel(id, name, description, exts)));
        break;
    }
  }

  void Reply(string id, string resultJson, string error) {
    var core = Core;
    if (core == null || id == null) return;
    long n;
    if (!long.TryParse(id, out n)) return;
    core.PostWebMessageAsJson("{\"type\":\"reply\",\"id\":" + n + ",\"result\":" + (resultJson ?? "null") +
      ",\"error\":" + (error == null ? "null" : Program.JsonString(error)) + "}");
  }

  void SavePanel(string id, string name, string description, List<string> exts) {
    exts = exts.Where(x => x.Length > 0 && x.IndexOfAny(new[] { '/', '\\', '*', '?', '|', ';' }) < 0).ToList();
    foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '-');
    using (var d = new SaveFileDialog()) {
      d.Title = "Save";
      d.FileName = name;
      d.OverwritePrompt = true;
      d.AddExtension = true;
      if (exts.Count > 0) {
        d.DefaultExt = exts[0];
        d.Filter = (description.Length > 0 ? description : exts[0].ToUpperInvariant() + " file") + "|" +
          string.Join(";", exts.Select(x => "*." + x).ToArray()) + "|All files|*.*";
      }
      if (Folder != null && Directory.Exists(Folder)) d.InitialDirectory = Folder;
      if (d.ShowDialog(form) != DialogResult.OK) { Reply(id, null, null); return; }
      var token = Guid.NewGuid().ToString("N");
      saveTargets[token] = d.FileName;
      Reply(id, "{\"token\":\"" + token + "\",\"name\":" + Program.JsonString(Path.GetFileName(d.FileName)) + "}", null);
    }
  }

  void SaveWrite(string id, string token, string base64) {
    // The page can only write to a file the user just picked, identified by a one-time token.
    string path;
    if (!saveTargets.TryGetValue(token, out path)) { Reply(id, null, "This save wasn't started from a Save dialog."); return; }
    saveTargets.Remove(token);
    byte[] data;
    try { data = Convert.FromBase64String(base64); } catch (FormatException) { Reply(id, null, "The document data was invalid."); return; }
    try {
      WriteAtomically(path, data);
      Folder = Path.GetDirectoryName(path);
      Reply(id, "true", null);
    } catch (Exception ex) {
      Reply(id, null, ex.Message);
    }
  }

  static void WriteAtomically(string path, byte[] data) {
    var tmp = path + "." + Guid.NewGuid().ToString("N").Substring(0, 8) + ".tmp";
    File.WriteAllBytes(tmp, data);
    try {
      if (!File.Exists(path)) { File.Move(tmp, path); return; }
      try { File.Replace(tmp, path, null, true); }
      catch (IOException) { File.Copy(tmp, path, true); File.Delete(tmp); } // e.g. some network drives
    } catch (Exception) {
      try { File.Delete(tmp); } catch (Exception) { }
      throw;
    }
  }

  public void Dispose() {
    if (disposed) return;
    disposed = true;
    if (form.Content.Controls.Contains(Web)) form.Content.Controls.Remove(Web);
    Web.Dispose();
  }
}

// MARK: - Print preview window (for the edited PDF)

sealed class PreviewForm : Form {
  public readonly WebView2 Web;

  public PreviewForm(string title, Form owner) {
    Text = "Print Preview — " + title;
    if (Program.AppIcon != null) Icon = Program.AppIcon;
    StartPosition = FormStartPosition.Manual;
    var area = Screen.FromControl(owner).WorkingArea;
    int scale = Native.Dpi(owner);
    var size = new Size(Math.Min(860 * scale / 96, (int)(area.Width * 0.8)), Math.Min(980 * scale / 96, (int)(area.Height * 0.9)));
    Bounds = new Rectangle(area.Left + (area.Width - size.Width) / 2, area.Top + (area.Height - size.Height) / 2, size.Width, size.Height);
    Web = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Theme.Bg };
    Controls.Add(Web);
  }

  protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Theme.ApplyTitleBar(this); }

  public async Task<CoreWebView2> Init(CoreWebView2Environment env) {
    await Web.EnsureCoreWebView2Async(env);
    var core = Web.CoreWebView2;
    core.Settings.AreDevToolsEnabled = false;
    core.Settings.IsStatusBarEnabled = false;
    // Links inside the PDF open in the default browser; the preview itself stays on the PDF.
    core.NavigationStarting += (s, e) => {
      if (e.Uri.StartsWith("blob:", StringComparison.OrdinalIgnoreCase) || e.Uri == "about:blank") return;
      e.Cancel = true; Program.OpenExternal(e.Uri);
    };
    core.NewWindowRequested += (s, e) => { e.Handled = true; Program.OpenExternal(e.Uri); };
    core.WindowCloseRequested += (s, e) => Close();
    return core;
  }
}

// MARK: - Dialogs

static class Dialogs {
  public static void Info(IWin32Window owner, string message) {
    MessageBox.Show(owner, message, Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
  }
  public static void Error(IWin32Window owner, string message) {
    MessageBox.Show(owner, message, Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
  }
  public static bool Confirm(IWin32Window owner, string message) {
    return MessageBox.Show(owner, message, Program.AppName, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK;
  }
  /// "Close without saving?" style questions. The safe answer (No) is the default button.
  public static bool ConfirmDiscard(IWin32Window owner, string message) {
    return MessageBox.Show(owner, message, Program.AppName, MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
  }

  /// A text prompt. The app's only prompt asks for a PDF password, so what is typed there is hidden.
  public static string Prompt(Form owner, string message, string defaultText) {
    using (var f = new Form()) {
      double k = Native.Dpi(owner) / 96.0;
      Func<int, int> S = v => (int)Math.Round(v * k);
      f.Text = Program.AppName;
      f.FormBorderStyle = FormBorderStyle.FixedDialog;
      f.MinimizeBox = f.MaximizeBox = false;
      f.ShowInTaskbar = false;
      f.StartPosition = FormStartPosition.CenterParent;
      f.Font = new Font("Segoe UI", 12f * (float)k, GraphicsUnit.Pixel);
      var label = new Label { Text = message, AutoSize = true, MaximumSize = new Size(S(380), 0), Location = new Point(S(14), S(14)) };
      f.Controls.Add(label);
      var size = label.GetPreferredSize(new Size(S(380), 0));
      var box = new TextBox { Text = defaultText ?? "", Location = new Point(S(14), S(22) + size.Height), Width = S(380) };
      if (message.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0) box.UseSystemPasswordChar = true;
      f.Controls.Add(box);
      var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Size = new Size(S(88), S(28)) };
      var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Size = new Size(S(88), S(28)) };
      int y = box.Bottom + S(14);
      cancel.Location = new Point(S(14) + S(380) - cancel.Width, y);
      ok.Location = new Point(cancel.Left - S(8) - ok.Width, y);
      f.Controls.Add(ok);
      f.Controls.Add(cancel);
      f.AcceptButton = ok;
      f.CancelButton = cancel;
      f.ClientSize = new Size(S(408), cancel.Bottom + S(14));
      f.Shown += (s, e) => { box.Focus(); box.SelectAll(); };
      return f.ShowDialog(owner) == DialogResult.OK ? box.Text : null;
    }
  }
}

// MARK: - Script added to the page before the app's own code

static class Bridge {
  // The app saves with showSaveFilePicker; that is routed to the native Save dialog here, as in the Mac app.
  // The page's Open button and Ctrl+O show the native Open dialog, so several files open in tabs.
  // window.__pdfstudio is the app's own hook object (see the end of src/app.js).
  public const string Script = @"
(() => {
  if (window.top !== window || !window.chrome || !window.chrome.webview) return;
  const wv = window.chrome.webview;
  const pending = new Map();
  let nextId = 1;
  const request = (msg) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    wv.postMessage(Object.assign({ id: String(id) }, msg));
  });
  const fromBase64 = (s) => {
    if (Uint8Array.fromBase64) return Uint8Array.fromBase64(s);
    const bin = atob(s); const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  };
  const toBase64 = (blob) => new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => { const s = String(r.result); resolve(s.slice(s.indexOf(',') + 1)); };
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });

  wv.addEventListener('message', async (e) => {
    const m = e.data;
    if (!m || typeof m !== 'object') return;
    if (m.type === 'reply') {
      const p = pending.get(Number(m.id));
      if (!p) return;
      pending.delete(Number(m.id));
      if (m.error) p.reject(new Error(m.error)); else p.resolve(m.result);
      return;
    }
    if (m.type === 'open') {
      try {
        const files = m.files.map((f) => new File([fromBase64(f.data)], f.name, { type: f.mime }));
        await window.__pdfstudio.openAny(files);
      } catch (err) {
        console.error('PDF Studio: could not open', err);
        alert('Could not open “' + m.files.map((f) => f.name).join(', ') + '”.\n\n' + ((err && err.message) || err));
      }
    }
  });

  window.showSaveFilePicker = async (opts = {}) => {
    const types = opts.types || [];
    const exts = types.flatMap((t) => Object.values(t.accept || {}).flat()).map((x) => String(x).replace(/^\./, ''));
    const target = await request({ type: 'savePanel', name: String(opts.suggestedName || 'Untitled'), exts, description: String((types[0] && types[0].description) || '') });
    if (!target) throw new DOMException('Save cancelled', 'AbortError');
    return {
      kind: 'file', name: target.name,
      async createWritable() {
        const parts = [];
        return {
          async write(data) { parts.push(data); },
          async close() {
            const data = await toBase64(new Blob(parts));
            const id = nextId++;
            await new Promise((resolve, reject) => {
              pending.set(id, { resolve, reject });
              wv.postMessage('saveWrite\n' + id + '\n' + target.token + '\n' + data);
            });
          },
        };
      },
    };
  };

  window.__pdfstudioNative = {
    state() {
      const S = window.__pdfstudio && window.__pdfstudio.S;
      return { hasDoc: !!S && (S.pages.length > 0 || S.mode === 'md'), dirty: !!(S && S.dirty) };
    },
  };

  const shortcut = (name) => wv.postMessage({ type: 'shortcut', name });
  window.addEventListener('keydown', (e) => {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    const k = e.key.toLowerCase();
    let name = null;
    if (k === 'o' && !e.shiftKey) name = 'open';
    else if (k === 't' && !e.shiftKey) name = 'newTab';
    else if (k === 'n' && !e.shiftKey) name = 'newWindow';
    else if ((k === 'w' && !e.shiftKey) || k === 'f4') name = 'closeTab';
    else if (k === 'tab') name = e.shiftKey ? 'prevTab' : 'nextTab';
    else if (k === 'pagedown') name = 'nextTab';
    else if (k === 'pageup') name = 'prevTab';
    else if (/^[1-9]$/.test(k) && !e.shiftKey) name = 'tab' + k;
    if (name) { e.preventDefault(); e.stopImmediatePropagation(); shortcut(name); }
  }, true);
  document.addEventListener('click', (e) => {
    if (!(e.target instanceof Element) || !e.target.closest('#btnOpen, #btnOpen2')) return;
    e.preventDefault(); e.stopImmediatePropagation(); shortcut('open');
  }, true);
})();
";
}

}
