using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Graphics;
using Windows.UI.ViewManagement;
using WinRT.Interop;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 原生 HWND 宿主。32×32 DIP 方芯片，跟 caret，点穿，不抢焦点。
/// WinUI 只通过 DesktopWindowXamlSource 画 CN / EN / CAPS 三套 stroke 图标。
/// 正式生命周期：创建一次 → Hide → ShowNoActivate → Hide → 复用，不销毁 Island。
/// Island SystemBackdrop 必须等消息循环至少一个 tick 后再设。
/// 90ms 淡入、110ms 淡出；连续 STATE 用 generation 挡住旧的淡出 Completed。
/// </summary>
internal sealed class HudHost : IDisposable
{
    const string ClassName = Protocol.WindowClass;
    const string WindowTitle = Protocol.WindowTitle;
    const uint QuitTimerId = 1;
    const uint BackdropTimerId = 3;
    const uint HideTimerId = 4;
    const double WidthDip = 32;
    const double HeightDip = 32;
    const double AnchorGapDip = 7;
    const int ShowAnimMs = 90;
    const int HideAnimMs = 110;

    static readonly string[] RotateStates = ["CN", "EN", "CAPS"];

    readonly Native.WndProc _wndProc;
    readonly GCHandle _wndProcPin;
    readonly DispatcherQueue _dispatcher;
    readonly IntPtr _hwnd;
    readonly DesktopWindowXamlSource _xamlSource;
    readonly HudContent _content;
    readonly UISettings _uiSettings;
    readonly DispatcherQueueTimer _cycleTimer;
    readonly HashSet<long> _islandSiteLogged = [];

    TranslationPanelHost? _panel;
    IslandSystemBackdrop? _islandBackdrop;
    Storyboard? _showStoryboard;
    Storyboard? _hideStoryboard;
    IntPtr _foregroundBeforeShow;
    IntPtr _cycleForeground;
    int _cycleIndex;
    int _cycleRounds;
    int _cycleChanged;
    int _cycleStolen;
    int _showGeneration;
    bool _visible;
    bool _hiding;
    bool _backdropApplied;
    bool _closing;
    bool _disposed;

    public IntPtr Handle => _hwnd;
    public bool CycleFailed { get; private set; }

    /// <summary>
    /// Island 自己画材质、并且系统透明效果开着时，宿主必须 DWMSBT_NONE。
    /// 透明关了就退回宿主 Transient，让 DWM 自己降成实色。
    /// 高对比度只读、不测、不改系统设置。
    /// </summary>
    bool ShouldApplyIslandBackdrop =>
        Native.TransparencyEnabled() && !Native.HighContrastEnabled();

    int HostBackdrop =>
        ShouldApplyIslandBackdrop
            ? Native.DWMSBT_NONE
            : Native.DWMSBT_TRANSIENTWINDOW;

    public HudHost()
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("当前线程没有 DispatcherQueue");
        _wndProc = WndProc;
        // 委托必须钉住，否则 GC 后窗口过程会变成野指针。
        _wndProcPin = GCHandle.Alloc(_wndProc);

        RegisterClass();
        HudLog.Line("class-ok");
        _hwnd = CreatePopup();
        if (_hwnd == IntPtr.Zero)
            throw new InvalidOperationException("CreateWindowExW 失败: " + Marshal.GetLastWin32Error());
        HudLog.Line("create-hwnd=" + _hwnd.ToInt64());

        ApplyHostChrome();
        HudLog.Line("dwm-ok dark=" + Native.AppsUseDarkMode()
            + " transparency=" + Native.TransparencyEnabled()
            + " high-contrast=" + Native.HighContrastEnabled()
            + " host-backdrop=" + HostBackdrop
            + " island-backdrop=" + ShouldApplyIslandBackdrop);

        _xamlSource = new DesktopWindowXamlSource();
        HudLog.Line("xaml-source-ctor-ok");
        _xamlSource.Initialize(Win32Interop.GetWindowIdFromWindow(_hwnd));
        HudLog.Line("xaml-source-init-ok");
        // Application.Resources 这时才可用，ThemeResource 才能解析。
        HudApp.TryEnsureControlsResources("after-island");

        _content = new HudContent();
        _content.SetRequestedTheme(Native.AppsUseDarkMode());
        _content.Root.Opacity = 0;
        _xamlSource.Content = _content.Root;
        HudLog.Line("content-ok");
        ResizeIsland();
        HudLog.Line("island-resize-ok");

