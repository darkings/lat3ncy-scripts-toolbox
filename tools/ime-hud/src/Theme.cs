using System.Windows.Media;
using Microsoft.Win32;

namespace Lat3ncyToolbox.ImeHud;

/// <summary>
/// 深浅色跟随 AppsUseLightTheme。配色贴近 Win11 微软拼音候选条：
/// 深色半透明黑底、浅色半透明白底，小字靠高不透明度保住对比度。
/// 颜色由 HUD 自己读系统，AHK 不传色值。
/// </summary>
internal sealed class Theme
{
    public bool IsDark { get; }
    public Color Fill { get; }
    public Color Text { get; }
    public Color Hairline { get; }
    public int BorderDwm { get; }

    Theme(bool isDark)
    {
        IsDark = isDark;
        if (isDark)
        {
            // 约 89% 不透明：Desktop Acrylic 还能透一点桌面，13–15 DIP 字不会发灰。
            Fill = Color.FromArgb(0xE3, 0x2C, 0x2C, 0x2C);
            Text = Color.FromRgb(0xF5, 0xF5, 0xF5);
            // 约 12% 白，避免出现 AHK HUD 那种明显灰线。
            Hairline = Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF);
            BorderDwm = 0x002E2E2E;
        }
        else
        {
            Fill = Color.FromArgb(0xF0, 0xFF, 0xFF, 0xFF);
            Text = Color.FromRgb(0x11, 0x18, 0x27);
            Hairline = Color.FromArgb(0x24, 0x00, 0x00, 0x00);
            BorderDwm = 0x00E8E8E8;
        }
    }

    public SolidColorBrush FillBrush => Freeze(new SolidColorBrush(Fill));
    public SolidColorBrush TextBrush => Freeze(new SolidColorBrush(Text));
    public SolidColorBrush HairlineBrush => Freeze(new SolidColorBrush(Hairline));

    public uint FillArgb =>
        ((uint)Fill.A << 24) | ((uint)Fill.R << 16) | ((uint)Fill.G << 8) | Fill.B;

    public static Theme Current() => new(IsAppsLightTheme() == false);

    static SolidColorBrush Freeze(SolidColorBrush brush)
    {
        if (brush.CanFreeze)
            brush.Freeze();
        return brush;
    }

    static bool IsAppsLightTheme()
    {
        try
        {
            object? value = Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme",
                0);
            return value is int i && i == 1;
        }
        catch
        {
            return false;
        }
    }
}

/// <summary>
/// 候选框式芯片的尺寸和动画。全部按 DIP，DPI 换算交给 HWND。
/// </summary>
internal static class StateVisual
{
    public const double WidthDip = 38;
    public const double HeightDip = 30;
    public const double ChineseFontDip = 13.5;
    public const double LatinFontDip = 14.5;
    public const double AnchorGapDip = 7;
    public const int DefaultDurationMs = 750;
    public const int MinDurationMs = 650;
    public const int MaxDurationMs = 900;
    public const int ShowAnimMs = 90;
    public const int HideAnimMs = 110;

    public static (string Glyph, string FontFamily, bool Caps) For(Protocol.ImeState state)
    {
        return state switch
        {
            // 中文用微软雅黑 UI；英文 / 大写用 Segoe UI Variable Text，字号略大一档。
            Protocol.ImeState.Chinese => ("中", "Microsoft YaHei UI", false),
            Protocol.ImeState.English => ("A", "Segoe UI Variable Text", false),
            // 大写仍显示 A，但 HUD 会加一条底线，避免做成彩色 Badge 或 Fluent 图标。
            Protocol.ImeState.Caps => ("A", "Segoe UI Variable Text", true),
            _ => ("?", "Segoe UI", false)
        };
    }

    public static int ClampDuration(int durationMs)
    {
        if (durationMs <= 0)
            return DefaultDurationMs;
        if (durationMs < MinDurationMs)
            return MinDurationMs;
        if (durationMs > MaxDurationMs)
            return MaxDurationMs;
        return durationMs;
    }
}
