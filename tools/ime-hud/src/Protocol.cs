namespace Lat3ncyToolbox.ImeHud;

/// <summary>
/// AHK ↔ ImeHud 的纯文本协议。故意不用 JSON，方便 AHK 拼接和测试断言。
///
/// 显示：
///   STATE|&lt;CN|EN|CAPS&gt;|&lt;x&gt;|&lt;y&gt;|&lt;dpi&gt;|&lt;durationMs&gt;
/// 后四个字段都可省略；x/y 是 caret 锚点（屏幕物理像素，caret 底部），不是窗口左上角。
///
/// 其它：
///   HIDE
///   PING
///   QUIT
/// </summary>
internal static class Protocol
{
    public const int CopyDataId = 1;
    public const string WindowTitle = "Lat3ncyImeHud";
    public const string MutexName = @"Local\Lat3ncyImeHud";

    public enum Kind
    {
        None,
        State,
        Hide,
        Ping,
        Quit
    }

    public enum ImeState
    {
        Unknown,
        Chinese,
        English,
        Caps
    }

    public readonly struct Message
    {
        public Kind Kind { get; init; }
        public ImeState State { get; init; }
        public int X { get; init; }
        public int Y { get; init; }
        public int Dpi { get; init; }
        public int DurationMs { get; init; }
        public bool HasAnchor => X != 0 || Y != 0;
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
            return new Message { Kind = Kind.Hide };
        if (head == "PING")
            return new Message { Kind = Kind.Ping };
        if (head == "QUIT")
            return new Message { Kind = Kind.Quit };
        if (head != "STATE" || parts.Length < 2)
            return default;

        ImeState state = ParseState(parts[1]);
        if (state == ImeState.Unknown)
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

    public static ImeState ParseState(string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return ImeState.Unknown;

        switch (token.Trim().ToUpperInvariant())
        {
            case "CN":
            case "CHINESE":
            case "ZH":
            case "中":
                return ImeState.Chinese;
            case "EN":
            case "ENGLISH":
            case "A":
            case "英":
                return ImeState.English;
            case "CAPS":
            case "CAPSLOCK":
            case "CAP":
            case "大写":
                return ImeState.Caps;
            default:
                return ImeState.Unknown;
        }
    }

    static int ReadInt(string[] parts, int index)
    {
        if (index >= parts.Length)
            return 0;
        return int.TryParse(parts[index].Trim(), out int value) ? value : 0;
    }

    /// <summary>
    /// 不创建窗口，只校验协议和视觉常量。供 `ImeHud.exe --self-test` 使用。
    /// 返回 0 表示通过，非 0 是失败编号。
    /// </summary>
    public static int SelfTest()
    {
        if (!Match("STATE|CN", Kind.State, ImeState.Chinese))
            return 1;
        if (!Match("STATE|中", Kind.State, ImeState.Chinese))
            return 2;
        if (!Match("STATE|EN", Kind.State, ImeState.English))
            return 3;
        if (!Match("STATE|A", Kind.State, ImeState.English))
            return 4;
        if (!Match("STATE|CAPS", Kind.State, ImeState.Caps))
            return 5;
        if (!Match("STATE|大写", Kind.State, ImeState.Caps))
            return 6;
        if (!Match("STATE|CN|100|200", Kind.State, ImeState.Chinese, 100, 200))
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

        var (glyph, font, caps) = StateVisual.For(ImeState.Chinese);
        if (glyph != "中" || caps || font.IndexOf("YaHei", StringComparison.OrdinalIgnoreCase) < 0)
            return 13;

        (glyph, font, caps) = StateVisual.For(ImeState.English);
        if (glyph != "A" || caps)
            return 14;

        (glyph, font, caps) = StateVisual.For(ImeState.Caps);
        if (glyph != "A" || !caps)
            return 15;

        if (StateVisual.ClampDuration(0) != StateVisual.DefaultDurationMs)
            return 16;
        if (StateVisual.ClampDuration(500) != StateVisual.MinDurationMs)
            return 17;
        if (StateVisual.ClampDuration(2000) != StateVisual.MaxDurationMs)
            return 18;
        return 0;
    }

    static bool Match(string text, Kind kind, ImeState state = ImeState.Unknown, int x = 0, int y = 0)
    {
        Message message = Parse(text);
        return message.Kind == kind && message.State == state && message.X == x && message.Y == y;
    }
}