        _uiSettings = new UISettings();
        _uiSettings.ColorValuesChanged += OnColorValuesChanged;

        _cycleTimer = _dispatcher.CreateTimer();
        _cycleTimer.IsRepeating = true;
        // 4ms 一轮 tick，给 Island layout / DWM 一点时间，200 轮大约 1.6s。
        _cycleTimer.Interval = TimeSpan.FromMilliseconds(4);
        _cycleTimer.Tick += OnCycleTick;

        // 启动后默认隐藏，等 ShowState / 循环测试再 ShowNoActivate。
        Native.HideNoActivate(_hwnd);
        HudLog.Line("host-hidden dpi=" + Native.GetDpiForWindow(_hwnd));

        // 不要在 Initialize / Content 赋值附近同步设 SystemBackdrop。
        _content.Root.Loaded += OnContentLoadedForBackdrop;
    }

    /// <summary>
    /// 翻译面板按需创建。--cycle / 纯 IME 芯片路径不要提前占第二扇 HWND。
    /// </summary>
    TranslationPanelHost Panel
    {
        get
        {
            if (_panel == null)
            {
                _panel = new TranslationPanelHost();
                HudLog.Line("translation-host-ok hwnd=" + _panel.Handle.ToInt64());
            }
            return _panel;
        }
    }

    public void ShowState(
        string state,
        bool logFocus,
        int hintX = 0,
        int hintY = 0,
        int hintDpi = 0,
        int durationMs = 0,
        bool animate = true)
    {
        _content.SetState(state);
        ApplyHostChrome();
        PlaceAtCaret(hintX, hintY, hintDpi, log: logFocus);

        if (logFocus)
        {
            _foregroundBeforeShow = Native.GetForegroundWindow();
            HudLog.Line("show-state=" + state);
            HudLog.Line("hwnd=" + _hwnd.ToInt64());
            HudLog.Line("fg-before=" + _foregroundBeforeShow.ToInt64());
        }

        Native.ShowNoActivate(_hwnd);
        // NOACTIVATE 会把默认 SystemBackdropConfiguration.IsInputActive 打回 false，立刻钉回去。
        _islandBackdrop?.ForceInputActive();
        TryIslandSiteChrome();

        _visible = true;
        _hiding = false;
        _showGeneration++;
        if (animate)
            PlayShow();
        else
        {
            StopAnimations(leaveOpacity: 1);
            _content.Root.Opacity = 1;
        }

        if (logFocus)
        {
            IntPtr fgAfter = Native.GetForegroundWindow();
            HudLog.Line("fg-after=" + fgAfter.ToInt64());
            // 只有 HUD 自己变成前台才算抢焦点。用户切走窗口不算失败。
            HudLog.Line("stole-focus=" + (fgAfter == _hwnd));
        }

        if (animate)
            ArmHideTimer(durationMs);
        else
            Native.KillTimer(_hwnd, new UIntPtr(HideTimerId));
    }

    public void HideNoActivate(bool animate = true)
    {
        Native.KillTimer(_hwnd, new UIntPtr(HideTimerId));
        if (animate)
        {
            BeginHide();
            return;
        }

        StopAnimations(leaveOpacity: 0);
        Native.HideNoActivate(_hwnd);
        _visible = false;
        _hiding = false;
        _content.Root.Opacity = 0;
        HudLog.Line("hide-now");
    }

    /// <summary>
    /// 连续 ShowNoActivate / Hide，每轮核对 GetForegroundWindow。
    /// 走 DispatcherQueueTimer，让 WinUI 有机会 layout，而不是死循环占住 UI 线程。
    /// 循环测试跳过淡入淡出，否则 200 轮会被动画拖死。
    /// </summary>
    public void RunCycleThenExit(int rounds)
    {
        _cycleRounds = Math.Max(1, rounds);
        _cycleIndex = 0;
        _cycleChanged = 0;
        _cycleStolen = 0;
        _cycleForeground = Native.GetForegroundWindow();
        HudLog.Line("cycle-start rounds=" + _cycleRounds
            + " fg=" + _cycleForeground.ToInt64());
        _cycleTimer.Start();
    }

    /// <summary>
    /// 命令行冷启动和 WM_COPYDATA 走同一套解析，避免两套协议分叉。
    /// </summary>
    public void DispatchCommand(string? text)
    {
        if (TranslationPanelProtocol.IsPanelCommand(text))
        {
            Panel.Dispatch(TranslationPanelProtocol.Parse(text));
            return;
        }

        Protocol.Message message = Protocol.Parse(text);
        switch (message.Kind)
        {
            case Protocol.Kind.Hide:
                HideNoActivate(animate: true);
                break;
            case Protocol.Kind.Quit:
                CloseHud("copydata-quit");
                break;
            case Protocol.Kind.Ping:
                HudLog.Line("ping");
                break;
            case Protocol.Kind.State:
                ShowState(
                    message.State,
                    logFocus: true,
                    message.X,
                    message.Y,
                    message.Dpi,
                    message.DurationMs,
                    animate: true);
                break;
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        try { _uiSettings.ColorValuesChanged -= OnColorValuesChanged; } catch { }
        try { _cycleTimer.Tick -= OnCycleTick; } catch { }
        // CloseHud 已经 DetachIsland。这里只 unpin，避免二次 Dispose Island。
        if (_wndProcPin.IsAllocated)
            _wndProcPin.Free();
        HudLog.Line("host-disposed");
    }

    void OnContentLoadedForBackdrop(object sender, RoutedEventArgs e)
    {
        _content.Root.Loaded -= OnContentLoadedForBackdrop;
        if (!ShouldApplyIslandBackdrop)
        {
            HudLog.Line("island-backdrop=skip"
                + " transparency=" + Native.TransparencyEnabled()
                + " high-contrast=" + Native.HighContrastEnabled());
            TryIslandSiteChrome();
            return;
        }

        HudLog.Line("island-backdrop-schedule kind=Acrylic.Default");
        // 再入队一次：Loaded 已经发生，这条 callback 会在当前消息循环的下一个 tick 跑。
        bool queued = _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, ApplyIslandBackdrop);
        HudLog.Line("island-backdrop-enqueued=" + queued);
    }

    void ApplyIslandBackdrop()
    {
        if (_backdropApplied || _closing || _disposed)
            return;
        if (!ShouldApplyIslandBackdrop)
        {
            HudLog.Line("island-backdrop-apply-skip transparency=" + Native.TransparencyEnabled()
                + " high-contrast=" + Native.HighContrastEnabled());
            ApplyHostChrome();
            return;
        }
        _backdropApplied = true;

        HudLog.Line("island-backdrop-begin=Acrylic"
            + " supported=" + IslandSystemBackdrop.IsSupported()
            + " high-contrast=" + Native.HighContrastEnabled());
        try
        {
            if (!IslandSystemBackdrop.IsSupported())
            {
                HudLog.Line("island-backdrop-skip-unsupported");
                _backdropApplied = false;
                ApplyHostChrome();
                return;
            }

            // Composition Controller，强制 IsInputActive。不要用默认 DesktopAcrylicBackdrop。
            _islandBackdrop = new IslandSystemBackdrop();
            _xamlSource.SystemBackdrop = _islandBackdrop;
            _islandBackdrop.ForceInputActive();
            _islandBackdrop.SyncTheme(Native.AppsUseDarkMode());
            HudLog.Line("island-backdrop-ok=" + _islandBackdrop.GetType().Name
                + " kind=Acrylic"
                + " current=" + (_xamlSource.SystemBackdrop?.GetType().Name ?? "null"));
            TryIslandSiteChrome();
            // OnTargetConnected 可能还没跑完，下一个 tick 再钉一次激活态。
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
            HudLog.Line("island-backdrop-failed=" + ex);
            _islandBackdrop = null;
            _backdropApplied = false;
        }
    }

    void OnCycleTick(DispatcherQueueTimer sender, object args)
    {
        if (_closing)
        {
            _cycleTimer.Stop();
            return;
        }

        // 一轮 = show + hide。tick 偶数 show，奇数 hide。
        if (_cycleIndex >= _cycleRounds * 2)
        {
            _cycleTimer.Stop();
            FinishCycle();
            return;
        }

        if (_cycleIndex % 2 == 0)
        {
            string state = RotateStates[(_cycleIndex / 2) % RotateStates.Length];
            ShowState(state, logFocus: _cycleIndex == 0, animate: false);
        }
        else
        {
            HideNoActivate(animate: false);
        }

        IntPtr fg = Native.GetForegroundWindow();
        if (fg == _hwnd)
        {
            _cycleStolen++;
            if (_cycleStolen <= 8)
                HudLog.Line("stole i=" + _cycleIndex + " fg=" + fg.ToInt64());
        }
        else if (fg != _cycleForeground)
        {
            _cycleChanged++;
            if (_cycleChanged <= 8)
                HudLog.Line("fg-changed i=" + _cycleIndex + " fg=" + fg.ToInt64());
            _cycleForeground = fg;
        }

        _cycleIndex++;
    }

    void FinishCycle()
    {
        CycleFailed = _cycleStolen != 0;
        HudLog.Line("cycle-done shown=" + _cycleRounds
            + " stolen=" + _cycleStolen
            + " fg-changed=" + _cycleChanged);
        HudLog.Line("stole-focus=" + CycleFailed);
        HudLog.Line(CycleFailed ? "pass=0" : "pass=1");
        CloseHud(CycleFailed ? "cycle-focus" : "cycle-ok");
    }

    void OnColorValuesChanged(UISettings sender, object args)
    {
        // UISettings 回调不在 UI 线程，必须跳回 Dispatcher。
        _dispatcher.TryEnqueue(() => SyncThemeFromSystem("ColorValuesChanged"));
    }

    void SyncThemeFromSystem(string reason)
    {
        if (_closing || _disposed)
            return;

        bool dark = Native.AppsUseDarkMode();
        bool transparency = Native.TransparencyEnabled();
        HudLog.Line("theme-sync reason=" + reason
            + " dark=" + dark
            + " transparency=" + transparency
            + " high-contrast=" + Native.HighContrastEnabled()
            + " island=" + ShouldApplyIslandBackdrop);
        _content.SetRequestedTheme(dark);
        _islandBackdrop?.SyncTheme(dark);
        SyncIslandBackdropWithTransparency();
        ApplyHostChrome(dark);
        ResizeIsland();
        _panel?.SyncThemeFromSystem(reason);
    }

    void ApplyHostChrome(bool? dark = null)
    {
        Native.ApplyDwmChrome(_hwnd, dark, HostBackdrop);
        TryIslandSiteChrome(dark);
    }

    /// <summary>
    /// 可选尝试：给 Island 子 HWND 再打一次 DWM chrome。
    /// 实测站点 corner 读回 0，真正裁圆的是宿主 ROUNDSMALL。打不上不算失败。
    /// 不要 SetWindowRgn。
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
            HudLog.Line("host-chrome hwnd=" + _hwnd.ToInt64()
                + " corner=" + hostCorner
                + " expected=" + (highContrast ? "none" : "roundsmall"));
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
            HudLog.Line("island-site-chrome source=" + source
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
            HudLog.Line("island-site-bridge-failed=" + ex.GetType().Name);
        }

        Native.ForEachChildWindow(_hwnd, child => ApplyOne(child, "enum-child"));
    }

    void ArmHideTimer(int durationMs)
    {
        Native.KillTimer(_hwnd, new UIntPtr(HideTimerId));
        uint ms = (uint)Protocol.ClampDuration(durationMs);
        Native.SetTimer(_hwnd, new UIntPtr(HideTimerId), ms, IntPtr.Zero);
        HudLog.Line("hide-arm-ms=" + ms + " generation=" + _showGeneration);
    }

    /// <summary>
    /// 透明开且非高对比度：Island 画 Acrylic。否则拆掉 Island 材质，宿主 Transient 自己降成实色。
    /// </summary>
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
            HudLog.Line("island-backdrop-cleared transparency=" + Native.TransparencyEnabled()
                + " high-contrast=" + Native.HighContrastEnabled());
        }
        catch (Exception ex)
        {
            HudLog.Line("island-backdrop-clear-failed=" + ex.GetType().Name);
        }
        _islandBackdrop = null;
        _backdropApplied = false;
    }

    /// <summary>
    /// 从当前透明度淡入到 1。连续 STATE 会先停掉正在跑的淡出，避免新芯片被旧 Completed 藏掉。
    /// </summary>
    void PlayShow()
    {
        StopAnimations(leaveOpacity: null);
        _showStoryboard = BuildOpacityStoryboard(1, ShowAnimMs, EasingMode.EaseOut);
        _showStoryboard.Begin();
    }

    /// <summary>
    /// 淡出到 0 再 Hide。Completed 必须对得上当前 generation，否则是过期的隐藏。
    /// </summary>
    void BeginHide()
    {
        if (!_visible || _hiding)
        {
            if (!_visible)
                Native.HideNoActivate(_hwnd);
            return;
        }

        _hiding = true;
        int generation = _showGeneration;
        StopAnimations(leaveOpacity: null);
        _hideStoryboard = BuildOpacityStoryboard(0, HideAnimMs, EasingMode.EaseIn);
        _hideStoryboard.Completed += (_, _) =>
        {
            if (generation != _showGeneration)
            {
                HudLog.Line("hide-completed-stale generation=" + generation
                    + " current=" + _showGeneration);
                return;
            }
            Native.HideNoActivate(_hwnd);
            _visible = false;
            _hiding = false;
            _content.Root.Opacity = 0;
            HudLog.Line("hide-now generation=" + generation);
        };
        _hideStoryboard.Begin();
        HudLog.Line("hide-begin generation=" + generation);
    }

    Storyboard BuildOpacityStoryboard(double to, int milliseconds, EasingMode easingMode)
    {
        var animation = new DoubleAnimation
        {
            To = to,
            Duration = new Duration(TimeSpan.FromMilliseconds(milliseconds)),
            EasingFunction = new QuadraticEase { EasingMode = easingMode }
        };
        Storyboard.SetTarget(animation, _content.Root);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        return storyboard;
    }

    void StopAnimations(double? leaveOpacity)
    {
        double current = _content.Root.Opacity;
        try { _showStoryboard?.Stop(); } catch { }
        try { _hideStoryboard?.Stop(); } catch { }
        _showStoryboard = null;
        _hideStoryboard = null;
        _content.Root.Opacity = leaveOpacity ?? current;
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
            // 1410 = ERROR_CLASS_ALREADY_EXISTS，重复跑时可以继续用。
            if (err != 1410)
                throw new InvalidOperationException("RegisterClassExW 失败: " + err);
        }
    }

    IntPtr CreatePopup()
    {
        int dpi = Native.GetSystemDpi();
        int width = Native.DipToPx(WidthDip, dpi);
        int height = Native.DipToPx(HeightDip, dpi);

        return Native.CreateWindowExW(
            Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST,
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

    /// <summary>
    /// 芯片跟 caret：默认落在锚点下方，下方不够翻到上方。显示期间不持续跟踪。
    /// </summary>
    void PlaceAtCaret(int hintX, int hintY, int hintDpi, bool log = false)
    {
        Anchor.Result anchor = Anchor.Locate(hintX, hintY);
        int dpi = hintDpi > 0 ? hintDpi : Native.GetDpiForPoint(anchor.X, anchor.Y);
        if (dpi <= 0)
            dpi = Native.GetSystemDpi();

        int width = Native.DipToPx(WidthDip, dpi);
        int height = Native.DipToPx(HeightDip, dpi);
        int gap = Native.DipToPx(AnchorGapDip, dpi);

        int x;
        int y;
        if (anchor.Ok)
        {
            x = anchor.X - width / 2;
            y = anchor.Y + gap;
            Native.RECT work = Native.GetWorkAreaFromPoint(anchor.X, anchor.Y);
            if (y + height > work.Bottom - 8)
                y = anchor.Y - Math.Max(12, anchor.Height) - height - gap;
            if (y < work.Top + 8)
                y = work.Top + 8;
            if (x + width > work.Right - 8)
                x = work.Right - 8 - width;
            if (x < work.Left + 8)
                x = work.Left + 8;
        }
        else
        {
            Native.RECT work = Native.GetPrimaryWorkArea();
            x = work.Left + Math.Max(0, (work.Width - width) / 2);
            y = work.Top + Math.Max(0, (int)(work.Height * 0.82) - height / 2);
        }

        Native.SetWindowPos(
            _hwnd,
            Native.HWND_TOPMOST,
            x,
            y,
            width,
            height,
            Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
        if (log)
        {
            HudLog.Line("place source=" + (anchor.Ok ? anchor.Source : "fallback")
                + " x=" + x + " y=" + y
                + " dpi=" + dpi
                + " size=" + width + "x" + height);
        }
        ResizeIsland();
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
            HudLog.Line("island-resize-failed=" + ex.GetType().Name + " " + ex.Message);
        }
    }

    IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case Native.WM_MOUSEACTIVATE:
                return new IntPtr(Native.MA_NOACTIVATE);
            case Native.WM_NCACTIVATE:
                return IntPtr.Zero;
            case Native.WM_NCHITTEST:
                return new IntPtr(Native.HTTRANSPARENT);
            case Native.WM_TIMER:
                uint timerId = (uint)wParam.ToInt64();
                if (timerId == QuitTimerId)
                    CloseHud("timer");
                else if (timerId == BackdropTimerId)
                {
                    Native.KillTimer(_hwnd, new UIntPtr(BackdropTimerId));
                    ApplyIslandBackdrop();
                }
                else if (timerId == HideTimerId)
                {
                    Native.KillTimer(_hwnd, new UIntPtr(HideTimerId));
                    HudLog.Line("hide-timeout generation=" + _showGeneration);
                    BeginHide();
                }
                return IntPtr.Zero;
            case Native.WM_SETTINGCHANGE:
                HudLog.Line("settingchange=" + (Native.PtrToString(lParam) ?? ""));
                SyncThemeFromSystem("WM_SETTINGCHANGE");
                break;
            case Native.WM_THEMECHANGED:
                SyncThemeFromSystem("WM_THEMECHANGED");
                break;
            case Native.WM_DWMCOLORIZATIONCOLORCHANGED:
                SyncThemeFromSystem("WM_DWMCOLORIZATIONCOLORCHANGED");
                break;
            case Native.WM_POWERBROADCAST:
                if (wParam.ToInt32() == Native.PBT_APMRESUMEAUTOMATIC
                    || wParam.ToInt32() == Native.PBT_APMRESUMESUSPEND)
                {
                    HudLog.Line("resume wparam=" + wParam.ToInt32());
                    SyncThemeFromSystem("resume");
                }
                break;
            case Native.WM_DPICHANGED:
                HandleDpiChanged(wParam, lParam);
                return IntPtr.Zero;
            case Native.WM_SIZE:
            case Native.WM_MOVE:
                ResizeIsland();
                break;
            case Native.WM_COPYDATA:
                HandleCopyData(lParam);
                return new IntPtr(1);
            case Native.WM_DESTROY:
                Native.PostQuitMessage(0);
                return IntPtr.Zero;
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    void HandleDpiChanged(IntPtr wParam, IntPtr lParam)
    {
        int dpi = Native.HiWord(wParam);
        HudLog.Line("dpi-changed=" + dpi);
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

    void HandleCopyData(IntPtr lParam)
    {
        string? text = Native.ReadCopyData(lParam);
        HudLog.Line("copydata=" + (text ?? ""));
        DispatchCommand(text);
    }

    void CloseHud(string reason)
    {
        if (_closing)
            return;
        _closing = true;
        try { _cycleTimer.Stop(); } catch { }
        Native.KillTimer(_hwnd, new UIntPtr(QuitTimerId));
        Native.KillTimer(_hwnd, new UIntPtr(BackdropTimerId));
        Native.KillTimer(_hwnd, new UIntPtr(HideTimerId));
        StopAnimations(leaveOpacity: 0);
        HudLog.Line("closing=" + reason);
        if (reason is not ("cycle-ok" or "cycle-focus"))
            HudLog.Line("pass=1");

        // SystemBackdrop 必须在 HWND 还活着时拆掉。Destroy 后再 Dispose Island 会 native AV。
        try { _panel?.Dispose(); } catch { }
        _panel = null;
        DetachIsland("close");
        if (Native.IsWindow(_hwnd))
            Native.DestroyWindow(_hwnd);
        HudLog.Line("hwnd-destroyed");
        try { Application.Current?.Exit(); } catch { }
    }

    void DetachIsland(string reason)
    {
        HudLog.Line("island-detach-begin=" + reason);
        try
        {
            if (_xamlSource.SystemBackdrop != null)
                _xamlSource.SystemBackdrop = null;
            HudLog.Line("island-backdrop-cleared");
        }
        catch (Exception ex)
        {
            HudLog.Line("island-backdrop-clear-failed=" + ex.GetType().Name);
        }

        _islandBackdrop = null;
        _islandSiteLogged.Clear();
        try
        {
            _xamlSource.Content = null;
            HudLog.Line("island-content-cleared");
        }
        catch (Exception ex)
        {
            HudLog.Line("island-content-clear-failed=" + ex.GetType().Name);
        }

        try
        {
            _xamlSource.Dispose();
            HudLog.Line("island-disposed");
        }
        catch (Exception ex)
        {
            HudLog.Line("island-dispose-failed=" + ex.GetType().Name);
        }
    }
}
