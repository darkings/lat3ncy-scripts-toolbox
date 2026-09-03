using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Lat3ncyToolbox.ImeHud;

/// <summary>
/// 候选框式 HUD。HwndSource 直接创建 NoActivate popup，不走 WPF Window，
/// 避免激活、任务栏按钮和系统标题栏。
/// </summary>
internal sealed class HudWindow
{
    readonly HwndSource _source;
    readonly Border _shell;
    readonly TextBlock _glyph;
    readonly Border _capsMark;
    readonly DispatcherTimer _hideTimer;
    Theme _theme;
    bool _visible;
    bool _hiding;
    // ShowState 递增；淡出 Completed 对不上这一代就不再 Hide，避免连按把新 HUD 藏掉。
    int _showGeneration;

    public IntPtr Handle => _source.Handle;

    public HudWindow()
    {
        _theme = Theme.Current();

        _glyph = new TextBlock
        {
            Text = "A",
            FontFamily = new FontFamily("Segoe UI Variable Text"),
            FontSize = StateVisual.LatinFontDip,
            FontWeight = FontWeights.Normal,
            Foreground = _theme.TextBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            SnapsToDevicePixels = true
        };
        TextOptions.SetTextFormattingMode(_glyph, TextFormattingMode.Display);
        TextOptions.SetTextRenderingMode(_glyph, TextRenderingMode.ClearType);
        TextOptions.SetTextHintingMode(_glyph, TextHintingMode.Fixed);

        // 大写状态：仍显示 A，底部一条极细底线，不做成彩色 Badge。
        _capsMark = new Border
        {
            Width = 10,
            Height = 1.25,
            CornerRadius = new CornerRadius(0.6),
            Background = _theme.TextBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 5),
            Opacity = 0,
            IsHitTestVisible = false
        };

        var content = new Grid
        {
            IsHitTestVisible = false
        };
        content.Children.Add(_glyph);
        content.Children.Add(_capsMark);

