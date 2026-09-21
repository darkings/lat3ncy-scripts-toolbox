using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Windows.Graphics;
using Windows.UI.ViewManagement;
using WinRT.Interop;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 翻译面板独立顶层宿主。不能复用 HudHost：芯片是 NOACTIVATE + 点穿，面板要能点、能钉、能输入。
/// HWND 独立，不塞进 32×32 IME 芯片。Acrylic.Default，宿主 DWM ROUNDSMALL，不用 SetWindowRgn，不用 Thin。
/// </summary>
internal sealed class TranslationPanelHost : IDisposable
{
    public const string ClassName = "Lat3ncyImeHudWinUiPanel";
    public const string WindowTitle = "Lat3ncyImeHudWinUiPanel";

    readonly Native.WndProc _wndProc;
    readonly GCHandle _wndProcPin;
    readonly Native.WinEventDelegate _winEventProc;
    readonly GCHandle _winEventPin;
    readonly Native.HookProc _mouseHookProc;
    readonly GCHandle _mouseHookPin;
    readonly DispatcherQueue _dispatcher;
    readonly IntPtr _hwnd;
    readonly DesktopWindowXamlSource _xamlSource;
    readonly TranslationPanel _content;
    readonly UISettings _uiSettings;
    readonly HashSet<long> _islandSiteLogged = [];

    IslandSystemBackdrop? _islandBackdrop;
    TranslationSource.Result _source = TranslationSource.Empty();
    TranslationResult.Result _result = TranslationResult.Empty();
    IntPtr _foregroundHook;
    IntPtr _mouseHook;
    IntPtr _openForeground;
    int _dismissEpoch;
    bool _visible;
    bool _pinned;
    Native.RECT _pinnedRect;
    bool _hasPinnedRect;
    bool _backdropApplied;
    bool _closing;
    bool _disposed;

    public IntPtr Handle => _hwnd;
    public bool IsVisible => _visible;
    public bool IsPinned => _pinned;

    bool ShouldApplyIslandBackdrop =>
        Native.TransparencyEnabled() && !Native.HighContrastEnabled();

    int HostBackdrop =>
        ShouldApplyIslandBackdrop
            ? Native.DWMSBT_NONE
            : Native.DWMSBT_TRANSIENTWINDOW;

    public TranslationPanelHost()
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("当前线程没有 DispatcherQueue");
        _wndProc = WndProc;
        _wndProcPin = GCHandle.Alloc(_wndProc);
        // EVENT_SYSTEM_FOREGROUND 回调在钩子线程，委托必须钉住。
        _winEventProc = OnWinEvent;
        _winEventPin = GCHandle.Alloc(_winEventProc);
        // 同一窗口里点别处不换前台。WH_MOUSE_LL 用来抓面板外的按下。
        _mouseHookProc = OnMouseHook;
        _mouseHookPin = GCHandle.Alloc(_mouseHookProc);

        RegisterClass();
        HudLog.Line("translation-class-ok");
        _hwnd = CreatePopup();
        if (_hwnd == IntPtr.Zero)
            throw new InvalidOperationException("翻译面板 CreateWindowExW 失败: " + Marshal.GetLastWin32Error());
        HudLog.Line("translation-create-hwnd=" + _hwnd.ToInt64());

        ApplyHostChrome();
        HudLog.Line("translation-dwm-ok dark=" + Native.AppsUseDarkMode()
            + " transparency=" + Native.TransparencyEnabled()
            + " high-contrast=" + Native.HighContrastEnabled()
            + " host-backdrop=" + HostBackdrop
            + " noactivate=False hit-transparent=False");

        _xamlSource = new DesktopWindowXamlSource();
        _xamlSource.Initialize(Win32Interop.GetWindowIdFromWindow(_hwnd));
        HudApp.TryEnsureControlsResources("after-panel-island");

