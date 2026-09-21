using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 翻译面板 Island 内容。独立于 32×32 IME 芯片，可点击、可钉住、可拖动。
/// 骨架只放原文 / 译文占位，不接选区，不接翻译后端。
/// 视觉已定稿，不要改尺寸、padding、图标 path、标题次级色和分隔线。
/// </summary>
internal sealed class TranslationPanel
{
    // 定稿：标题栏 32，按钮 24，图标 16，标题字 12，stroke 1.32。
    const double IconDip = 16;
    const double ButtonDip = 24;
    const double CaptionDip = 32;
    const double CaptionFontDip = 12;
    const double StrokeDip = 1.32;

    readonly Grid _root;
    readonly Border _dragRegion;
    readonly ToggleButton _pinButton;
    readonly Button _copyResultButton;
    readonly Button _closeButton;
    readonly FrameworkElement _iconPinOutline;
    readonly FrameworkElement _iconPinFilled;
    readonly TextBlock _sourceText;
    readonly TextBlock _resultText;

    TranslationSource.Result _source = TranslationSource.Empty();
    TranslationResult.Result _result = TranslationResult.Empty();

    public FrameworkElement Root => _root;

    public event EventHandler? PinChanged;
    public event EventHandler? CloseRequested;
    public event EventHandler<string>? CopyRequested;
    public event EventHandler? DragRequested;

    public bool IsPinned => _pinButton.IsChecked == true;
    public TranslationSource.Result CurrentSource => _source;
    public TranslationResult.Result CurrentResult => _result;

