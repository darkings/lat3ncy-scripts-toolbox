namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 翻译面板失焦关闭策略。和定位 / 原文 / 译文分开，可测。
///
/// 未钉住 + 面板可见 + 前台落到面板树以外 → 关闭。
/// 钉住、已经隐藏、前台未知、前台仍是面板 / Island 子窗口 → 保持。
/// OPEN 用 ShowNoActivate，打开瞬间前台仍是编辑器；
/// 不要在 Show 当时用「前台不是我」去关，只在后续前台变化 / WM_ACTIVATE 里判断。
///
/// 同一窗口里点别处通常不换前台 HWND。那种点击走外面点击策略：
/// 未钉住 + 可见 + 点不在面板矩形 / 子窗口上 → 关闭。
/// </summary>
internal static class TranslationPanelDismiss
{
    public static bool ShouldHide(
        bool visible,
        bool pinned,
        bool foregroundKnown,
        bool foregroundBelongsToPanel)
    {
        if (!visible || pinned)
            return false;
        if (!foregroundKnown)
            return false;
        return !foregroundBelongsToPanel;
    }

    public static bool ShouldHideOnOutsideClick(
        bool visible,
        bool pinned,
        bool pointHitsPanel)
    {
        if (!visible || pinned)
            return false;
        return !pointHitsPanel;
    }

    public static int SelfTest()
    {
        // 隐藏着的面板不重复关。
        if (ShouldHide(visible: false, pinned: false, foregroundKnown: true, foregroundBelongsToPanel: false))
            return 601;
        // 钉住后点到别的窗口也要留着。
        if (ShouldHide(visible: true, pinned: true, foregroundKnown: true, foregroundBelongsToPanel: false))
            return 602;
        // 前台仍是面板或 Island 子窗口，不能关。
        if (ShouldHide(visible: true, pinned: false, foregroundKnown: true, foregroundBelongsToPanel: true))
            return 603;
        // 未钉住、前台切到无关窗口，必须关。
        if (!ShouldHide(visible: true, pinned: false, foregroundKnown: true, foregroundBelongsToPanel: false))
            return 604;
        // 钉住且自己仍前台，保持。
        if (ShouldHide(visible: true, pinned: true, foregroundKnown: true, foregroundBelongsToPanel: true))
            return 605;
        // 前台 HWND 未知时不要误关，避免 OPEN / 销毁途中抖一下。
        if (ShouldHide(visible: true, pinned: false, foregroundKnown: false, foregroundBelongsToPanel: false))
            return 606;
        // 隐藏着的面板不因点击再关一次。
        if (ShouldHideOnOutsideClick(visible: false, pinned: false, pointHitsPanel: false))
            return 607;
        // 钉住后点到同一窗口别处也要留着。
        if (ShouldHideOnOutsideClick(visible: true, pinned: true, pointHitsPanel: false))
            return 608;
        // 点在面板 / 按钮 / Island 上不能关。
        if (ShouldHideOnOutsideClick(visible: true, pinned: false, pointHitsPanel: true))
            return 609;
        // 未钉住、点在面板外（包括原编辑器客户区），必须关。
        if (!ShouldHideOnOutsideClick(visible: true, pinned: false, pointHitsPanel: false))
            return 610;
        return 0;
    }
}
