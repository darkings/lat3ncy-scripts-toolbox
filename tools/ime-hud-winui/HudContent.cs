using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI.ViewManagement;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// IME 芯片内容。三态都是同一套 20×20 stroke SVG，没有底线、没有副标题、不混字体。
/// CN → 方框 + 竖线；EN → A；CAPS → 上箭头 + 竖杆 + 底杠。
/// 颜色走 {ThemeResource}，根必须透明。图形和尺寸已定稿，不要改 path。
/// </summary>
internal sealed class HudContent
{
    // 和定稿 viewBox 对齐，Viewbox 不再二次缩放 stroke。
    // CN 那张 SVG 是 1.20，EN / CAPS 是 1.32。
    const double IconDip = 20;
    const double StrokeDip = 1.32;
    const double StrokeDipZh = 1.20;

    readonly Grid _root;
    readonly FrameworkElement _iconZh;
    readonly FrameworkElement _iconEn;
    readonly FrameworkElement _iconCaps;
    readonly List<Shape> _strokes = [];
    readonly bool _themeResourceOk;

    public FrameworkElement Root => _root;
    public bool ThemeResourceOk => _themeResourceOk;

    public HudContent()
    {
        TryAttachIslandResources(out ResourceDictionary islandResources);

        Grid? fromXaml = TryLoadThemeResourceTree();
        if (fromXaml != null)
        {
            _root = fromXaml;
            _iconZh = RequireNamed(_root, "IconZh");
            _iconEn = RequireNamed(_root, "IconEn");
            _iconCaps = RequireNamed(_root, "IconCaps");
            _themeResourceOk = true;
            HudLog.Line("content-theme-resource=True");
        }
        else
        {
            (_root, _iconZh, _iconEn, _iconCaps) = BuildFallbackTree();
            _themeResourceOk = false;
            HudLog.Line("content-theme-resource=False");
        }

        // fallback 时 ThemeResource 不可用，后面靠这三组 Shape 手绑 Stroke。
        CollectStrokes(_iconZh);
        CollectStrokes(_iconEn);
        CollectStrokes(_iconCaps);

        if (islandResources.MergedDictionaries.Count > 0
            && !HasControlsResources(_root.Resources))
        {
            _root.Resources.MergedDictionaries.Add(islandResources);
        }

        _root.Loaded += (_, _) =>
        {
            HudLog.Line("content-loaded actual=" + _root.ActualTheme);
            LogThemeLookup("loaded");
        };
        _root.ActualThemeChanged += (_, _) =>
        {
            HudLog.Line("actual-theme=" + _root.ActualTheme);
            LogThemeLookup("actual-theme");
            if (!_themeResourceOk)
                BindFallbackBrushes();
        };
    }

    /// <summary>
    /// 只切三套图标的 Visibility，不再改 Text / FontFamily / FontSize。
    /// </summary>
    public void SetState(string state)
    {
        switch (state.Trim().ToUpperInvariant())
        {
            case "ZH":
            case "CN":
            case "CHINESE":
            case "中":
                ShowOnly(_iconZh);
                HudLog.Line("glyph=zh icon=box-zhong size=" + IconDip);
                break;
            case "CAPS":
            case "CAPSLOCK":
            case "CAP":
            case "大写":
                ShowOnly(_iconCaps);
                HudLog.Line("glyph=caps icon=shift-uppercase size=" + IconDip);
                break;
            default:
                ShowOnly(_iconEn);
                HudLog.Line("glyph=en icon=letter-a size=" + IconDip);
                break;
        }
    }

    /// <summary>
    /// 告诉 WinUI 现在该用 Light 还是 Dark。颜色仍由 ThemeResource 出。
    /// </summary>
    public void SetRequestedTheme(bool dark)
    {
        ElementTheme next = dark ? ElementTheme.Dark : ElementTheme.Light;
        if (_root.RequestedTheme != next)
            _root.RequestedTheme = next;
        else if (!_themeResourceOk)
            BindFallbackBrushes();
    }

    void ShowOnly(FrameworkElement visible)
    {
        _iconZh.Visibility = visible == _iconZh ? Visibility.Visible : Visibility.Collapsed;
        _iconEn.Visibility = visible == _iconEn ? Visibility.Visible : Visibility.Collapsed;
        _iconCaps.Visibility = visible == _iconCaps ? Visibility.Visible : Visibility.Collapsed;
    }

    void LogThemeLookup(string reason)
    {
        bool primary = Lookup("TextFillColorPrimaryBrush") is Brush;
        HudLog.Line(
            "theme-bind reason=" + reason
            + " actual=" + _root.ActualTheme
            + " primary=" + primary
            + " xaml=" + _themeResourceOk);
    }

