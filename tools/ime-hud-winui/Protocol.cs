using System.Runtime.InteropServices;
using System.Text;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// IME 状态协议。窗口标题 / 类名 / mutex 只认本 Renderer。
/// 只查找 Lat3ncyImeHudWinUi，不查找其他窗口。
///
/// STATE|&lt;CN|EN|CAPS&gt;|&lt;x&gt;|&lt;y&gt;|&lt;dpi&gt;|&lt;durationMs&gt;
/// HIDE / PING / QUIT
/// </summary>
internal static class Protocol
{
    public const int CopyDataId = 1;
    public const string WindowClass = "Lat3ncyImeHudWinUi";
    public const string WindowTitle = "Lat3ncyImeHudWinUi";
    public const string MutexName = @"Local\Lat3ncyImeHudWinUi";

    public const int DefaultDurationMs = 750;
    public const int MinDurationMs = 650;
    public const int MaxDurationMs = 900;

    public enum Kind
    {
        None,
        State,
        Hide,
        Ping,
        Quit
    }

    public readonly struct Message
    {
        public Kind Kind { get; init; }
        public string State { get; init; }
        public int X { get; init; }
        public int Y { get; init; }
        public int Dpi { get; init; }
        public int DurationMs { get; init; }
    }

    public static Message Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return default;

        string trimmed = text.Trim().Trim('\0');
        if (trimmed.Length == 0)
            return default;

        string[] parts = trimmed.Split('|');
        string head = parts[0].Trim().ToUpperInvariant();
        if (head == "HIDE")
            return new Message { Kind = Kind.Hide, State = "" };
        if (head == "PING")
            return new Message { Kind = Kind.Ping, State = "" };
        if (head == "QUIT")
            return new Message { Kind = Kind.Quit, State = "" };
        if (head != "STATE" || parts.Length < 2)
            return default;

        string state = NormalizeState(parts[1]);
        if (state.Length == 0)
            return default;