    public TranslationPanel()
    {
        _root = new Grid
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent)
        };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // 定稿标题栏：32 DIP 高，padding 12,0,4,0。右边距不要再往圆角内沿收。
        var caption = new Grid
        {
            Height = CaptionDip,
            Padding = new Thickness(12, 0, 4, 0)
        };

        // 整条标题栏可拖；按钮自己命中，不会落到这块 Border 上。
        _dragRegion = new Border
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent)
        };
        _dragRegion.PointerPressed += OnDragPressed;
        caption.Children.Add(_dragRegion);

        // 定稿标题：12 DIP + TextFillColorSecondaryBrush，不要跟正文抢主前景。
        TextBlock title = BuildCaptionTitle("翻译");
        caption.Children.Add(title);

        // 未钉：空心图钉，跟标题栏前景。
        _iconPinOutline = BuildIcon(PinGlyphXaml(pinned: false), fallback: BuildPinFallback(pinned: false));
        // 已钉：ToggleButton 选中底是实色，图标必须用白色，不能再跟 TextFillColorPrimary。
        _iconPinFilled = BuildIcon(PinGlyphXaml(pinned: true), fallback: BuildPinFallback(pinned: true));
        _iconPinFilled.Visibility = Visibility.Collapsed;

        var pinGlyph = new Grid
        {
            Width = IconDip,
            Height = IconDip
        };
        pinGlyph.Children.Add(_iconPinOutline);
        pinGlyph.Children.Add(_iconPinFilled);

        _pinButton = MakeChromeButton<ToggleButton>(pinGlyph);
        _pinButton.Margin = new Thickness(0, 0, 2, 0);
        _pinButton.Click += (_, _) =>
        {
            SyncPinVisual();
            PinChanged?.Invoke(this, EventArgs.Empty);
        };

        FrameworkElement closeGlyph = BuildIcon(
            """
            <Path Data="M4.2,4.2 L11.8,11.8"
                  Fill="Transparent"
                  Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                  StrokeThickness="1.32"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"/>
            <Path Data="M11.8,4.2 L4.2,11.8"
                  Fill="Transparent"
                  Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                  StrokeThickness="1.32"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"/>
            """,
            fallback: BuildCloseFallback());
        _closeButton = MakeChromeButton<Button>(closeGlyph);
        ToolTipService.SetToolTip(_closeButton, "关闭");
        AutomationProperties.SetName(_closeButton, "关闭");
        _closeButton.Click += (_, _) => CloseRequested?.Invoke(this, EventArgs.Empty);

        // 复制只出译文。放在钉住左边，空占位禁用，避免覆盖用户剪贴板。
        _copyResultButton = MakeCopyButton("result", "复制译文");
        _copyResultButton.Margin = new Thickness(0, 0, 2, 0);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center
        };
        buttons.Children.Add(_copyResultButton);
        buttons.Children.Add(_pinButton);
        buttons.Children.Add(_closeButton);
        caption.Children.Add(buttons);
        Grid.SetRow(caption, 0);
        _root.Children.Add(caption);
        SyncPinVisual();

        _sourceText = BuildBody(TranslationSource.Empty().DisplayText);
        var sourceView = new ScrollViewer
        {
            Padding = new Thickness(12, 8, 12, 8),
            Content = _sourceText
        };
        Grid.SetRow(sourceView, 1);
        _root.Children.Add(sourceView);

        // 分隔线走 ThemeResource，不要写死 Gray。资源挂不上才退回半透明灰。
        FrameworkElement divider = BuildDivider();
        Grid.SetRow(divider, 2);
        _root.Children.Add(divider);

        _resultText = BuildBody(TranslationResult.Empty().DisplayText);
        var resultView = new ScrollViewer
        {
            Padding = new Thickness(12, 8, 12, 12),
            Content = _resultText
        };
        Grid.SetRow(resultView, 3);
        _root.Children.Add(resultView);

        // Esc 关面板。不抢 IME 芯片热键，不接线 AHK。定位 / 原文 / 译文来源只写日志，不画在面板上。
        var escape = new KeyboardAccelerator
        {
            Key = Windows.System.VirtualKey.Escape
        };
        escape.Invoked += (_, args) =>
        {
            CloseRequested?.Invoke(this, EventArgs.Empty);
            args.Handled = true;
        };
        _root.KeyboardAccelerators.Add(escape);
        SyncCopyButtons();
    }

    public void SetPinned(bool pinned)
    {
        if (_pinButton.IsChecked != pinned)
            _pinButton.IsChecked = pinned;
        SyncPinVisual();
    }

    public void SetRequestedTheme(bool dark)
    {
        ElementTheme next = dark ? ElementTheme.Dark : ElementTheme.Light;
        if (_root.RequestedTheme != next)
            _root.RequestedTheme = next;
    }

    /// <summary>
    /// 只填原文。默认把译文打回 Empty，避免旧译文看起来像已经译完。
    /// 明确 keepResult 时才保留当前译文（给后续可能的增量刷新用）。
    /// </summary>
    public void SetSource(TranslationSource.Result source, bool keepResult = false)
    {
        _source = source;
        ApplyBody(_sourceText, source.Ok, source.DisplayText);
        if (!keepResult)
            SetResult(TranslationResult.Empty());
        else
            SyncCopyButtons();
    }

    /// <summary>
    /// 只填译文占位。不调用翻译服务，也不把原文拷过来。
    /// </summary>
    public void SetResult(TranslationResult.Result result)
    {
        _result = result;
        ApplyBody(_resultText, result.Ok, result.DisplayText);
        SyncCopyButtons();
    }

    void SyncPinVisual()
    {
        bool pinned = IsPinned;
        _iconPinOutline.Visibility = pinned ? Visibility.Collapsed : Visibility.Visible;
        _iconPinFilled.Visibility = pinned ? Visibility.Visible : Visibility.Collapsed;
        string label = pinned ? "取消钉住" : "钉住";
        ToolTipService.SetToolTip(_pinButton, label);
        AutomationProperties.SetName(_pinButton, label);
    }

    void OnDragPressed(object sender, PointerRoutedEventArgs e)
    {
        if (e.OriginalSource is DependencyObject origin
            && (IsInside(_copyResultButton, origin)
                || IsInside(_pinButton, origin)
                || IsInside(_closeButton, origin)))
        {
            return;
        }
        DragRequested?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// 按钮只复制译文。空占位禁用，避免覆盖用户剪贴板。
    /// </summary>
    void SyncCopyButtons()
    {
        TranslationCopy.Outcome resultCopy = TranslationCopy.Resolve("result", _source, _result);
        ApplyCopyButton(_copyResultButton, resultCopy.Ok, "复制译文");
    }

    static void ApplyCopyButton(Button button, bool enabled, string label)
    {
        button.IsEnabled = enabled;
        string tip = enabled ? label : label + "（空）";
        ToolTipService.SetToolTip(button, tip);
        AutomationProperties.SetName(button, tip);
    }

    Button MakeCopyButton(string target, string label)
    {
        FrameworkElement glyph = BuildIcon(CopyGlyphXaml(), fallback: BuildCopyFallback());
        Button button = MakeChromeButton<Button>(glyph);
        button.Click += (_, _) => CopyRequested?.Invoke(this, target);
        ApplyCopyButton(button, enabled: false, label);
        return button;
    }

    static string CopyGlyphXaml()
    {
        // 复制：剪贴板。纸张空心圆角框，顶部夹子盖住纸张上沿，全程 1.32 stroke。
        return
            """
            <Path Data="M4.15,4.55 H11.85 C12.5,4.55 13.05,5.1 13.05,5.75 V12.7 C13.05,13.35 12.5,13.9 11.85,13.9 H4.15 C3.5,13.9 2.95,13.35 2.95,12.7 V5.75 C2.95,5.1 3.5,4.55 4.15,4.55 Z"
                  Fill="Transparent"
                  Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                  StrokeThickness="1.32"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"
                  StrokeLineJoin="Round"/>
            <Path Data="M6.05,1.75 H9.95 C10.5,1.75 10.95,2.2 10.95,2.75 V5.15 H5.05 V2.75 C5.05,2.2 5.5,1.75 6.05,1.75 Z"
                  Fill="{ThemeResource ControlFillColorDefaultBrush}"
                  Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                  StrokeThickness="1.32"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"
                  StrokeLineJoin="Round"/>
            <Path Data="M6.7,3.15 H9.3"
                  Fill="Transparent"
                  Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                  StrokeThickness="1.32"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"/>
            """;
    }

    static FrameworkElement BuildCopyFallback()
    {
        // fallback 跟 XAML 同一套：纸张空心，夹子白底挡住纸张上沿。
        var paper = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = ParseGeometry("M4.15,4.55 H11.85 C12.5,4.55 13.05,5.1 13.05,5.75 V12.7 C13.05,13.35 12.5,13.9 11.85,13.9 H4.15 C3.5,13.9 2.95,13.35 2.95,12.7 V5.75 C2.95,5.1 3.5,4.55 4.15,4.55 Z")
        };
        StyleStroke(paper);

        var clip = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = ParseGeometry("M6.05,1.75 H9.95 C10.5,1.75 10.95,2.2 10.95,2.75 V5.15 H5.05 V2.75 C5.05,2.2 5.5,1.75 6.05,1.75 Z")
        };
        StyleStroke(clip);
        // StyleStroke 会把 Fill 清成透明，这里再盖一层白，挡住纸张上沿。
        clip.Fill = new SolidColorBrush(Microsoft.UI.Colors.White);

        var clipBar = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = ParseGeometry("M6.7,3.15 H9.3")
        };
        StyleStroke(clipBar);
        return WrapIcon(paper, clip, clipBar);
    }

    static bool IsInside(FrameworkElement root, DependencyObject? node)
    {
        while (node != null)
        {
            if (ReferenceEquals(node, root))
                return true;
            node = VisualTreeHelper.GetParent(node);
        }
        return false;
    }

    /// <summary>
    /// 标题栏「翻译」。12 DIP + 次级前景，失败才退回默认前景。
    /// </summary>
    static TextBlock BuildCaptionTitle(string text)
    {
        const string xaml =
            """
            <TextBlock xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                       VerticalAlignment="Center"
                       IsHitTestVisible="False"
                       Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>
            """;
        try
        {
            if (XamlReader.Load(xaml) is TextBlock title)
            {
                title.Text = text;
                title.FontSize = CaptionFontDip;
                return title;
            }
        }
        catch (Exception ex)
        {
            HudLog.Line("translation-caption-xaml-failed=" + ex.GetType().Name + " " + ex.Message);
        }

        return new TextBlock
        {
            Text = text,
            FontSize = CaptionFontDip,
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false
        };
    }

    /// <summary>
    /// 原文 / 译文之间那条线。优先 DividerStrokeColorDefaultBrush，失败才退回半透明灰。
    /// 不要再手写 Gray。
    /// </summary>
    static FrameworkElement BuildDivider()
    {
        const string xaml =
            """
            <Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    Height="1"
                    Margin="12,0,12,0"
                    Background="{ThemeResource DividerStrokeColorDefaultBrush}"/>
            """;
        try
        {
            if (XamlReader.Load(xaml) is FrameworkElement divider)
                return divider;
        }
        catch (Exception ex)
        {
            HudLog.Line("translation-divider-xaml-failed=" + ex.GetType().Name + " " + ex.Message);
        }

        return new Border
        {
            Height = 1,
            Opacity = 0.25,
            Margin = new Thickness(12, 0, 12, 0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Gray)
        };
    }

    static TextBlock BuildBody(string text)
    {
        var block = new TextBlock
        {
            TextWrapping = TextWrapping.WrapWholeWords,
            IsTextSelectionEnabled = true
        };
        ApplyBody(block, ok: false, text);
        return block;
    }

    /// <summary>
    /// 真文案不透明；空占位降低透明度，避免看起来像已经译完。
    /// </summary>
    static void ApplyBody(TextBlock block, bool ok, string text)
    {
        block.Text = text;
        block.Opacity = ok ? 1 : 0.55;
        block.IsTextSelectionEnabled = ok;
    }

    static string PinGlyphXaml(bool pinned)
    {
        // 标准图钉：圆头 + 两侧斜肩 + 横档 + 竖针。已钉走白色，压在选中实心按钮上。
        string stroke = pinned ? "White" : "{ThemeResource TextFillColorPrimaryBrush}";
        return
            $"""
            <Path Data="M6.15,3.15 C6.15,2.55 6.7,2.15 7.25,2.15 H8.75 C9.3,2.15 9.85,2.55 9.85,3.15 V5.55 L11.55,7.55 C11.8,7.85 11.55,8.35 11.15,8.35 H4.85 C4.45,8.35 4.2,7.85 4.45,7.55 L6.15,5.55 Z"
                  Fill="Transparent"
                  Stroke="{stroke}"
                  StrokeThickness="1.32"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"
                  StrokeLineJoin="Round"/>
            <Path Data="M4.55,8.35 H11.45"
                  Fill="Transparent"
                  Stroke="{stroke}"
                  StrokeThickness="1.32"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"/>
            <Path Data="M8,8.35 V13.7"
                  Fill="Transparent"
                  Stroke="{stroke}"
                  StrokeThickness="1.32"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"/>
            """;
    }

    static T MakeChromeButton<T>(UIElement glyph) where T : ButtonBase, new()
    {
        return new T
        {
            Content = glyph,
            Width = ButtonDip,
            Height = ButtonDip,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center
        };
    }

    /// <summary>
    /// 优先 XamlReader + ThemeResource；失败就退到手写 Path，颜色跟系统前景。
    /// </summary>
    static FrameworkElement BuildIcon(string canvasChildrenXaml, FrameworkElement fallback)
    {
        string xaml =
            """
            <Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                     Width="16" Height="16"
                     HorizontalAlignment="Center"
                     VerticalAlignment="Center">
              <Canvas Width="16" Height="16">
            """
            + canvasChildrenXaml
            + """
              </Canvas>
            </Viewbox>
            """;
        try
        {
            if (XamlReader.Load(xaml) is FrameworkElement icon)
                return icon;
        }
        catch (Exception ex)
        {
            HudLog.Line("translation-icon-xaml-failed=" + ex.GetType().Name + " " + ex.Message);
        }
        return fallback;
    }

    static FrameworkElement BuildPinFallback(bool pinned)
    {
        var brush = new SolidColorBrush(pinned ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black);
        var head = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = ParseGeometry("M6.15,3.15 C6.15,2.55 6.7,2.15 7.25,2.15 H8.75 C9.3,2.15 9.85,2.55 9.85,3.15 V5.55 L11.55,7.55 C11.8,7.85 11.55,8.35 11.15,8.35 H4.85 C4.45,8.35 4.2,7.85 4.45,7.55 L6.15,5.55 Z")
        };
        StyleStroke(head, brush);

        var bar = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = ParseGeometry("M4.55,8.35 H11.45")
        };
        StyleStroke(bar, brush);

        var shaft = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = ParseGeometry("M8,8.35 V13.7")
        };
        StyleStroke(shaft, brush);

        return WrapIcon(head, bar, shaft);
    }

    static FrameworkElement BuildCloseFallback()
    {
        var a = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = ParseGeometry("M4.2,4.2 L11.8,11.8")
        };
        StyleStroke(a);
        var b = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = ParseGeometry("M11.8,4.2 L4.2,11.8")
        };
        StyleStroke(b);
        return WrapIcon(a, b);
    }

    static Viewbox WrapIcon(params UIElement[] children)
    {
        var canvas = new Canvas { Width = IconDip, Height = IconDip };
        foreach (UIElement child in children)
            canvas.Children.Add(child);
        return new Viewbox
        {
            Width = IconDip,
            Height = IconDip,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Child = canvas
        };
    }

    static void StyleStroke(Shape shape, Brush? stroke = null)
    {
        shape.Fill = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        shape.Stroke = stroke ?? new SolidColorBrush(Microsoft.UI.Colors.Black);
        shape.StrokeThickness = StrokeDip;
        shape.StrokeStartLineCap = PenLineCap.Round;
        shape.StrokeEndLineCap = PenLineCap.Round;
        shape.StrokeLineJoin = PenLineJoin.Round;
    }

    static Geometry ParseGeometry(string data)
    {
        return (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), data);
    }
}
