namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 翻译原文来源。策略可替换，和定位层分开。
///
/// 优先级：
/// 1. 调用方显式传入的文本
/// 2. 调用方明确要求时才读剪贴板
/// 3. 空占位
///
/// 不抓鼠标下文本，不抓当前选区 / UIA，不接翻译后端。
/// 剪贴板必须调用方声明，不能在 OPEN 时偷偷读。
/// </summary>
internal static class TranslationSource
{
    public enum Kind
    {
        Empty,
        Explicit,
        Clipboard
    }

    public const int MaxChars = 4000;

    public readonly struct Result
    {
        public Kind Kind { get; init; }
        public string Text { get; init; }
        public bool Ok { get; init; }
        public int CharCount => Text.Length;
        public string SourceToken => Token(Kind);

        public string DisplayText
        {
            get
            {
                if (Ok && Text.Length > 0)
                    return Text;
                return Kind switch
                {
                    Kind.Clipboard => "剪贴板为空",
                    _ => "暂无原文"
                };
            }
        }
    }

    public static Result Resolve(string? requestedSource, string? payload, IntPtr clipboardOwner)
    {
        Kind kind = ParseKind(requestedSource) ?? InferKind(payload);
        switch (kind)
        {
            case Kind.Explicit:
                return FromExplicit(payload);
            case Kind.Clipboard:
                return FromClipboard(clipboardOwner);
            default:
                return Empty();
        }
    }

    public static Result Empty()
    {
        return new Result { Kind = Kind.Empty, Text = "", Ok = false };
    }

    public static Result FromExplicit(string? payload)
    {
        string text = Normalize(payload);
        bool ok = text.Length > 0;
        return new Result
        {
            Kind = Kind.Explicit,
            Text = text,
            Ok = ok
        };
    }

    public static Result FromClipboard(IntPtr owner)
    {
        string? raw = Native.TryReadClipboardUnicode(owner, MaxChars);
        string text = Normalize(raw);
        HudLog.Line("translation-source=clipboard ok=" + (text.Length > 0)
            + " chars=" + text.Length
            + " truncated=" + (raw != null && raw.Length >= MaxChars));
        return new Result
        {
            Kind = Kind.Clipboard,
            Text = text,
            Ok = text.Length > 0
        };
    }

    public static Kind? ParseKind(string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return null;
        return token.Trim().ToLowerInvariant() switch
        {
            "explicit" or "text" or "payload" => Kind.Explicit,
            "clipboard" or "clip" or "paste" => Kind.Clipboard,
            "empty" or "none" or "placeholder" => Kind.Empty,
            _ => null
        };
    }

    public static string Token(Kind kind) => kind switch
    {
        Kind.Explicit => "explicit",
        Kind.Clipboard => "clipboard",
        _ => "empty"
    };

    public static int SelfTest()
    {
        if (ParseKind("clipboard") != Kind.Clipboard)
            return 301;
        if (ParseKind("explicit") != Kind.Explicit)
            return 302;
        if (ParseKind("empty") != Kind.Empty)
            return 303;
        if (ParseKind("mouse") != null)
            return 304;

        Result explicitText = FromExplicit("  hello  ");
        if (!explicitText.Ok || explicitText.Text != "hello" || explicitText.SourceToken != "explicit")
            return 305;

        Result pipes = FromExplicit("a|b");
        if (pipes.Text != "a|b")
            return 306;

        Result emptyPayload = FromExplicit("   ");
        if (emptyPayload.Ok || emptyPayload.Kind != Kind.Explicit)
            return 307;

        Result empty = Empty();
        if (empty.Ok || empty.SourceToken != "empty")
            return 308;
        if (empty.DisplayText != "暂无原文")
            return 309;

        // OPEN 未声明文本来源时绝不能伪装成剪贴板。
        Result inferred = Resolve("", "", IntPtr.Zero);
        if (inferred.Kind != Kind.Empty)
            return 310;
        return 0;
    }

    static Kind InferKind(string? payload)
    {
        return string.IsNullOrWhiteSpace(payload) ? Kind.Empty : Kind.Explicit;
    }

    static string Normalize(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return "";
        string trimmed = text.Replace("\0", "").Trim();
        if (trimmed.Length <= MaxChars)
            return trimmed;
        return trimmed[..MaxChars];
    }
}
