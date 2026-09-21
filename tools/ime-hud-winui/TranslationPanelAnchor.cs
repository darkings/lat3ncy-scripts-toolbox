namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 翻译面板定位策略。结果始终是屏幕物理像素。
///
/// 优先级：
/// 1. 钉住后记住的窗口矩形（进程内，不写盘）
/// 2. 调用方显式传入的点（ExplicitPoint / MouseAtHotkey，后者必须带坐标）
/// 3. 当前 caret / IMM 组词窗口
/// 4. 活动窗口底部
/// 5. 当前屏幕工作区中心
///
/// 快捷键按下时的鼠标未知。这里绝不把 GetCursorPos 的“现在”伪装成 MouseAtHotkey。
/// remembered 只由 RestorePinned 产出，协议不能伪装成这种来源。
/// </summary>
internal static class TranslationPanelAnchor
{
    public enum Source
    {
        ExplicitPoint,
        MouseAtHotkey,
        Caret,
        ActiveWindow,
        ScreenFallback,
        Remembered
    }

    public readonly struct Result
    {
        public int AnchorX { get; init; }
        public int AnchorY { get; init; }
        public int X { get; init; }
        public int Y { get; init; }
        public int Width { get; init; }
        public int Height { get; init; }
        public int Dpi { get; init; }
        public int Gap { get; init; }
        public int RawX { get; init; }
        public int RawY { get; init; }
        public bool Clamped { get; init; }
        public Native.RECT WorkArea { get; init; }
        public Source Source { get; init; }
        public bool Reliable { get; init; }
        public bool AllowRelocate { get; init; }

        public string SourceToken => Token(Source);
    }

    const double WidthDip = 360;
    const double HeightDip = 240;
    const double GapDip = 12;
    const int MarginPx = 8;

    public static Result Resolve(
        int hintX,
        int hintY,
        int hintDpi,
        string? requestedSource,
        bool allowRelocate)
    {
        Source? requested = ParseSource(requestedSource);
        bool hasPoint = hintX != 0 || hintY != 0;

        // 有坐标才算调用方给了锚点。没坐标的 mouse-at-hotkey 直接作废。
        if (hasPoint)
        {
            Source source = requested == Source.MouseAtHotkey
                ? Source.MouseAtHotkey
                : Source.ExplicitPoint;
            return Place(hintX, hintY, hintDpi, source, reliable: true, allowRelocate);
        }

        if (requested == Source.MouseAtHotkey)
        {
            HudLog.Line("translation-anchor mouse-at-hotkey missing; not reading live cursor");
        }

        if (requested == Source.ScreenFallback)
            return ScreenFallback(hintDpi, allowRelocate);

        if (requested != Source.ActiveWindow)
        {
            Anchor.Result caret = Anchor.Locate(0, 0);
            if (caret.Ok && IsCaretSource(caret.Source))
                return Place(caret.X, caret.Y, hintDpi, Source.Caret, reliable: true, allowRelocate);
            if (caret.Ok)
                return Place(caret.X, caret.Y, hintDpi, Source.ActiveWindow, reliable: false, allowRelocate);
        }

        Anchor.Result window = LocateActiveWindow();
        if (window.Ok)
            return Place(window.X, window.Y, hintDpi, Source.ActiveWindow, reliable: false, allowRelocate);

        return ScreenFallback(hintDpi, allowRelocate);
    }

    /// <summary>
    /// 钉住后恢复上次矩形。工作区不够时只夹紧，不改尺寸。
    /// 协议里的 remembered 不走这里，避免调用方伪装钉住位置。
    /// </summary>
    public static Result RestorePinned(int x, int y, int width, int height, int dpi)
    {
        if (width <= 0)
            width = Native.DipToPx(WidthDip, dpi > 0 ? dpi : Native.GetSystemDpi());
        if (height <= 0)
            height = Native.DipToPx(HeightDip, dpi > 0 ? dpi : Native.GetSystemDpi());

        Native.RECT work = Native.GetWorkAreaFromPoint(x, y);
        ClampResult clamped = ClampToWorkArea(x, y, width, height, work);

        int gap = Native.DipToPx(GapDip, dpi > 0 ? dpi : Native.GetSystemDpi());
        return new Result
        {
            AnchorX = x,
            AnchorY = y,
            X = clamped.X,
            Y = clamped.Y,
            Width = width,
            Height = height,
            Dpi = dpi > 0 ? dpi : Native.GetDpiForPoint(clamped.X, clamped.Y),
            Gap = gap,
            RawX = x,
            RawY = y,
            Clamped = clamped.Moved,
            WorkArea = work,
            Source = Source.Remembered,
            Reliable = true,
            AllowRelocate = false
        };
    }