        _shell = new Border
        {
            Width = StateVisual.WidthDip,
            Height = StateVisual.HeightDip,
            Background = _theme.FillBrush,
            BorderBrush = _theme.HairlineBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6.5),
            Child = content,
            SnapsToDevicePixels = true,
            UseLayoutRounding = true,
            Opacity = 0
        };

        var parameters = new HwndSourceParameters(Protocol.WindowTitle)
        {
            Width = Native.DipToPx(StateVisual.WidthDip, Native.GetSystemDpi()),
            Height = Native.DipToPx(StateVisual.HeightDip, Native.GetSystemDpi()),
            PositionX = -32000,
            PositionY = -32000,
            WindowStyle = Native.WS_POPUP,
            ExtendedWindowStyle = Native.WS_EX_TOOLWINDOW
                | Native.WS_EX_NOACTIVATE
                | Native.WS_EX_TOPMOST
                | Native.WS_EX_TRANSPARENT,
            RestoreFocusMode = RestoreFocusMode.None,
            // 不用 classic layered window。UsesPerPixelOpacity/Transparency 都会走
            // UpdateLayeredWindow，DWM Desktop Acrylic 就透不出来。
            UsesPerPixelOpacity = false,
            UsesPerPixelTransparency = false
        };
        parameters.SetPosition(-32000, -32000);

        _source = new HwndSource(parameters)
        {
            RootVisual = _shell,
            SizeToContent = SizeToContent.Manual
        };
        if (_source.CompositionTarget is { } composition)
            composition.BackgroundColor = Colors.Transparent;
        _source.AddHook(WndProc);

        Native.EnableAcrylic(Handle, _theme.FillArgb, _theme.IsDark, _theme.BorderDwm);
        Native.ShowWindow(Handle, Native.SW_HIDE);

        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(StateVisual.DefaultDurationMs) };
        _hideTimer.Tick += (_, _) => BeginHide();
    }

    public void ShowState(Protocol.Message message)
    {
        ApplyTheme(Theme.Current());

        var (glyph, font, caps) = StateVisual.For(message.State);
        _glyph.Text = glyph;
        _glyph.FontFamily = new FontFamily(font + ", Segoe UI, Microsoft YaHei UI");
        _glyph.FontSize = caps || message.State == Protocol.ImeState.English
            ? StateVisual.LatinFontDip
            : StateVisual.ChineseFontDip;
        _glyph.FontWeight = FontWeights.Normal;
        _capsMark.Opacity = caps ? 1 : 0;

        Anchor.Result anchor = Anchor.Locate(message.X, message.Y);
        PlaceAt(anchor, message.Dpi);

        Native.ShowWindow(Handle, Native.SW_SHOWNOACTIVATE);
        Native.SetWindowPos(
            Handle,
            Native.HWND_TOPMOST,
            0, 0, 0, 0,
            Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        // Acrylic 对可见 HWND 更稳；先 ShowNoActivate 再设材质。
        Native.EnableAcrylic(Handle, _theme.FillArgb, _theme.IsDark, _theme.BorderDwm);

        _visible = true;
        _hiding = false;
        _showGeneration++;
        PlayShow();

        int duration = StateVisual.ClampDuration(message.DurationMs);
        _hideTimer.Stop();
        _hideTimer.Interval = TimeSpan.FromMilliseconds(duration);
        _hideTimer.Start();
    }

    public void HideNow()
    {
        _hideTimer.Stop();
        BeginHide();
    }

    void PlaceAt(Anchor.Result anchor, int hintDpi)
    {
        int dpi = hintDpi > 0 ? hintDpi : Native.GetDpiForPoint(anchor.X, anchor.Y);
        if (dpi <= 0)
            dpi = Native.GetSystemDpi();

        int width = Native.DipToPx(StateVisual.WidthDip, dpi);
        int height = Native.DipToPx(StateVisual.HeightDip, dpi);
        int gap = Native.DipToPx(StateVisual.AnchorGapDip, dpi);

        int x = anchor.X - width / 2;
        int y = anchor.Y + gap;
        Native.RECT work = Native.GetWorkAreaFromPoint(anchor.X, anchor.Y);

        // 下方空间不够时翻到 caret 上方，和微软拼音候选框一致。
        if (y + height > work.Bottom - 8)
            y = anchor.Y - Math.Max(12, anchor.Height) - height - gap;
        if (y < work.Top + 8)
            y = work.Top + 8;
        if (x + width > work.Right - 8)
            x = work.Right - 8 - width;
        if (x < work.Left + 8)
            x = work.Left + 8;

        Native.SetWindowPos(
            Handle,
            Native.HWND_TOPMOST,
            x, y, width, height,
            Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
    }

    void ApplyTheme(Theme theme)
    {
        _theme = theme;
        _shell.Background = theme.FillBrush;
        _shell.BorderBrush = theme.HairlineBrush;
        _glyph.Foreground = theme.TextBrush;
        _capsMark.Background = theme.TextBrush;
        Native.ApplyChrome(Handle, theme.IsDark, theme.BorderDwm);
    }

    void PlayShow()
    {
        var duration = TimeSpan.FromMilliseconds(StateVisual.ShowAnimMs);
        var ease = new QuadraticEase { EasingMode = EasingMode.EaseOut };

        var opacity = new DoubleAnimation(0, 1, duration) { EasingFunction = ease };
        var scaleX = new DoubleAnimation(0.97, 1, duration) { EasingFunction = ease };
        var scaleY = new DoubleAnimation(0.97, 1, duration) { EasingFunction = ease };

        if (_shell.RenderTransform is not ScaleTransform)
        {
            _shell.RenderTransformOrigin = new Point(0.5, 0.5);
            _shell.RenderTransform = new ScaleTransform(0.97, 0.97);
        }

        _shell.BeginAnimation(UIElement.OpacityProperty, opacity);
        ((ScaleTransform)_shell.RenderTransform).BeginAnimation(ScaleTransform.ScaleXProperty, scaleX);
        ((ScaleTransform)_shell.RenderTransform).BeginAnimation(ScaleTransform.ScaleYProperty, scaleY);
    }

    void BeginHide()
    {
        if (!_visible || _hiding)
        {
            if (!_visible)
                Native.ShowWindow(Handle, Native.SW_HIDE);
            return;
        }

        _hiding = true;
        int generation = _showGeneration;
        var duration = TimeSpan.FromMilliseconds(StateVisual.HideAnimMs);
        var opacity = new DoubleAnimation(1, 0, duration)
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn }
        };
        opacity.Completed += (_, _) =>
        {
            // 淡出期间又 ShowState 了：这一代已经作废，不能把新芯片藏掉。
            if (generation != _showGeneration)
                return;
            Native.ShowWindow(Handle, Native.SW_HIDE);
            _visible = false;
            _hiding = false;
        };
        _shell.BeginAnimation(UIElement.OpacityProperty, opacity);
    }

    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case Native.WM_MOUSEACTIVATE:
                handled = true;
                return new IntPtr(Native.MA_NOACTIVATE);
            case Native.WM_NCACTIVATE:
                handled = true;
                return IntPtr.Zero;
            case Native.WM_NCHITTEST:
                handled = true;
                return new IntPtr(Native.HTTRANSPARENT);
            case Native.WM_COPYDATA:
                handled = true;
                HandleCopyData(lParam);
                return new IntPtr(1);
            case Native.WM_SETTINGCHANGE:
                ApplyTheme(Theme.Current());
                Native.EnableAcrylic(Handle, _theme.FillArgb, _theme.IsDark, _theme.BorderDwm);
                break;
            case Native.WM_DPICHANGED:
                if (_visible)
                    Native.EnableAcrylic(Handle, _theme.FillArgb, _theme.IsDark, _theme.BorderDwm);
                break;
        }
        return IntPtr.Zero;
    }

    void HandleCopyData(IntPtr lParam)
    {
        string? text = Native.ReadCopyData(lParam);
        Protocol.Message message = Protocol.Parse(text);
        switch (message.Kind)
        {
            case Protocol.Kind.State:
                ShowState(message);
                break;
            case Protocol.Kind.Hide:
                HideNow();
                break;
            case Protocol.Kind.Quit:
                Application.Current?.Shutdown();
                break;
            case Protocol.Kind.Ping:
                break;
        }
    }
}