    object? Lookup(string key)
    {
        if (Application.Current?.Resources is { } appResources)
        {
            object? found = LookupTheme(appResources, key, _root.ActualTheme);
            if (found != null)
                return found;
        }
        return LookupTheme(_root.Resources, key, _root.ActualTheme);
    }

    static void TryAttachIslandResources(out ResourceDictionary islandResources)
    {
        islandResources = new ResourceDictionary();
        try
        {
            islandResources.MergedDictionaries.Add(new XamlControlsResources());
            HudLog.Line("island-resources-ok");
        }
        catch (Exception ex)
        {
            HudLog.Line("island-resources-failed=" + ex.GetType().Name + " " + ex.Message);
        }
    }

    static bool HasControlsResources(ResourceDictionary resources)
    {
        foreach (ResourceDictionary dict in resources.MergedDictionaries)
        {
            if (dict is XamlControlsResources)
                return true;
        }
        return false;
    }

    /// <summary>
    /// 用 XamlReader 挂真正的 {ThemeResource}。三套图标都是 stroke，和定稿 SVG 一一对应。
    /// </summary>
    static Grid? TryLoadThemeResourceTree()
    {
        const string xaml =
            """
            <Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                  Background="Transparent">
              <Viewbox x:Name="IconZh"
                       Width="20" Height="20"
                       HorizontalAlignment="Center"
                       VerticalAlignment="Center"
                       Visibility="Collapsed">
                <Canvas Width="20" Height="20">
                  <Path Data="M4.7,6.2 H15.3 V13.8 H4.7 Z"
                        Fill="Transparent"
                        Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                        StrokeThickness="1.20"
                        StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round"
                        StrokeLineJoin="Round"/>
                  <Path Data="M10,3.9 V16.1"
                        Fill="Transparent"
                        Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                        StrokeThickness="1.20"
                        StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round"
                        StrokeLineJoin="Round"/>
                </Canvas>
              </Viewbox>
              <Viewbox x:Name="IconEn"
                       Width="20" Height="20"
                       HorizontalAlignment="Center"
                       VerticalAlignment="Center"
                       Visibility="Visible">
                <Canvas Width="20" Height="20">
                  <Path Data="M5.35,15.25 L9.42,5.05 C9.62,4.55 10.38,4.55 10.58,5.05 L14.65,15.25"
                        Fill="Transparent"
                        Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                        StrokeThickness="1.32"
                        StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round"
                        StrokeLineJoin="Round"/>
                  <Path Data="M7.05,11.2 H12.95"
                        Fill="Transparent"
                        Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                        StrokeThickness="1.32"
                        StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round"
                        StrokeLineJoin="Round"/>
                </Canvas>
              </Viewbox>
              <Viewbox x:Name="IconCaps"
                       Width="20" Height="20"
                       HorizontalAlignment="Center"
                       VerticalAlignment="Center"
                       Visibility="Collapsed">
                <Canvas Width="20" Height="20">
                  <Path Data="M5.55,9.25 L10,4.8 L14.45,9.25"
                        Fill="Transparent"
                        Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                        StrokeThickness="1.32"
                        StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round"
                        StrokeLineJoin="Round"/>
                  <Path Data="M10,5.05 V13.1"
                        Fill="Transparent"
                        Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                        StrokeThickness="1.32"
                        StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round"
                        StrokeLineJoin="Round"/>
                  <Path Data="M6.45,15.0 H13.55"
                        Fill="Transparent"
                        Stroke="{ThemeResource TextFillColorPrimaryBrush}"
                        StrokeThickness="1.32"
                        StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round"
                        StrokeLineJoin="Round"/>
                </Canvas>
              </Viewbox>
            </Grid>
            """;
        try
        {
            if (XamlReader.Load(xaml) is Grid grid)
                return grid;
        }
        catch (Exception ex)
        {
            HudLog.Line("theme-xaml-failed=" + ex.GetType().Name + " " + ex.Message);
        }
        return null;
    }

    static (Grid root, FrameworkElement zh, FrameworkElement en, FrameworkElement caps) BuildFallbackTree()
    {
        Viewbox zh = WrapIcon(BuildZhIcon());
        zh.Name = "IconZh";
        zh.Visibility = Visibility.Collapsed;

        Viewbox en = WrapIcon(BuildEnIcon());
        en.Name = "IconEn";
        en.Visibility = Visibility.Visible;

        Viewbox caps = WrapIcon(BuildCapsIcon());
        caps.Name = "IconCaps";
        caps.Visibility = Visibility.Collapsed;

        var root = new Grid
        {
            Background = new SolidColorBrush(Colors.Transparent)
        };
        root.Children.Add(zh);
        root.Children.Add(en);
        root.Children.Add(caps);
        return (root, zh, en, caps);
    }

