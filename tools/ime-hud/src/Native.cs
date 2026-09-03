using System.Runtime.InteropServices;

namespace Lat3ncyToolbox.ImeHud;

/// <summary>
/// HUD 需要的 Win32 / DWM / IMM 入口。全部集中在这里，避免 UI 代码里散落 DllImport。
/// </summary>
internal static class Native
{
    public const int WS_POPUP = unchecked((int)0x80000000);
    public const int WS_VISIBLE = 0x10000000;
    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_LAYERED = 0x00080000;

    public const int SW_HIDE = 0;
    public const int SW_SHOWNOACTIVATE = 4;

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_HIDEWINDOW = 0x0080;
    public const uint SWP_NOOWNERZORDER = 0x0200;

    public static readonly IntPtr HWND_TOPMOST = new(-1);

    public const int WM_DESTROY = 0x0002;
    public const int WM_SETTINGCHANGE = 0x001A;
    public const int WM_MOUSEACTIVATE = 0x0021;
    public const int WM_NCHITTEST = 0x0084;
    public const int WM_NCACTIVATE = 0x0086;
    public const int WM_COPYDATA = 0x004A;
    public const int WM_DPICHANGED = 0x02E0;
    public const int WM_IME_CONTROL = 0x0283;
    public const int IMC_GETCOMPOSITIONWINDOW = 0x000B;
    public const uint SMTO_ABORTIFHUNG = 0x0002;

    public const int WCA_ACCENT_POLICY = 19;
    public const int ACCENT_ENABLE_ACRYLICBLURBEHIND = 4;

    public const int MA_NOACTIVATE = 3;
    public const int HTTRANSPARENT = -1;

