namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 翻译面板骨架协议。走现有 Renderer 的 WM_COPYDATA，不接线 AHK，不接翻译后端。
///
/// PANEL|OPEN
/// PANEL|OPEN|&lt;x&gt;|&lt;y&gt;|&lt;dpi&gt;|&lt;placeSource&gt;
/// PANEL|OPEN|&lt;x&gt;|&lt;y&gt;|&lt;dpi&gt;|&lt;placeSource&gt;|&lt;textSource&gt;|&lt;payload&gt;
/// PANEL|MOVE|&lt;x&gt;|&lt;y&gt;|&lt;dpi&gt;|&lt;placeSource&gt;
/// PANEL|TEXT|clipboard
/// PANEL|TEXT|explicit|&lt;payload&gt;
/// PANEL|TEXT|empty
/// PANEL|RESULT|explicit|&lt;payload&gt;
/// PANEL|RESULT|empty
/// PANEL|COPY|source
/// PANEL|COPY|result
/// PANEL|CLOSE
/// PANEL|PIN|1
/// PANEL|PIN|0
/// PANEL|PING
///
/// placeSource 只是调用方声明，不是 Renderer 自己去猜鼠标。
/// textSource 同样必须声明：没有 payload 绝不能偷偷读剪贴板。
/// 译文必须走 RESULT / 显式 payload；换原文时译文打回占位，不能假装已经译完。
/// COPY 必须声明 source / result。空占位绝不能覆盖用户剪贴板。
/// 快捷键按下时的鼠标位置当前未知：没有坐标就绝不能写成 mouse-at-hotkey。
/// payload 允许再含 | ，TEXT / RESULT 从对应字段起拼回去。
/// </summary>
internal static class TranslationPanelProtocol
{
    public enum Kind
    {
        None,
        Open,
        Move,
        Text,
        Result,
        Copy,
        Close,
        Pin,
        Ping
    }

    public readonly struct Message
    {
        public Kind Kind { get; init; }
        public int X { get; init; }
        public int Y { get; init; }
        public int Dpi { get; init; }
        public string Source { get; init; }
        public string TextSource { get; init; }
        public string ResultSource { get; init; }
        public string CopyTarget { get; init; }
        public string Payload { get; init; }
        public bool Pin { get; init; }
        public bool HasPoint => X != 0 || Y != 0;
    }

    public static bool IsPanelCommand(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return false;
        string trimmed = text.Trim().Trim('\0');
        return trimmed.StartsWith("PANEL", StringComparison.OrdinalIgnoreCase);
    }

    public static Message Parse(string? text)
    {
        if (!IsPanelCommand(text))
            return default;

        string trimmed = text!.Trim().Trim('\0');
        string[] parts = trimmed.Split('|');
        if (parts.Length < 2)
            return default;

        string head = parts[1].Trim().ToUpperInvariant();
        return head switch
        {
            "OPEN" => ReadPoint(Kind.Open, parts),
            "MOVE" => ReadPoint(Kind.Move, parts),
            "TEXT" => ReadText(parts),
            "RESULT" => ReadResult(parts),
            "COPY" => ReadCopy(parts),
            "CLOSE" => Empty(Kind.Close),
            "PIN" => new Message
            {
                Kind = Kind.Pin,
                Source = "",
                TextSource = "",
                ResultSource = "",
                CopyTarget = "",
                Payload = "",
                // 缺省第三段时按钉住处理；PIN|0 明确取消。
                Pin = parts.Length < 3 || ReadPin(parts[2])
            },
            "PING" => Empty(Kind.Ping),
            _ => default
        };
    }

