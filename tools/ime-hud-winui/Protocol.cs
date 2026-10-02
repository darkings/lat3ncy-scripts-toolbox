using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// IME 状态协议。窗口标题 / 类名 / mutex 只认本 Renderer。
/// 只查找 Lat3ncyImeHudWinUi，不查找其他窗口。
///
/// STATE|&lt;CN|EN|CAPS&gt;|&lt;x&gt;|&lt;y&gt;|&lt;dpi&gt;|&lt;durationMs&gt;[|&lt;targetHwnd&gt;][|&lt;anchorSource&gt;]
/// MOVE|&lt;CN|EN|CAPS&gt;|&lt;x&gt;|&lt;y&gt;|&lt;dpi&gt;|&lt;durationMs&gt;[|&lt;targetHwnd&gt;][|&lt;anchorSource&gt;]
/// HIDE / PING / QUIT
///
/// anchorSource 是 AHK 侧解析出来的锚点来源（text-caret / win32-caret /
/// focus-bounds / target-window-bottom ...）。没有这一段就是 unknown，
/// 不能当成“跟着光标”。
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
        Move,
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
        public long TargetHwnd { get; init; }
        public string AnchorSource { get; init; }
    }

    /// <summary>
    /// 真实光标来源白名单，和 shared/notify/anchor.ahk、
    /// shared/notify/AnchorLocator.cs 三处必须一致。
    /// </summary>
    public static bool IsRealCaretSource(string? source)
    {
        return source is "text-caret" or "value-caret" or "imm-caret" or "win32-caret";
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
        if ((head != "STATE" && head != "MOVE") || parts.Length < 2)
            return default;

        string state = NormalizeState(parts[1]);
        if (state.Length == 0)
            return default;

        long targetHwnd = 0;
        if (parts.Length >= 7
            && long.TryParse(parts[6].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out long parsedHwnd)
            && parsedHwnd > 0)
        {
            targetHwnd = parsedHwnd;
        }
        return new Message
        {
            Kind = head == "MOVE" ? Kind.Move : Kind.State,
            State = state,
            X = ReadInt(parts, 2),
            Y = ReadInt(parts, 3),
            Dpi = ReadInt(parts, 4),
            DurationMs = ReadInt(parts, 5),
            TargetHwnd = targetHwnd,
            AnchorSource = NormalizeSource(ReadText(parts, 7)),
        };
    }

    /// <summary>
    /// 来源只允许安全字符，避免日志/协议被奇怪输入污染。
    /// 空段返回 unknown。
    /// </summary>
    public static string NormalizeSource(string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return "unknown";
        string trimmed = token.Trim();
        Span<char> buffer = trimmed.Length <= 32 ? stackalloc char[trimmed.Length] : new char[trimmed.Length];
        int length = 0;
        foreach (char ch in trimmed)
        {
            if (char.IsLetterOrDigit(ch) || ch == '-' || ch == '_')
                buffer[length++] = ch;
        }
        return length == 0 ? "unknown" : new string(buffer[..length]);
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
        return int.TryParse(parts[index].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int value)
            ? value
            : 0;
    }

    static string ReadText(string[] parts, int index)
    {
        return index >= parts.Length ? "" : parts[index].Trim();
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
        Message targeted = Parse("STATE|CN|10|20|96|750|12345");
        if (targeted.Kind != Kind.State || targeted.X != 10 || targeted.Y != 20 || targeted.TargetHwnd != 12345)
            return 16;
        if (Parse("STATE|EN|0|0|0|0").TargetHwnd != 0)
            return 17;
        if (Parse("STATE|CN|1.280|20|96|750").X != 0)
            return 18;
        if (Parse("STATE|CN|10|20|96|750|0").TargetHwnd != 0)
            return 19;

        // 锚点来源：必须能区分“真光标”和“退化锚点”。
        Message sourced = Parse("STATE|CN|10|20|96|750|12345|text-caret");
        if (sourced.Kind != Kind.State || sourced.AnchorSource != "text-caret")
            return 20;
        if (!IsRealCaretSource(sourced.AnchorSource))
            return 21;
        Message degraded = Parse("STATE|CN|10|20|96|750|12345|target-window-bottom");
        if (degraded.AnchorSource != "target-window-bottom" || IsRealCaretSource(degraded.AnchorSource))
            return 22;
        if (Parse("STATE|CN|10|20|96|750").AnchorSource != "unknown")
            return 23;
        if (Parse("STATE|CN|10|20|96|750|12345|").AnchorSource != "unknown")
            return 24;
        if (Parse("STATE|CN|10|20|96|750|12345|focus bounds").AnchorSource != "focusbounds")
            return 25;
        if (!IsRealCaretSource("win32-caret") || !IsRealCaretSource("imm-caret"))
            return 26;
        if (IsRealCaretSource("focus-bounds") || IsRealCaretSource("hint") || IsRealCaretSource(null))
            return 27;

        // MOVE 只重定位，不改状态 / 时长 / 目标窗口。
        Message move = Parse("MOVE|EN|100|200|96|750|12345|text-caret");
        if (move.Kind != Kind.Move || move.State != "EN" || move.X != 100 || move.Y != 200
            || move.TargetHwnd != 12345 || move.AnchorSource != "text-caret")
            return 28;
        if (Parse("MOVE|BOGUS|1|2").Kind != Kind.None)
            return 29;

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
            return false;

        return SendCopyData(existing, command);
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

    public static bool SendCopyData(IntPtr hwnd, string text)
    {
        if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd) || string.IsNullOrWhiteSpace(text))
            return false;

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
            IntPtr result = IntPtr.Zero;
            IntPtr sent = Native.SendMessageTimeout(
                hwnd,
                Native.WM_COPYDATA,
                IntPtr.Zero,
                ref cds,
                Native.SMTO_ABORTIFHUNG,
                2500,
                out result);
            bool ok = sent != IntPtr.Zero && result != IntPtr.Zero;
            if (!ok)
                HudLog.Line("forward-failed hwnd=" + hwnd.ToInt64() + " sent=" + sent.ToInt64() + " result=" + result.ToInt64());
            return ok;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
