namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 译文结果策略。和原文来源分开，可替换。
///
/// 优先级：
/// 1. 调用方显式传入的译文
/// 2. 空占位（未接翻译后端）
///
/// 不调用任何翻译服务，不把原文拷贝成译文，不读剪贴板当译文。
/// 换原文时由面板把译文打回 Empty，避免旧译文看起来像已经译完。
/// </summary>
internal static class TranslationResult
{
    public enum Kind
    {
        Empty,
        Explicit
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
                return "暂无译文";
            }
        }
    }

    public static Result Resolve(string? requestedSource, string? payload)
    {
        Kind kind = ParseKind(requestedSource) ?? InferKind(payload);
        return kind == Kind.Explicit ? FromExplicit(payload) : Empty();
    }

    public static Result Empty()
    {
        return new Result { Kind = Kind.Empty, Text = "", Ok = false };
    }

    public static Result FromExplicit(string? payload)
    {
        string text = Normalize(payload);
        return new Result
        {
            Kind = Kind.Explicit,
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
            "empty" or "none" or "placeholder" or "pending" => Kind.Empty,
            _ => null
        };
    }

    public static string Token(Kind kind) => kind switch
    {
        Kind.Explicit => "explicit",
        _ => "empty"
    };

    public static int SelfTest()
    {
        if (ParseKind("explicit") != Kind.Explicit)
            return 401;
        if (ParseKind("empty") != Kind.Empty)
            return 402;
        if (ParseKind("pending") != Kind.Empty)
            return 403;
        // 没有后端种类。clipboard / deepl 都不能伪装成译文来源。
        if (ParseKind("clipboard") != null)
            return 404;
        if (ParseKind("deepl") != null)
            return 405;

        Result explicitText = FromExplicit("  hello  ");
        if (!explicitText.Ok || explicitText.Text != "hello" || explicitText.SourceToken != "explicit")
            return 406;

        Result pipes = FromExplicit("a|b");
        if (pipes.Text != "a|b")
            return 407;

        Result emptyPayload = FromExplicit("   ");
        if (emptyPayload.Ok || emptyPayload.Kind != Kind.Explicit)
            return 408;

        Result empty = Empty();
        if (empty.Ok || empty.SourceToken != "empty")
            return 409;
        if (empty.DisplayText != "暂无译文")
            return 410;

        Result inferred = Resolve("", "");
        if (inferred.Kind != Kind.Empty)
            return 411;

        Result inferredPayload = Resolve("", "你好");
        if (!inferredPayload.Ok || inferredPayload.Kind != Kind.Explicit || inferredPayload.Text != "你好")
            return 412;
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