    public const int GCL_STYLE = -26;
    public const int CS_DROPSHADOW = 0x00020000;

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWA_BORDER_COLOR = 34;
    public const int DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);
    public const int DWMWA_SYSTEMBACKDROP_TYPE = 38;

    // 小圆角，接近微软拼音候选条上的状态芯片，而不是主窗口 8px 大圆角。
    public const int DWMWCP_ROUNDSMALL = 3;
    // Desktop Acrylic。2=Mica，4=Mica Alt，这里明确不用。
    public const int DWMSBT_TRANSIENTWINDOW = 3;

    public const int MONITOR_DEFAULTTONEAREST = 2;
    public const int LOGPIXELSX = 88;
    public const int MDT_EFFECTIVE_DPI = 0;

    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new(-4);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
        public int Width => Right - Left;
        public int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct COPYDATASTRUCT
    {
        public IntPtr dwData;
        public int cbData;
        public IntPtr lpData;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS
    {
        public int cxLeftWidth;
        public int cxRightWidth;
        public int cyTopHeight;
        public int cyBottomHeight;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct COMPOSITIONFORM
    {
        public uint dwStyle;
        public POINT ptCurrentPos;
        public RECT rcArea;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct AccentPolicy
    {
        public int AccentState;
        public int AccentFlags;
        public uint GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WindowCompositionAttributeData
    {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public int dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern int GetDeviceCaps(IntPtr hdc, int nIndex);

    [DllImport("Shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")]
    public static extern IntPtr GetClassLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetClassLongPtrW")]
    public static extern IntPtr SetClassLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS pMarInset);

    [DllImport("imm32.dll")]
    public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        int Msg,
        IntPtr wParam,
        ref COMPOSITIONFORM lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult);

    [DllImport("user32.dll")]
    public static extern int SetWindowCompositionAttribute(
        IntPtr hwnd,
        ref WindowCompositionAttributeData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string? lpClassName, string lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool PostMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, ref COPYDATASTRUCT lParam);

    public static void TryEnablePerMonitorV2()
    {
        try
        {
            if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))
                SetProcessDPIAware();
        }
        catch
        {
            try { SetProcessDPIAware(); }
            catch { /* 启动期 DPI 失败也不阻止 HUD */ }
        }
    }

    public static void EnableDropShadow(IntPtr hwnd)
    {
        try
        {
            IntPtr style = GetClassLongPtr(hwnd, GCL_STYLE);
            if ((style.ToInt64() & CS_DROPSHADOW) != 0)
                return;
            SetClassLongPtr(hwnd, GCL_STYLE, new IntPtr(style.ToInt64() | CS_DROPSHADOW));
        }
        catch
        {
            // 阴影失败只影响观感，不能让 HUD 起不来。
        }
    }

    public static void ApplyChrome(IntPtr hwnd, bool dark, int borderColor)
    {
        try
        {
            int darkMode = dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int));
        }
        catch { }

        try
        {
            int backdrop = DWMSBT_TRANSIENTWINDOW;
            DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
        }
        catch { }

        try
        {
            int corner = DWMWCP_ROUNDSMALL;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
        }
        catch { }

        try
        {
            // 关掉系统描边，内部再画 1 物理像素低对比度 hairline。
            int border = DWMWA_COLOR_NONE;
            DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
        }
        catch
        {
            try
            {
                int border = borderColor;
                DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
            }
            catch { }
        }

        try
        {
            // 负边距让 Acrylic 铺满客户区；芯片很小，靠半透明色罩保住文字对比度。
            var margins = new MARGINS
            {
                cxLeftWidth = -1,
                cxRightWidth = -1,
                cyTopHeight = -1,
                cyBottomHeight = -1
            };
            DwmExtendFrameIntoClientArea(hwnd, ref margins);
        }
        catch { }

        EnableDropShadow(hwnd);
    }

    /// <summary>
    /// Desktop Acrylic：优先 DWM TransientWindow，再补 SetWindowCompositionAttribute。
    /// 不用 Mica（SYSTEMBACKDROP=2/4）。
    /// </summary>
    public static void EnableAcrylic(IntPtr hwnd, uint argb, bool dark, int borderColor)
    {
        ApplyChrome(hwnd, dark, borderColor);
        try
        {
            uint abgr = (argb & 0xFF000000)
                | ((argb & 0x000000FF) << 16)
                | (argb & 0x0000FF00)
                | ((argb & 0x00FF0000) >> 16);
            var accent = new AccentPolicy
            {
                AccentState = ACCENT_ENABLE_ACRYLICBLURBEHIND,
                AccentFlags = 2,
                GradientColor = abgr
            };
            int size = Marshal.SizeOf<AccentPolicy>();
            IntPtr ptr = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(accent, ptr, false);
                var data = new WindowCompositionAttributeData
                {
                    Attribute = WCA_ACCENT_POLICY,
                    Data = ptr,
                    SizeOfData = size
                };
                SetWindowCompositionAttribute(hwnd, ref data);
            }
            finally
            {
                Marshal.FreeHGlobal(ptr);
            }
        }
        catch
        {
            // Acrylic 失败时仍保留 DWM 圆角/边框/阴影。
        }
    }

    public static RECT GetWorkAreaFromPoint(int x, int y)
    {
        var pt = new POINT { X = x, Y = y };
        IntPtr monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info))
            return info.rcWork;
        return new RECT { Left = 0, Top = 0, Right = 1920, Bottom = 1080 };
    }

    public static int GetDpiForPoint(int x, int y)
    {
        var pt = new POINT { X = x, Y = y };
        IntPtr monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        if (monitor != IntPtr.Zero)
        {
            try
            {
                if (GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out uint dpiX, out _) == 0 && dpiX > 0)
                    return (int)dpiX;
            }
            catch { }
        }
        return GetSystemDpi();
    }

    public static int GetSystemDpi()
    {
        IntPtr hdc = GetDC(IntPtr.Zero);
        if (hdc == IntPtr.Zero)
            return 96;
        try
        {
            int dpi = GetDeviceCaps(hdc, LOGPIXELSX);
            return dpi > 0 ? dpi : 96;
        }
        finally
        {
            ReleaseDC(IntPtr.Zero, hdc);
        }
    }

    public static int DipToPx(double dip, int dpi)
    {
        if (dpi <= 0)
            dpi = 96;
        return (int)Math.Round(dip * dpi / 96.0);
    }

    public static string? ReadCopyData(IntPtr lParam)
    {
        if (lParam == IntPtr.Zero)
            return null;
        var cds = Marshal.PtrToStructure<COPYDATASTRUCT>(lParam);
        if (cds.lpData == IntPtr.Zero || cds.cbData <= 0)
            return null;
        // AHK 发 UTF-16。cbData 可能含或不含结尾 NUL。
        int chars = cds.cbData / 2;
        return Marshal.PtrToStringUni(cds.lpData, chars);
    }
}
