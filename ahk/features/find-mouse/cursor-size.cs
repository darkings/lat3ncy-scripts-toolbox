using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

public static class Program {
  const uint IMAGE_CURSOR = 2;
  const uint LR_LOADFROMFILE = 0x10;
  const int Port = 47631;

  // 与 ThemeUtils.ps1 的箭头类角色保持一致。文本、缩放和不可用光标不改。
  static readonly uint[] CursorIds = {
    32512, // OCR_NORMAL / Arrow
    32650, // OCR_APPSTARTING
    32651, // OCR_HELP
    32649, // OCR_HAND
    32671, // OCR_PIN
    32672  // OCR_PERSON
  };

  static readonly string[] CursorNames = {
    "Arrow",
    "AppStarting",
    "Help",
    "Hand",
    "Pin",
    "Person"
  };

  [DllImport("user32.dll")]
  static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int cx, int cy, uint flags);
  [DllImport("user32.dll", SetLastError = true)]
  static extern bool DestroyCursor(IntPtr cursor);
  [DllImport("user32.dll", SetLastError = true)]
  static extern bool SetSystemCursor(IntPtr cursor, uint id);
  [DllImport("user32.dll")]
  static extern int GetSystemMetricsForDpi(int index, uint dpi);

  static int RestSize() {
    int dpi = 96;
    try {
      object value = Registry.GetValue(@"HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics", "AppliedDPI", 96);
      if (value != null) dpi = Convert.ToInt32(value);
    } catch {
      dpi = 96;
    }
    if (dpi < 96) dpi = 96;
    int size = GetSystemMetricsForDpi(13, (uint)dpi);
    return size > 0 ? size : 32;
  }

  static string CursorPath(string name) {
    object value = Registry.GetValue(@"HKEY_CURRENT_USER\Control Panel\Cursors", name, "");
    return value == null ? "" : Convert.ToString(value);
  }

  static bool ApplyOne(string path, uint id, int size) {
    if (path.Length == 0 || !File.Exists(path)) return false;
    IntPtr loaded = LoadImage(IntPtr.Zero, path, IMAGE_CURSOR, size, size, LR_LOADFROMFILE);
    if (loaded == IntPtr.Zero) return false;
    if (!SetSystemCursor(loaded, id)) {
      DestroyCursor(loaded);
      return false;
    }
    return true;
  }

  static bool Apply(string command) {
    int size = command == "large" ? 128 : RestSize();
    bool any = false;
    bool arrow = false;
    for (int i = 0; i < CursorIds.Length; i++) {
      bool ok = ApplyOne(CursorPath(CursorNames[i]), CursorIds[i], size);
      any = any || ok;
      if (i == 0) arrow = ok;
    }
    return arrow && any;
  }

  static int Serve() {
    TcpListener listener = new TcpListener(IPAddress.Loopback, Port);
    listener.Start();
    try {
      while (true) {
        using (TcpClient client = listener.AcceptTcpClient())
        using (NetworkStream stream = client.GetStream())
        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, false, 64, true))
        using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false), 64, true)) {
          writer.NewLine = "\n";
          writer.AutoFlush = true;
          string line = reader.ReadLine();
          if (line == "stop") {
            writer.WriteLine("ok");
            return 0;
          }
          writer.WriteLine(line == "large" || line == "rest" ? (Apply(line) ? "ok" : "fail") : "fail");
        }
      }
    } finally {
      listener.Stop();
    }
  }

  public static int Main(string[] args) {
    SetProcessDpiAwarenessContext(new IntPtr(-4));
    string command = args.Length > 0 ? args[0] : "serve";
    if (command == "serve") return Serve();
    if (command != "large" && command != "rest") return 2;
    return Apply(command) ? 0 : 1;
  }
}