    public static int SelfTest()
    {
        Result explicitPoint = Resolve(120, 240, 96, "explicit", allowRelocate: true);
        if (explicitPoint.Source != Source.ExplicitPoint || !explicitPoint.Reliable)
            return 201;

        Result mouse = Resolve(10, 20, 144, "mouse-at-hotkey", allowRelocate: true);
        if (mouse.Source != Source.MouseAtHotkey || !mouse.Reliable)
            return 202;

        // 没有坐标时禁止退化成“当前鼠标就是热键鼠标”。
        Result missingMouse = Resolve(0, 0, 0, "mouse-at-hotkey", allowRelocate: true);
        if (missingMouse.Source == Source.MouseAtHotkey)
            return 203;

        Result screen = Resolve(0, 0, 96, "screen-fallback", allowRelocate: false);
        if (screen.Source != Source.ScreenFallback || screen.Reliable || screen.AllowRelocate)
            return 204;

        if (ParseSource("explicit") != Source.ExplicitPoint)
            return 205;
        if (ParseSource("mouse-at-hotkey") != Source.MouseAtHotkey)
            return 206;
        if (ParseSource("caret") != Source.Caret)
            return 207;
        if (ParseSource("active-window") != Source.ActiveWindow)
            return 208;
        if (ParseSource("nope") != null)
            return 209;
        // 协议不能把 remembered 伪装成定位来源。
        if (ParseSource("remembered") != null)
            return 210;
        if (ParseSource("pinned") != null)
            return 211;

        Result remembered = RestorePinned(120, 240, 450, 300, 120);
        if (remembered.Source != Source.Remembered
            || remembered.AllowRelocate
            || remembered.X != 120
            || remembered.Y != 240
            || remembered.Width != 450
            || remembered.Height != 300
            || remembered.RawX != 120
            || remembered.RawY != 240
            || Token(remembered.Source) != "remembered")
        {
            return 212;
        }

        // 钳位自检用固定工作区，不读当前屏幕，避免多显示器把坐标测飘。
        var work = new Native.RECT { Left = 0, Top = 0, Right = 1000, Bottom = 800 };
        ClampResult inside = ClampToWorkArea(120, 240, 450, 300, work);
        if (inside.Moved || inside.X != 120 || inside.Y != 240)
            return 213;
        ClampResult bottomRight = ClampToWorkArea(900, 700, 450, 300, work);
        if (!bottomRight.Moved || bottomRight.X != 542 || bottomRight.Y != 492)
            return 214;
        ClampResult topLeft = ClampToWorkArea(-20, -20, 450, 300, work);
        if (!topLeft.Moved || topLeft.X != MarginPx || topLeft.Y != MarginPx)
            return 215;
        return 0;
    }

    public static string Token(Source source) => source switch
    {
        Source.ExplicitPoint => "explicit",
        Source.MouseAtHotkey => "mouse-at-hotkey",
        Source.Caret => "caret",
        Source.ActiveWindow => "active-window",
        Source.Remembered => "remembered",
        _ => "screen-fallback"
    };

    public static Source? ParseSource(string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return null;
        return token.Trim().ToLowerInvariant() switch
        {
            "explicit" or "explicit-point" or "point" or "hint" => Source.ExplicitPoint,
            "mouse" or "mouse-at-hotkey" or "hotkey-mouse" => Source.MouseAtHotkey,
            "caret" or "tsf-imm" or "win32-caret" => Source.Caret,
            "window" or "active-window" or "window-bottom" => Source.ActiveWindow,
            "screen" or "screen-fallback" or "fallback" => Source.ScreenFallback,
            _ => null
        };
    }

