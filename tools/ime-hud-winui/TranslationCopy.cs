namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 翻译面板剪贴板写出策略。和原文 / 译文分开，可替换。
///
/// 只在调用方明确要求时写入：
/// 1. source：复制当前原文
/// 2. result：复制当前译文
///
/// 不复制占位文案，OPEN / TEXT / RESULT 不会偷偷写剪贴板。
/// 空原文 / 空译文直接拒绝，避免冲掉用户已有内容。
/// 不接翻译后端，不读选区。
/// </summary>
internal static class TranslationCopy
{
    public enum Target
    {
        None,
        Source,
        Result
    }

    public readonly struct Outcome
    {
        public Target Target { get; init; }
        public string Text { get; init; }
        public bool Ok { get; init; }
        public string Reason { get; init; }
        public int CharCount => Text.Length;
        public string TargetToken => Token(Target);
    }

    public static Outcome Resolve(
        string? requestedTarget,
        TranslationSource.Result source,
        TranslationResult.Result result)
    {
        Target target = ParseTarget(requestedTarget) ?? Target.None;
        return target switch
        {
            Target.Source => From(source.Ok, source.Text, Target.Source),
            Target.Result => From(result.Ok, result.Text, Target.Result),
            _ => Fail(Target.None, "unspecified")
        };
    }

    public static Target? ParseTarget(string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return null;
        return token.Trim().ToLowerInvariant() switch
        {
            "source" or "text" or "original" or "src" => Target.Source,
            "result" or "translation" or "dst" or "output" => Target.Result,
            _ => null
        };
    }

    public static string Token(Target target) => target switch
    {
        Target.Source => "source",
        Target.Result => "result",
        _ => "none"
    };

    public static int SelfTest()
    {
        if (ParseTarget("source") != Target.Source)
            return 501;
        if (ParseTarget("result") != Target.Result)
            return 502;
        if (ParseTarget("original") != Target.Source)
            return 503;
        if (ParseTarget("translation") != Target.Result)
            return 504;
        // 剪贴板不是写出目标。没声明目标时也不能默认写译文。
        if (ParseTarget("clipboard") != null)
            return 505;
        if (ParseTarget("") != null)
            return 506;

        TranslationSource.Result emptySource = TranslationSource.Empty();
        TranslationResult.Result emptyResult = TranslationResult.Empty();
        Outcome unspecified = Resolve("", emptySource, emptyResult);
        if (unspecified.Ok || unspecified.Target != Target.None || unspecified.Reason != "unspecified")
            return 507;

        Outcome emptyCopy = Resolve("source", emptySource, emptyResult);
        if (emptyCopy.Ok || emptyCopy.Reason != "empty")
            return 508;

        TranslationSource.Result hello = TranslationSource.FromExplicit("hello world");
        TranslationResult.Result nihao = TranslationResult.FromExplicit("你好世界");
        Outcome sourceOk = Resolve("source", hello, nihao);
        if (!sourceOk.Ok || sourceOk.Text != "hello world" || sourceOk.TargetToken != "source")
            return 509;
        Outcome resultOk = Resolve("result", hello, nihao);
        if (!resultOk.Ok || resultOk.Text != "你好世界" || resultOk.CharCount != 4)
            return 510;

        Outcome placeholder = From(true, "暂无译文", Target.Result);
        if (placeholder.Ok || placeholder.Reason != "placeholder")
            return 511;

        Outcome sourcePlaceholder = From(true, "暂无原文", Target.Source);
        if (sourcePlaceholder.Ok || sourcePlaceholder.Reason != "placeholder")
            return 512;

        Outcome clipboardPlaceholder = From(true, "剪贴板为空", Target.Source);
        if (clipboardPlaceholder.Ok || clipboardPlaceholder.Reason != "placeholder")
            return 513;
        return 0;
    }

    static Outcome From(bool ok, string text, Target target)
    {
        if (!ok || string.IsNullOrEmpty(text))
            return Fail(target, "empty");
        if (LooksLikePlaceholder(text))
            return Fail(target, "placeholder");
        return new Outcome
        {
            Target = target,
            Text = text,
            Ok = true,
            Reason = "ok"
        };
    }

    static Outcome Fail(Target target, string reason)
    {
        return new Outcome
        {
            Target = target,
            Text = "",
            Ok = false,
            Reason = reason
        };
    }

    static bool LooksLikePlaceholder(string text)
    {
        return text is "暂无原文" or "暂无译文" or "剪贴板为空";
    }
}