        return new Message
        {
            Kind = Kind.State,
            State = state,
            X = ReadInt(parts, 2),
            Y = ReadInt(parts, 3),
            Dpi = ReadInt(parts, 4),
            DurationMs = ReadInt(parts, 5)
        };
    }

    public static string NormalizeState(string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return "";
        return token.Trim().ToUpperInvariant() switch
        {
            "CN" or "CHINESE" or "ZH" or "中" => "CN",
            "EN" or "ENGLISH" or "A" or "英" => "EN",
            "CAPS" or "CAPSLOCK" or "CAP" or "大写" => "CAPS",
            _ => ""
        };
    }

    public static int ClampDuration(int durationMs)
    {
        if (durationMs <= 0)
            return DefaultDurationMs;
        if (durationMs < MinDurationMs)
            return MinDurationMs;
        if (durationMs > MaxDurationMs)
            return MaxDurationMs;
        return durationMs;
    }

    static int ReadInt(string[] parts, int index)
    {
        if (index >= parts.Length)
            return 0;
        return int.TryParse(parts[index].Trim(), out int value) ? value : 0;
    }

    /// <summary>
    /// 不创建窗口，只校验协议常量和时长夹紧。供 --self-test 使用。
    /// 返回 0 表示通过。
    /// </summary>
    public static int SelfTest()
    {
        if (!Match("STATE|CN", Kind.State, "CN"))
            return 1;
        if (!Match("STATE|中", Kind.State, "CN"))
            return 2;
        if (!Match("STATE|EN", Kind.State, "EN"))
            return 3;
        if (!Match("STATE|A", Kind.State, "EN"))
            return 4;
        if (!Match("STATE|CAPS", Kind.State, "CAPS"))
            return 5;
        if (!Match("STATE|大写", Kind.State, "CAPS"))
            return 6;
        if (!Match("STATE|CN|100|200", Kind.State, "CN", 100, 200))
            return 7;
        if (!Match("HIDE", Kind.Hide))
            return 8;
        if (!Match("PING", Kind.Ping))
            return 9;
        if (!Match("QUIT", Kind.Quit))
            return 10;
        if (Parse("STATE|NOPE").Kind != Kind.None)
            return 11;
        if (Parse("").Kind != Kind.None)
            return 12;
        if (ClampDuration(0) != DefaultDurationMs)
            return 13;
        if (ClampDuration(500) != MinDurationMs)
            return 14;
        if (ClampDuration(2000) != MaxDurationMs)
            return 15;

        // 面板协议 / 定位是独立骨架，失败码从 101 / 201 起，不和芯片协议撞号。
        int panel = TranslationPanelProtocol.SelfTest();
        if (panel != 0)
            return panel;
        int anchor = TranslationPanelAnchor.SelfTest();
        if (anchor != 0)
            return anchor;
        int source = TranslationSource.SelfTest();
        if (source != 0)
            return source;
        int result = TranslationResult.SelfTest();
        if (result != 0)
            return result;
        int copy = TranslationCopy.SelfTest();
        if (copy != 0)
            return copy;
        int dismiss = TranslationPanelDismiss.SelfTest();
        if (dismiss != 0)
            return dismiss;
        return 0;
    }

    static bool Match(string text, Kind kind, string state = "", int x = 0, int y = 0)
    {
        Message message = Parse(text);
        return message.Kind == kind && message.State == state && message.X == x && message.Y == y;
    }

    /// <summary>
    /// 第二个进程把命令转给已有 HWND，然后立刻退出。
    /// 只找本 Renderer 的类名 / 标题，不查找其他窗口。
    /// </summary>
    public static bool TryForwardToExisting(string? command)
    {
        IntPtr existing = FindExistingWindowWithRetry();
        HudLog.Line("forward-find hwnd=" + existing.ToInt64()
            + " class=" + Native.GetWindowClassName(existing)
            + " command=" + (command ?? ""));
        if (existing == IntPtr.Zero)
            return false;
        if (string.IsNullOrWhiteSpace(command))
            return true;

        SendCopyData(existing, command);
        return true;
    }

    /// <summary>
    /// 第一个进程可能已经拿到 mutex，HWND 还在 CreateWindow 途中。短重试避免丢掉 STATE。
    /// </summary>
    public static IntPtr FindExistingWindowWithRetry()
    {
        for (int i = 0; i < 20; i++)
        {
            IntPtr hwnd = FindExistingWindow();
            if (hwnd != IntPtr.Zero)
                return hwnd;
            Thread.Sleep(50);
        }
        return IntPtr.Zero;
    }

    public static IntPtr FindExistingWindow()
    {
        IntPtr hwnd = Native.FindWindow(WindowClass, WindowTitle);
        if (Native.IsWindow(hwnd) && Native.GetWindowClassName(hwnd) == WindowClass)
            return hwnd;

        hwnd = Native.FindWindow(WindowClass, null);
        if (Native.IsWindow(hwnd) && Native.GetWindowClassName(hwnd) == WindowClass)
            return hwnd;

        hwnd = Native.FindWindow(null, WindowTitle);
        if (Native.IsWindow(hwnd) && Native.GetWindowClassName(hwnd) == WindowClass)
            return hwnd;

        IntPtr found = IntPtr.Zero;
        Native.ForEachTopLevelWindow(candidate =>
        {
            if (found != IntPtr.Zero)
                return;
            if (!Native.IsWindow(candidate))
                return;
            if (Native.GetWindowClassName(candidate) != WindowClass)
                return;
            found = candidate;
        });
        return found;
    }

    public static void SendCopyData(IntPtr hwnd, string text)
    {
        byte[] bytes = Encoding.Unicode.GetBytes(text + "\0");
        IntPtr buffer = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, buffer, bytes.Length);
            var cds = new Native.COPYDATASTRUCT
            {
                dwData = new IntPtr(CopyDataId),
                cbData = bytes.Length,
                lpData = buffer
            };
            Native.SendMessage(hwnd, Native.WM_COPYDATA, IntPtr.Zero, ref cds);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
