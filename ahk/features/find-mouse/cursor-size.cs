using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

public static class Program {
  const uint IMAGE_CURSOR = 2;
  const uint LR_LOADFROMFILE = 0x10;
  const int Port = 47631;
  const uint SPI_SETCURSORS = 0x0057;

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
  [DllImport("user32.dll", SetLastError = true)]
  static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr OpenMutex(uint access, bool inherit, string name);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  const uint SYNCHRONIZE = 0x00100000;
  const uint WAIT_TIMEOUT = 0x00000102;
  const uint INFINITE = 0xFFFFFFFF;

  // 助手进程只有一个消息循环，但父进程守护线程也会 Apply，必须串行化。
  static readonly object ApplyGate = new object();
  static int parentPid = 0;
  static DateTime parentStarted = DateTime.MinValue;

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

  // 逐条还原失败（注册表里的方案路径缺失、光标文件被删）时不能把放大态留在全局：
  // 让系统按当前方案整表重载，这是 Windows 自己恢复系统光标的路径。
  static bool ReloadSystemCursors() {
    try {
      return SystemParametersInfo(SPI_SETCURSORS, 0, IntPtr.Zero, 0);
    } catch {
      return false;
    }
  }

  static bool Apply(string command) {
    lock (ApplyGate) {
      int size = command == "large" ? 128 : RestSize();
      bool any = false;
      bool arrow = false;
      for (int i = 0; i < CursorIds.Length; i++) {
        bool ok = ApplyOne(CursorPath(CursorNames[i]), CursorIds[i], size);
        any = any || ok;
        if (i == 0) arrow = ok;
      }
      // 还原是安全动作：哪怕一条都没换成，也要保证系统回到未放大的光标。
      if (command == "rest") {
        if (!any || !arrow) return ReloadSystemCursors();
        return true;
      }
      return arrow && any;
    }
  }

  // 记录父进程身份。只比 PID 不够：PID 会被复用，必须同时比启动时间。
  static bool WatchParent(int pid) {
    if (pid <= 0) return false;
    try {
      Process parent = Process.GetProcessById(pid);
      parentStarted = parent.StartTime;
      parentPid = pid;
      return true;
    } catch {
      return false;
    }
  }

  static bool ParentAlive() {
    if (parentPid <= 0) return false;
    try {
      Process parent = Process.GetProcessById(parentPid);
      // 父进程已退出但杀手仍持有句柄时，进程对象依旧能被打开，StartTime 也不变；
      // 必须显式看 HasExited，否则守护线程会一直以为父进程还活着。
      if (parent.HasExited) return false;
      return parent.StartTime == parentStarted;
    } catch {
      return false;
    }
  }

  static void RestoreAndExit() {
    for (int attempt = 0; attempt < 3; attempt++) {
      if (Apply("rest")) break;
      Thread.Sleep(200);
    }
    Environment.Exit(0);
  }

  // AHK 被强杀（Stop-Process -Force / 崩溃）时不会走 OnExit，没人发 rest。
  // 助手是唯一还活着的知情人，父进程一没就自己还原并退出，不留放大光标。
  static void WatchParentLoop() {
    while (true) {
      Thread.Sleep(500);
      if (!ParentAlive()) {
        RestoreAndExit();
        return;
      }
    }
  }

  // AHK 以拥有者身份持有一个命名互斥体；脚本被强杀（Stop-Process -Force、崩溃）时
  // 互斥体变成 abandoned，助手据此确定地判断父进程已死。不依赖打开对方进程的权限，
  // 也就不会因为权限/完整性级别差异而静默失效。
  static void StartParentWatch(int pid, string mutexName) {
    if (mutexName != null && mutexName.Length > 0) {
      IntPtr mutex = IntPtr.Zero;
      try {
        mutex = OpenMutex(SYNCHRONIZE, false, mutexName);
      } catch {
        mutex = IntPtr.Zero;
      }
      if (mutex == IntPtr.Zero) {
        // 名字给了却打不开：父进程已经不在了。
        RestoreAndExit();
        return;
      }
      Thread watcher = new Thread(delegate() {
        try {
          WaitForSingleObject(mutex, INFINITE);
        } catch {
        }
        RestoreAndExit();
      });
      watcher.IsBackground = true;
      watcher.Start();
      return;
    }
    // 兼容不带互斥体名的一键调用：退回按进程身份守护。
    if (WatchParent(pid)) {
      Thread fallback = new Thread(WatchParentLoop);
      fallback.IsBackground = true;
      fallback.Start();
    }
  }

  static int Serve(int pid, string mutexName) {
    TcpListener listener;
    try {
      listener = new TcpListener(IPAddress.Loopback, Port);
      listener.Start();
    } catch (SocketException) {
      // 端口被占用：多半是上一个 AHK 留下的孤儿助手，由调用方先回收再启动。
      return 3;
    }
    try {
      StartParentWatch(pid, mutexName);
      while (true) {
        // 单个客户端异常（半开连接、读超时、对端提前关闭）绝不能带走整个助手，
        // 否则下一次请求会永久堵在 connect/recv 上。
        try {
          using (TcpClient client = listener.AcceptTcpClient())
          using (NetworkStream stream = client.GetStream())
          using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, false, 64, true))
          using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false), 64, true)) {
            client.ReceiveTimeout = 250;
            client.SendTimeout = 2000;
            writer.NewLine = "\n";
            writer.AutoFlush = true;
            string line = reader.ReadLine();
            if (line == "stop") {
              // 正常停机也要还原：调用方可能已经忘了自己处于放大态。
              Apply("rest");
              writer.WriteLine("ok");
              return 0;
            }
            writer.WriteLine(line == "large" || line == "rest" ? (Apply(line) ? "ok" : "fail") : "fail");
          }
        } catch (IOException) {
        } catch (SocketException) {
        } catch (ObjectDisposedException) {
        }
      }
    } finally {
      listener.Stop();
    }
  }

  public static int Main(string[] args) {
    SetProcessDpiAwarenessContext(new IntPtr(-4));
    string command = args.Length > 0 ? args[0] : "serve";
    if (command == "serve") {
      int pid = 0;
      if (args.Length > 1) int.TryParse(args[1], out pid);
      string mutexName = args.Length > 2 ? args[2] : "";
      return Serve(pid, mutexName);
    }
    if (command != "large" && command != "rest") return 2;
    return Apply(command) ? 0 : 1;
  }
}