        _content = new TranslationPanel();
        _content.SetRequestedTheme(Native.AppsUseDarkMode());
        _content.PinChanged += OnPinChanged;
        _content.CloseRequested += (_, _) => Hide();
        _content.CopyRequested += (_, target) => Copy(target);
        _content.DragRequested += (_, _) => BeginCaptionDrag();
        _xamlSource.Content = _content.Root;
        ResizeIsland();

        _uiSettings = new UISettings();
        _uiSettings.ColorValuesChanged += OnColorValuesChanged;

        Native.HideNoActivate(_hwnd);
        HudLog.Line("translation-host-hidden dpi=" + Native.GetDpiForWindow(_hwnd));
        RegisterForegroundListener();
        RegisterOutsideClickListener();
        _content.Root.Loaded += OnContentLoadedForBackdrop;
    }

    public void Dispatch(TranslationPanelProtocol.Message message)
    {
        switch (message.Kind)
        {
            case TranslationPanelProtocol.Kind.Open:
                Open(message);
                break;
            case TranslationPanelProtocol.Kind.Move:
                Move(message.X, message.Y, message.Dpi, message.Source);
                break;
            case TranslationPanelProtocol.Kind.Text:
                ApplySource(message.TextSource, message.Payload);
                break;
            case TranslationPanelProtocol.Kind.Result:
                ApplyResult(message.ResultSource, message.Payload);
                break;
            case TranslationPanelProtocol.Kind.Copy:
                Copy(message.CopyTarget);
                break;
            case TranslationPanelProtocol.Kind.Close:
                Hide();
                break;
            case TranslationPanelProtocol.Kind.Pin:
                SetPinned(message.Pin);
                break;
            case TranslationPanelProtocol.Kind.Ping:
                HudLog.Line("translation-ping visible=" + _visible
                    + " pinned=" + _pinned
                    + " hwnd=" + _hwnd.ToInt64());
                break;
        }
    }

    public void SyncThemeFromSystem(string reason)
    {
        if (_closing || _disposed)
            return;

        bool dark = Native.AppsUseDarkMode();
        HudLog.Line("translation-theme-sync reason=" + reason
            + " dark=" + dark
            + " transparency=" + Native.TransparencyEnabled()
            + " high-contrast=" + Native.HighContrastEnabled());
        _content.SetRequestedTheme(dark);
        _islandBackdrop?.SyncTheme(dark);
        SyncIslandBackdropWithTransparency();
        ApplyHostChrome(dark);
        ResizeIsland();
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _closing = true;
        // 先卸钩，避免回调摸已销毁宿主。在途回调靠 _disposed / epoch 再挡一层。
        UnregisterForegroundListener();
        UnregisterOutsideClickListener();
        try { _uiSettings.ColorValuesChanged -= OnColorValuesChanged; } catch { }
        try { _content.PinChanged -= OnPinChanged; } catch { }
        DetachIsland("panel-dispose");
        if (Native.IsWindow(_hwnd))
            Native.DestroyWindow(_hwnd);
        if (_wndProcPin.IsAllocated)
            _wndProcPin.Free();
        if (_winEventPin.IsAllocated)
            _winEventPin.Free();
        if (_mouseHookPin.IsAllocated)
            _mouseHookPin.Free();
        HudLog.Line("translation-host-disposed");
    }

    void Open(TranslationPanelProtocol.Message message)
    {
        if (_pinned && _hasPinnedRect)
        {
            // 钉住期间 OPEN 只恢复记住的矩形，不跟 caret / 显式点重放。
            int windowDpi = (int)Native.GetDpiForWindow(_hwnd);
            TranslationPanelAnchor.Result remembered = TranslationPanelAnchor.RestorePinned(
                _pinnedRect.Left,
                _pinnedRect.Top,
                _pinnedRect.Width,
                _pinnedRect.Height,
                windowDpi);
            ApplyPlacement(remembered);
        }
        else
        {
            TranslationPanelAnchor.Result place = TranslationPanelAnchor.Resolve(
                message.X,
                message.Y,
                message.Dpi,
                message.Source,
                allowRelocate: true);
            ApplyPlacement(place);
        }

        ApplySource(message.TextSource, message.Payload);
        ShowPanel();
    }

    void ApplySource(string textSource, string payload)
    {
        TranslationSource.Result source = TranslationSource.Resolve(textSource, payload, _hwnd);
        // 换原文时默认打回 Empty 译文，不能沿用上一次 RESULT。
        _source = source;
        _result = TranslationResult.Empty();
        _content.SetSource(source);
        HudLog.Line("translation-text source=" + source.SourceToken
            + " ok=" + source.Ok
            + " chars=" + source.CharCount
            + " requested=" + (textSource ?? ""));
        HudLog.Line("translation-result source=empty ok=False chars=0 requested=reset-on-text");
    }

    void ApplyResult(string resultSource, string payload)
    {
        TranslationResult.Result result = TranslationResult.Resolve(resultSource, payload);
        _result = result;
        _content.SetResult(result);
        HudLog.Line("translation-result source=" + result.SourceToken
            + " ok=" + result.Ok
            + " chars=" + result.CharCount
            + " requested=" + (resultSource ?? ""));
    }

    void Copy(string requestedTarget)
    {
        TranslationCopy.Outcome copy = TranslationCopy.Resolve(requestedTarget, _source, _result);
        if (!copy.Ok)
        {
            HudLog.Line("translation-copy skipped target=" + copy.TargetToken
                + " requested=" + (requestedTarget ?? "")
                + " reason=" + copy.Reason
                + " source-ok=" + _source.Ok
                + " result-ok=" + _result.Ok);
            return;
        }

        bool written = Native.TryWriteClipboardUnicode(_hwnd, copy.Text);
        HudLog.Line("translation-copy target=" + copy.TargetToken
            + " ok=" + written
            + " chars=" + copy.CharCount
            + " requested=" + (requestedTarget ?? ""));
    }

    void Move(int hintX, int hintY, int hintDpi, string requestedSource)
    {
        if (_pinned)
        {
            HudLog.Line("translation-move skipped pinned=True");
            return;
        }

        TranslationPanelAnchor.Result place = TranslationPanelAnchor.Resolve(
            hintX,
            hintY,
            hintDpi,
            requestedSource,
            allowRelocate: true);
        ApplyPlacement(place);
        if (_visible)
            ShowPanel();
    }

    void Hide()
    {
        // 隐藏后旧的前台回调全部作废，避免 ShowNoActivate 的编辑器快照把新一轮面板关掉。
        Interlocked.Increment(ref _dismissEpoch);
        _openForeground = IntPtr.Zero;
        if (_pinned)
            RememberCurrentRectIfPinned();
        Native.HideNoActivate(_hwnd);
        _visible = false;
        HudLog.Line("translation-hide pinned=" + _pinned
            + " remembered=" + _hasPinnedRect
            + " rect=" + DescribePinnedRect());
    }

    void SetPinned(bool pinned)
    {
        _pinned = pinned;
        _content.SetPinned(pinned);
        RememberCurrentRectIfPinned();
        HudLog.Line("translation-pin=" + pinned
            + " remembered=" + _hasPinnedRect
            + " rect=" + DescribePinnedRect());
    }

    void OnPinChanged(object? sender, EventArgs e)
    {
        _pinned = _content.IsPinned;
        RememberCurrentRectIfPinned();
        HudLog.Line("translation-pin=" + _pinned
            + " from=ui remembered=" + _hasPinnedRect
            + " rect=" + DescribePinnedRect());
    }

    void RememberCurrentRectIfPinned()
    {
        if (!_pinned)
        {
            _hasPinnedRect = false;
            _pinnedRect = default;
            return;
        }

        if (!Native.GetWindowRect(_hwnd, out Native.RECT rect))
            return;
        if (rect.Width <= 0 || rect.Height <= 0)
            return;
        _pinnedRect = rect;
        _hasPinnedRect = true;
    }

    string DescribePinnedRect()
    {
        if (!_hasPinnedRect)
            return "none";
        return _pinnedRect.Left + "," + _pinnedRect.Top
            + "-" + _pinnedRect.Right + "," + _pinnedRect.Bottom;
    }

    void ApplyPlacement(TranslationPanelAnchor.Result place)
    {
        Native.SetWindowPos(
            _hwnd,
            Native.HWND_TOPMOST,
            place.X,
            place.Y,
            place.Width,
            place.Height,
            Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
        ResizeIsland();

        Native.POINT cursor = Native.GetCursorPos();
        HudLog.Line("translation-place source=" + place.SourceToken
            + " x=" + place.X
            + " y=" + place.Y
            + " dpi=" + place.Dpi
            + " size=" + place.Width + "x" + place.Height
            + " anchor=" + place.AnchorX + "," + place.AnchorY
            + " raw=" + place.RawX + "," + place.RawY
            + " clamped=" + place.Clamped
            + " gap=" + place.Gap
            + " work=" + place.WorkArea.Left + "," + place.WorkArea.Top
            + "-" + place.WorkArea.Right + "," + place.WorkArea.Bottom
            + " reliable=" + place.Reliable
            + " allow-relocate=" + place.AllowRelocate
            + " cursor-now=" + cursor.X + "," + cursor.Y);
    }

    void ShowPanel()
    {
        // 打开时不抢焦点；没有 WS_EX_NOACTIVATE，点击后可以正常激活。
        // 材质 / 圆角跟芯片同一套：每次显示再钉一次宿主 chrome 和 Island 激活态。
        // ShowNoActivate 后前台仍是编辑器：这里只记下快照，不要用「前台不是我」立刻关。
        Interlocked.Increment(ref _dismissEpoch);
        IntPtr fgBefore = Native.GetForegroundWindow();
        _openForeground = RootWindow(fgBefore);
        if (Native.BelongsToWindow(_hwnd, _openForeground))
            _openForeground = IntPtr.Zero;
        ApplyHostChrome();
        Native.ShowNoActivate(_hwnd);
        _islandBackdrop?.ForceInputActive();
        TryIslandSiteChrome();
        _visible = true;
        IntPtr fgAfter = Native.GetForegroundWindow();
        HudLog.Line("translation-show hwnd=" + _hwnd.ToInt64()
            + " fg=" + fgAfter.ToInt64()
            + " open-fg=" + _openForeground.ToInt64()
            + " stole-focus=" + (fgAfter == _hwnd));
    }

    void BeginCaptionDrag()
    {
        if (_hwnd == IntPtr.Zero)
            return;
        Native.ReleaseCapture();
        Native.SendMessage(
            _hwnd,
            Native.WM_NCLBUTTONDOWN,
            new IntPtr(Native.HTCAPTION),
            IntPtr.Zero);
    }

    void OnContentLoadedForBackdrop(object sender, RoutedEventArgs e)
    {
        _content.Root.Loaded -= OnContentLoadedForBackdrop;
        if (!ShouldApplyIslandBackdrop)
        {
            HudLog.Line("translation-island-backdrop=skip"
                + " transparency=" + Native.TransparencyEnabled()
                + " high-contrast=" + Native.HighContrastEnabled());
            TryIslandSiteChrome();
            return;
        }
        HudLog.Line("translation-island-backdrop-schedule kind=Acrylic.Default");
        _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, ApplyIslandBackdrop);
    }

    void ApplyIslandBackdrop()
    {
        if (_backdropApplied || _closing || _disposed)
            return;
        if (!ShouldApplyIslandBackdrop)
        {
            HudLog.Line("translation-island-backdrop-apply-skip transparency=" + Native.TransparencyEnabled()
                + " high-contrast=" + Native.HighContrastEnabled());
            ApplyHostChrome();
            return;
        }
        _backdropApplied = true;

        HudLog.Line("translation-island-backdrop-begin=Acrylic"
            + " supported=" + IslandSystemBackdrop.IsSupported()
            + " high-contrast=" + Native.HighContrastEnabled());
        try
        {
            if (!IslandSystemBackdrop.IsSupported())
            {
                HudLog.Line("translation-island-backdrop-skip-unsupported");
                _backdropApplied = false;
                ApplyHostChrome();
                return;
            }

            // 跟芯片同一套 Composition Controller。不要 Thin，不要默认 DesktopAcrylicBackdrop。
            _islandBackdrop = new IslandSystemBackdrop();
            _xamlSource.SystemBackdrop = _islandBackdrop;
            _islandBackdrop.ForceInputActive();
            _islandBackdrop.SyncTheme(Native.AppsUseDarkMode());
            HudLog.Line("translation-island-backdrop-ok=" + _islandBackdrop.GetType().Name
                + " kind=Acrylic"
                + " current=" + (_xamlSource.SystemBackdrop?.GetType().Name ?? "null")
                + " recipe=Acrylic.Default");
            TryIslandSiteChrome();
            // OnTargetConnected 可能还没跑完，下一个 tick 再钉一次激活态和站点 chrome。
            _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                if (_closing || _disposed)
                    return;
                _islandBackdrop?.ForceInputActive();
                TryIslandSiteChrome();
            });
        }
        catch (Exception ex)
        {
            HudLog.Line("translation-island-backdrop-failed=" + ex);
            _islandBackdrop = null;
            _backdropApplied = false;
        }
    }

    void SyncIslandBackdropWithTransparency()
    {
        if (ShouldApplyIslandBackdrop)
        {
            if (!_backdropApplied)
                ApplyIslandBackdrop();
            else
                _islandBackdrop?.ForceInputActive();
            return;
        }

        if (!_backdropApplied && _xamlSource.SystemBackdrop == null)
            return;
        try
        {
            _xamlSource.SystemBackdrop = null;
            HudLog.Line("translation-island-backdrop-cleared");
        }
        catch (Exception ex)
        {
            HudLog.Line("translation-island-backdrop-clear-failed=" + ex.GetType().Name);
        }
        _islandBackdrop = null;
        _backdropApplied = false;
    }

    void OnColorValuesChanged(UISettings sender, object args)
    {
        _dispatcher.TryEnqueue(() => SyncThemeFromSystem("ColorValuesChanged"));
    }

    void ApplyHostChrome(bool? dark = null)
    {
        Native.ApplyDwmChrome(_hwnd, dark, HostBackdrop);
        TryIslandSiteChrome(dark);
    }

    /// <summary>
    /// 跟芯片同一套：圆角只打在宿主 HWND 上，DWMWCP_ROUNDSMALL。
    /// 给 Island 子 HWND 再打一次 chrome 只是可选尝试，读回 0 不算失败。
    /// 不要 SetWindowRgn，不要 Acrylic Thin。
    /// </summary>
    void TryIslandSiteChrome(bool? dark = null)
    {
        if (_closing || _disposed)
            return;

        bool useDark = dark ?? Native.AppsUseDarkMode();
        bool highContrast = Native.HighContrastEnabled();
        int hostCorner = Native.QueryDwmCorner(_hwnd);
        if (_islandSiteLogged.Add(_hwnd.ToInt64()))
        {
            HudLog.Line("translation-host-chrome hwnd=" + _hwnd.ToInt64()
                + " corner=" + hostCorner
                + " expected=" + (highContrast ? "none" : "roundsmall")
                + " host-backdrop=" + HostBackdrop
                + " island-backdrop=" + ShouldApplyIslandBackdrop);
        }

        void ApplyOne(IntPtr hwnd, string source)
        {
            if (hwnd == IntPtr.Zero || hwnd == _hwnd)
                return;
            string className = Native.GetWindowClassName(hwnd);
            if (!Native.IsIslandVisualSite(className))
                return;
            Native.ApplyIslandSiteChrome(hwnd, useDark);
            long key = hwnd.ToInt64();
            if (!_islandSiteLogged.Add(key))
                return;
            int actual = Native.QueryDwmCorner(hwnd);
            HudLog.Line("translation-island-site-chrome source=" + source
                + " hwnd=" + key
                + " class=" + className
                + " requested=" + (highContrast ? "none" : "roundsmall")
                + " actual=" + actual
                + " accepted=" + (actual == (highContrast ? Native.DWMWCP_DONOTROUND : Native.DWMWCP_ROUNDSMALL))
                + " optional=True"
                + " dark=" + useDark);
        }

        try
        {
            var bridge = _xamlSource?.SiteBridge;
            if (bridge != null)
                ApplyOne(Win32Interop.GetWindowFromWindowId(bridge.WindowId), "site-bridge");
        }
        catch (Exception ex)
        {
            HudLog.Line("translation-island-site-bridge-failed=" + ex.GetType().Name);
        }

        Native.ForEachChildWindow(_hwnd, child => ApplyOne(child, "enum-child"));
    }

    void RegisterForegroundListener()
    {
        try
        {
            _foregroundHook = Native.SetWinEventHook(
                Native.EVENT_SYSTEM_FOREGROUND,
                Native.EVENT_SYSTEM_FOREGROUND,
                IntPtr.Zero,
                _winEventProc,
                0,
                0,
                Native.WINEVENT_OUTOFCONTEXT);
        }
        catch (Exception ex)
        {
            _foregroundHook = IntPtr.Zero;
            HudLog.Line("translation-foreground-hook-failed=" + ex.GetType().Name);
            return;
        }

        GC.KeepAlive(_winEventProc);
        HudLog.Line("translation-foreground-hook hwnd=" + _hwnd.ToInt64()
            + " hook=" + _foregroundHook.ToInt64()
            + " ok=" + (_foregroundHook != IntPtr.Zero));
    }

    void UnregisterForegroundListener()
    {
        if (_foregroundHook != IntPtr.Zero)
        {
            try { Native.UnhookWinEvent(_foregroundHook); } catch { }
            HudLog.Line("translation-foreground-unhook=" + _foregroundHook.ToInt64());
            _foregroundHook = IntPtr.Zero;
        }
    }

    void RegisterOutsideClickListener()
    {
        try
        {
            _mouseHook = Native.SetWindowsHookExW(
                Native.WH_MOUSE_LL,
                _mouseHookProc,
                Native.GetModuleHandle(null),
                0);
        }
        catch (Exception ex)
        {
            _mouseHook = IntPtr.Zero;
            HudLog.Line("translation-mouse-hook-failed=" + ex.GetType().Name);
            return;
        }

        GC.KeepAlive(_mouseHookProc);
        HudLog.Line("translation-mouse-hook hwnd=" + _hwnd.ToInt64()
            + " hook=" + _mouseHook.ToInt64()
            + " ok=" + (_mouseHook != IntPtr.Zero));
    }

    void UnregisterOutsideClickListener()
    {
        if (_mouseHook != IntPtr.Zero)
        {
            try { Native.UnhookWindowsHookEx(_mouseHook); } catch { }
            HudLog.Line("translation-mouse-unhook=" + _mouseHook.ToInt64());
            _mouseHook = IntPtr.Zero;
        }
    }

    // 低级鼠标钩子：尽快 CallNextHookEx，不要在这里 Hide。
    IntPtr OnMouseHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= Native.HC_ACTION
            && Native.IsMouseButtonDown(wParam.ToInt32())
            && _visible
            && !_pinned
            && !_closing
            && !_disposed
            && Native.TryReadLowLevelMousePoint(lParam, out Native.POINT pt))
        {
            int epoch = Volatile.Read(ref _dismissEpoch);
            _dispatcher.TryEnqueue(() => OnOutsideClick(pt, epoch));
        }

        return Native.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    void OnOutsideClick(Native.POINT pt, int epoch)
    {
        if (_closing || _disposed)
            return;
        if (epoch != Volatile.Read(ref _dismissEpoch))
            return;
        if (!_visible)
            return;

        bool hits = Native.PointHitsWindow(_hwnd, pt);
        if (!TranslationPanelDismiss.ShouldHideOnOutsideClick(_visible, _pinned, hits))
            return;

        HudLog.Line("translation-dismiss reason=outside-click"
            + " x=" + pt.X
            + " y=" + pt.Y
            + " hits=" + hits
            + " pinned=" + _pinned);
        Hide();
    }

    // 钩子线程：只排队，不碰 UI 对象。
    void OnWinEvent(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime)
    {
        if (eventType != Native.EVENT_SYSTEM_FOREGROUND)
            return;
        // OBJID_WINDOW = 0。子对象噪声丢掉。
        if (idObject != 0)
            return;
        if (_closing || _disposed)
            return;

        int epoch = Volatile.Read(ref _dismissEpoch);
        _dispatcher.TryEnqueue(() => OnForegroundChanged(hwnd, epoch, "foreground"));
    }

    void OnForegroundChanged(IntPtr hwnd, int epoch, string reason)
    {
        if (_closing || _disposed)
            return;
        if (epoch != Volatile.Read(ref _dismissEpoch))
            return;
        if (!_visible)
            return;

        if (hwnd == IntPtr.Zero)
            hwnd = Native.GetForegroundWindow();

        bool known = hwnd != IntPtr.Zero && Native.IsWindow(hwnd);
        bool belongs = Native.BelongsToWindow(_hwnd, hwnd);
        // 打开瞬间前台仍是编辑器，包括它的子控件。点到面板或其他窗口后快照才作废。
        if (!belongs && IsOpenForeground(hwnd))
        {
            HudLog.Line("translation-dismiss-skip reason=open-fg"
                + " source=" + reason
                + " fg=" + hwnd.ToInt64()
                + " open-fg=" + _openForeground.ToInt64());
            return;
        }

        // hwnd=0 或无效窗口不能清快照，否则下一发编辑器前台会被当成新失焦。
        if (belongs || (known && !IsOpenForeground(hwnd)))
            _openForeground = IntPtr.Zero;

        if (!TranslationPanelDismiss.ShouldHide(_visible, _pinned, known, belongs))
            return;

        HudLog.Line("translation-dismiss reason=" + reason
            + " fg=" + hwnd.ToInt64()
            + " class=" + Native.GetWindowClassName(hwnd)
            + " belongs=" + belongs
            + " pinned=" + _pinned);
        Hide();
    }

    bool IsOpenForeground(IntPtr hwnd)
    {
        if (_openForeground == IntPtr.Zero || hwnd == IntPtr.Zero)
            return false;
        if (hwnd == _openForeground)
            return true;
        return Native.BelongsToWindow(_openForeground, hwnd);
    }

    static IntPtr RootWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return IntPtr.Zero;
        try
        {
            IntPtr root = Native.GetAncestor(hwnd, Native.GA_ROOT);
            if (root != IntPtr.Zero)
                return root;
        }
        catch
        {
        }
        return hwnd;
    }

    void RegisterClass()
    {
        var wc = new Native.WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<Native.WNDCLASSEXW>(),
            style = Native.CS_HREDRAW | Native.CS_VREDRAW,
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
            hInstance = Native.GetModuleHandle(null),
            hCursor = Native.LoadCursor(IntPtr.Zero, Native.IDC_ARROW),
            hbrBackground = IntPtr.Zero,
            lpszClassName = ClassName
        };
        ushort atom = Native.RegisterClassExW(ref wc);
        if (atom == 0)
        {
            int err = Marshal.GetLastWin32Error();
            if (err != 1410)
                throw new InvalidOperationException("翻译面板 RegisterClassExW 失败: " + err);
        }
    }

    IntPtr CreatePopup()
    {
        int dpi = Native.GetSystemDpi();
        int width = Native.DipToPx(360, dpi);
        int height = Native.DipToPx(240, dpi);

        // 可点击面板：TOPMOST + TOOLWINDOW，不要 NOACTIVATE，不要 TRANSPARENT。
        return Native.CreateWindowExW(
            Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST,
            ClassName,
            WindowTitle,
            Native.WS_POPUP,
            -32000,
            -32000,
            width,
            height,
            IntPtr.Zero,
            IntPtr.Zero,
            Native.GetModuleHandle(null),
            IntPtr.Zero);
    }

    void ResizeIsland()
    {
        if (!Native.GetClientRect(_hwnd, out Native.RECT client))
            return;
        try
        {
            _xamlSource.SiteBridge?.MoveAndResize(new RectInt32(
                0,
                0,
                Math.Max(1, client.Width),
                Math.Max(1, client.Height)));
            TryIslandSiteChrome();
        }
        catch (Exception ex)
        {
            HudLog.Line("translation-island-resize-failed=" + ex.GetType().Name + " " + ex.Message);
        }
    }

    IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case Native.WM_CLOSE:
                Hide();
                return IntPtr.Zero;
            case Native.WM_ACTIVATE:
                // ShowNoActivate 本身不会让面板变成前台；真正失焦是之后点到别的窗口。
                if (Native.LoWord(wParam) == Native.WA_INACTIVE)
                    OnForegroundChanged(lParam, Volatile.Read(ref _dismissEpoch), "activate");
                break;
            case Native.WM_KEYDOWN:
                if (wParam.ToInt32() == Native.VK_ESCAPE)
                {
                    Hide();
                    HudLog.Line("translation-esc");
                    return IntPtr.Zero;
                }
                break;
            case Native.WM_SETTINGCHANGE:
            case Native.WM_THEMECHANGED:
            case Native.WM_DWMCOLORIZATIONCOLORCHANGED:
                SyncThemeFromSystem("panel-" + msg);
                break;
            case Native.WM_DPICHANGED:
                HandleDpiChanged(wParam, lParam);
                return IntPtr.Zero;
            case Native.WM_SIZE:
            case Native.WM_MOVE:
                ResizeIsland();
                // 钉住后拖动也要记下矩形，关闭再 OPEN 才能回到拖完的位置。
                if (_pinned)
                    RememberCurrentRectIfPinned();
                break;
            case Native.WM_DESTROY:
                // 面板销毁不能 PostQuitMessage，否则会把 IME 芯片进程一起带走。
                return IntPtr.Zero;
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    void HandleDpiChanged(IntPtr wParam, IntPtr lParam)
    {
        int dpi = Native.HiWord(wParam);
        HudLog.Line("translation-dpi-changed=" + dpi);
        if (lParam != IntPtr.Zero)
        {
            var rect = Marshal.PtrToStructure<Native.RECT>(lParam);
            Native.SetWindowPos(
                _hwnd,
                IntPtr.Zero,
                rect.Left,
                rect.Top,
                rect.Width,
                rect.Height,
                Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        }
        ResizeIsland();
    }

    void DetachIsland(string reason)
    {
        HudLog.Line("translation-island-detach-begin=" + reason);
        try
        {
            if (_xamlSource.SystemBackdrop != null)
                _xamlSource.SystemBackdrop = null;
        }
        catch (Exception ex)
        {
            HudLog.Line("translation-island-backdrop-clear-failed=" + ex.GetType().Name);
        }
        _islandBackdrop = null;
        _islandSiteLogged.Clear();
        try { _xamlSource.Content = null; } catch { }
        try { _xamlSource.Dispose(); } catch (Exception ex)
        {
            HudLog.Line("translation-island-dispose-failed=" + ex.GetType().Name);
        }
    }
}