    static Viewbox WrapIcon(Canvas canvas)
    {
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

    /// <summary>
    /// CN：方框 + 竖线。定稿第二张 SVG，stroke 1.20。
    /// </summary>
    static Canvas BuildZhIcon()
    {
        var box = new XamlPath
        {
            Data = ParseGeometry("M4.7,6.2 H15.3 V13.8 H4.7 Z")
        };
        StyleStroke(box, StrokeDipZh);

        var bar = new XamlPath
        {
            Data = ParseGeometry("M10,3.9 V16.1")
        };
        StyleStroke(bar, StrokeDipZh);

        return PackCanvas(box, bar);
    }

    /// <summary>
    /// EN：字母 A，顶部带一点圆角。定稿第一张 SVG。
    /// </summary>
    static Canvas BuildEnIcon()
    {
        var body = new XamlPath
        {
            Data = ParseGeometry("M5.35,15.25 L9.42,5.05 C9.62,4.55 10.38,4.55 10.58,5.05 L14.65,15.25")
        };
        StyleStroke(body);

        var cross = new XamlPath
        {
            Data = ParseGeometry("M7.05,11.2 H12.95")
        };
        StyleStroke(cross);

        return PackCanvas(body, cross);
    }

    /// <summary>
    /// CAPS：上箭头 + 竖杆 + 底杠。定稿第三张 SVG。
    /// </summary>
    static Canvas BuildCapsIcon()
    {
        var chevron = new XamlPath
        {
            Data = ParseGeometry("M5.55,9.25 L10,4.8 L14.45,9.25")
        };
        StyleStroke(chevron);

        var stem = new XamlPath
        {
            Data = ParseGeometry("M10,5.05 V13.1")
        };
        StyleStroke(stem);

        var bar = new XamlPath
        {
            Data = ParseGeometry("M6.45,15.0 H13.55")
        };
        StyleStroke(bar);

        return PackCanvas(chevron, stem, bar);
    }

    static Canvas PackCanvas(params UIElement[] children)
    {
        var canvas = new Canvas
        {
            Width = 20,
            Height = 20
        };
        foreach (UIElement child in children)
            canvas.Children.Add(child);
        return canvas;
    }

    static void StyleStroke(Shape shape, double thickness = StrokeDip)
    {
        // 对齐 SVG：fill=none stroke=currentColor round/round。
        shape.Fill = new SolidColorBrush(Colors.Transparent);
        shape.StrokeThickness = thickness;
        shape.StrokeStartLineCap = PenLineCap.Round;
        shape.StrokeEndLineCap = PenLineCap.Round;
        shape.StrokeLineJoin = PenLineJoin.Round;
    }

    /// <summary>
    /// WinUI 没有 WPF 的 Geometry.Parse，走 XamlBindingHelper 把 mini-language 转成 Geometry。
    /// </summary>
    static Geometry ParseGeometry(string data)
    {
        return (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), data);
    }

    /// <summary>
    /// 三套图标都是 Viewbox → Canvas → Shape。只收集 Shape，方便 fallback 改 Stroke。
    /// </summary>
    void CollectStrokes(FrameworkElement icon)
    {
        if (icon is not Viewbox { Child: Canvas canvas })
            return;
        foreach (UIElement child in canvas.Children)
        {
            if (child is Shape shape)
                _strokes.Add(shape);
        }
    }

    static FrameworkElement RequireNamed(Grid root, string name)
    {
        return root.FindName(name) as FrameworkElement
            ?? throw new InvalidOperationException("缺少命名图标: " + name);
    }

    void BindFallbackBrushes()
    {
        Brush? primary = Lookup("TextFillColorPrimaryBrush") as Brush
            ?? UiColor(UIColorType.Foreground);
        if (primary == null)
            return;
        foreach (Shape shape in _strokes)
            shape.Stroke = primary;
    }

    static Brush? UiColor(UIColorType type)
    {
        try
        {
            return new SolidColorBrush(new UISettings().GetColorValue(type));
        }
        catch
        {
            return null;
        }
    }

    static object? LookupTheme(ResourceDictionary resources, string key, ElementTheme theme)
    {
        if (resources.TryGetValue(key, out object value))
            return value;

        string[] names = theme == ElementTheme.Light
            ? ["Light", "Default"]
            : ["Default", "Dark"];

        foreach (string name in names)
        {
            if (resources.ThemeDictionaries.TryGetValue(name, out object? tdObj)
                && tdObj is ResourceDictionary td
                && td.TryGetValue(key, out value))
            {
                return value;
            }
        }

        foreach (ResourceDictionary merged in resources.MergedDictionaries)
        {
            object? found = LookupTheme(merged, key, theme);
            if (found != null)
                return found;
        }

        return null;
    }
}