    public static int SelfTest()
    {
        if (!Match("PANEL|OPEN", Kind.Open))
            return 101;
        if (!Match("PANEL|OPEN|120|240|96|explicit", Kind.Open, 120, 240, 96, "explicit"))
            return 102;
        if (!Match("PANEL|OPEN|10|20|144|mouse-at-hotkey", Kind.Open, 10, 20, 144, "mouse-at-hotkey"))
            return 103;
        if (!Match("PANEL|MOVE|1|2|96|caret", Kind.Move, 1, 2, 96, "caret"))
            return 104;
        if (!Match("PANEL|CLOSE", Kind.Close))
            return 105;
        if (!MatchPin("PANEL|PIN|1", pin: true))
            return 106;
        if (!MatchPin("PANEL|PIN|0", pin: false))
            return 107;
        if (!Match("PANEL|PING", Kind.Ping))
            return 108;
        if (Parse("PANEL|NOPE").Kind != Kind.None)
            return 109;
        if (Parse("STATE|CN").Kind != Kind.None)
            return 110;
        if (Parse("").Kind != Kind.None)
            return 111;
        // 没有坐标的 OPEN 不能假装已经拿到鼠标。
        Message open = Parse("PANEL|OPEN");
        if (open.HasPoint || open.Source.Length != 0 || open.TextSource.Length != 0)
            return 112;
        if (!MatchText("PANEL|TEXT|clipboard", "clipboard", ""))
            return 113;
        if (!MatchText("PANEL|TEXT|explicit|hello world", "explicit", "hello world"))
            return 114;
        if (!MatchText("PANEL|TEXT|explicit|a|b", "explicit", "a|b"))
            return 115;
        Message openClip = Parse("PANEL|OPEN|||||clipboard");
        if (openClip.Kind != Kind.Open || openClip.HasPoint || openClip.TextSource != "clipboard")
            return 116;
        Message openPayload = Parse("PANEL|OPEN|10|20|96|explicit|explicit|foo|bar");
        if (openPayload.Kind != Kind.Open
            || openPayload.X != 10
            || openPayload.Source != "explicit"
            || openPayload.TextSource != "explicit"
            || openPayload.Payload != "foo|bar")
            return 117;
        if (!MatchResult("PANEL|RESULT|explicit|你好世界", "explicit", "你好世界"))
            return 118;
        if (!MatchResult("PANEL|RESULT|explicit|a|b", "explicit", "a|b"))
            return 119;
        if (!MatchResult("PANEL|RESULT|empty", "empty", ""))
            return 120;
        if (Parse("PANEL|RESULT|clipboard").Kind != Kind.Result
            || Parse("PANEL|RESULT|clipboard").ResultSource != "clipboard")
            return 121;
        Message openEmptyResult = Parse("PANEL|OPEN");
        if (openEmptyResult.ResultSource.Length != 0 || openEmptyResult.CopyTarget.Length != 0)
            return 122;
        if (!MatchCopy("PANEL|COPY|source", "source"))
            return 123;
        if (!MatchCopy("PANEL|COPY|result", "result"))
            return 124;
        if (Parse("PANEL|COPY").Kind != Kind.Copy || Parse("PANEL|COPY").CopyTarget.Length != 0)
            return 125;
        return 0;
    }

    static Message Empty(Kind kind)
    {
        return new Message
        {
            Kind = kind,
            Source = "",
            TextSource = "",
            ResultSource = "",
            CopyTarget = "",
            Payload = ""
        };
    }

    static Message ReadPoint(Kind kind, string[] parts)
    {
        return new Message
        {
            Kind = kind,
            X = ReadInt(parts, 2),
            Y = ReadInt(parts, 3),
            Dpi = ReadInt(parts, 4),
            Source = ReadToken(parts, 5),
            TextSource = ReadToken(parts, 6),
            ResultSource = "",
            CopyTarget = "",
            Payload = JoinFrom(parts, 7)
        };
    }

    static Message ReadText(string[] parts)
    {
        return new Message
        {
            Kind = Kind.Text,
            Source = "",
            TextSource = ReadToken(parts, 2),
            ResultSource = "",
            CopyTarget = "",
            Payload = JoinFrom(parts, 3)
        };
    }

    static Message ReadResult(string[] parts)
    {
        return new Message
        {
            Kind = Kind.Result,
            Source = "",
            TextSource = "",
            ResultSource = ReadToken(parts, 2),
            CopyTarget = "",
            Payload = JoinFrom(parts, 3)
        };
    }

    static Message ReadCopy(string[] parts)
    {
        return new Message
        {
            Kind = Kind.Copy,
            Source = "",
            TextSource = "",
            ResultSource = "",
            CopyTarget = ReadToken(parts, 2),
            Payload = ""
        };
    }

    static int ReadInt(string[] parts, int index)
    {
        if (index >= parts.Length)
            return 0;
        string token = parts[index].Trim();
        if (token.Length == 0)
            return 0;
        return int.TryParse(token, out int value) ? value : 0;
    }

    static string ReadToken(string[] parts, int index)
    {
        if (index >= parts.Length)
            return "";
        return parts[index].Trim();
    }

    static string JoinFrom(string[] parts, int index)
    {
        if (index >= parts.Length)
            return "";
        return string.Join("|", parts[index..]);
    }

    static bool ReadPin(string token)
    {
        string value = token.Trim().ToLowerInvariant();
        return value is not ("0" or "false" or "off" or "unpin" or "no");
    }

    static bool Match(string text, Kind kind, int x = 0, int y = 0, int dpi = 0, string source = "")
    {
        Message message = Parse(text);
        return message.Kind == kind
            && message.X == x
            && message.Y == y
            && message.Dpi == dpi
            && message.Source == source;
    }

    static bool MatchPin(string text, bool pin)
    {
        Message message = Parse(text);
        return message.Kind == Kind.Pin && message.Pin == pin;
    }

    static bool MatchText(string text, string textSource, string payload)
    {
        Message message = Parse(text);
        return message.Kind == Kind.Text
            && message.TextSource == textSource
            && message.Payload == payload;
    }

    static bool MatchResult(string text, string resultSource, string payload)
    {
        Message message = Parse(text);
        return message.Kind == Kind.Result
            && message.ResultSource == resultSource
            && message.Payload == payload;
    }

    static bool MatchCopy(string text, string copyTarget)
    {
        Message message = Parse(text);
        return message.Kind == Kind.Copy && message.CopyTarget == copyTarget;
    }
}