    static Result Place(
        int anchorX,
        int anchorY,
        int hintDpi,
        Source source,
        bool reliable,
        bool allowRelocate)
    {
        int dpi = hintDpi > 0 ? hintDpi : Native.GetDpiForPoint(anchorX, anchorY);
        if (dpi <= 0)
            dpi = Native.GetSystemDpi();

        int width = Native.DipToPx(WidthDip, dpi);
        int height = Native.DipToPx(HeightDip, dpi);
        int gap = Native.DipToPx(GapDip, dpi);
        Native.RECT work = Native.GetWorkAreaFromPoint(anchorX, anchorY);

        int x;
        int y;
        switch (source)
        {
            case Source.ScreenFallback:
                x = work.Left + Math.Max(0, (work.Width - width) / 2);
                y = work.Top + Math.Max(0, (work.Height - height) / 2);
                break;
            case Source.ActiveWindow:
                x = anchorX - width / 2;
                y = anchorY + gap;
                break;
            case Source.Caret:
                x = anchorX;
                y = anchorY + gap;
                break;
            default:
                // 显式点 / 热键鼠标：往右下让开锚点，避免盖住光标或选区。
                x = anchorX + gap;
                y = anchorY + gap;
                break;
        }

        int rawX = x;
        int rawY = y;
        ClampResult clamped = ClampToWorkArea(x, y, width, height, work);

        return new Result
        {
            AnchorX = anchorX,
            AnchorY = anchorY,
            X = clamped.X,
            Y = clamped.Y,
            Width = width,
            Height = height,
            Dpi = dpi,
            Gap = gap,
            RawX = rawX,
            RawY = rawY,
            Clamped = clamped.Moved,
            WorkArea = work,
            Source = source,
            Reliable = reliable,
            AllowRelocate = allowRelocate
        };
    }

    static Result ScreenFallback(int hintDpi, bool allowRelocate)
    {
        Native.RECT work = WorkAreaFromForegroundOrPrimary();
        int anchorX = work.Left + work.Width / 2;
        int anchorY = work.Top + work.Height / 2;
        return Place(anchorX, anchorY, hintDpi, Source.ScreenFallback, reliable: false, allowRelocate);
    }

    static Native.RECT WorkAreaFromForegroundOrPrimary()
    {
        IntPtr hwnd = Native.GetForegroundWindow();
        if (hwnd != IntPtr.Zero && Native.GetWindowRect(hwnd, out Native.RECT rc))
            return Native.GetWorkAreaFromPoint(rc.Left + rc.Width / 2, rc.Top + rc.Height / 2);
        return Native.GetPrimaryWorkArea();
    }

    static Anchor.Result LocateActiveWindow()
    {
        IntPtr hwnd = Native.GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
            return default;
        if (!Native.GetWindowRect(hwnd, out Native.RECT rc))
            return default;
        if (rc.Width < 50 || rc.Height < 50)
            return default;
        return new Anchor.Result
        {
            X = rc.Left + rc.Width / 2,
            Y = rc.Top + (int)(rc.Height * 0.85),
            Height = 0,
            Source = "window-bottom"
        };
    }

    static bool IsCaretSource(string source) =>
        source is "tsf-imm" or "win32-caret" or "caret";

    readonly struct ClampResult
    {
        public int X { get; init; }
        public int Y { get; init; }
        public bool Moved { get; init; }
    }

    /// <summary>
    /// 只夹进工作区，不改宽高。工作区比面板还小时钉在左上 margin。
    /// </summary>
    static ClampResult ClampToWorkArea(int x, int y, int width, int height, Native.RECT work)
    {
        int rawX = x;
        int rawY = y;
        int maxX = work.Right - MarginPx - width;
        int maxY = work.Bottom - MarginPx - height;
        int minX = work.Left + MarginPx;
        int minY = work.Top + MarginPx;
        if (maxX < minX)
            maxX = minX;
        if (maxY < minY)
            maxY = minY;
        if (x > maxX)
            x = maxX;
        if (y > maxY)
            y = maxY;
        if (x < minX)
            x = minX;
        if (y < minY)
            y = minY;
        return new ClampResult
        {
            X = x,
            Y = y,
            Moved = x != rawX || y != rawY
        };
    }
}
