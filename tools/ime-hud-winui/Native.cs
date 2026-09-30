using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 自己管 HWND：WS_POPUP + NOACTIVATE + TOOLWINDOW。
/// WinUI 只作为 Island 内容层。Island 接管 SystemBackdrop 时宿主改 DWMSBT_NONE。
/// 圆角只打在宿主上；站点子 HWND 的 DWM chrome 是可选尝试。
/// </summary>
internal static class Native
{
    public const int WS_POPUP = unchecked((int)0x80000000);
    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;

    public const int SW_HIDE = 0;
    public const int SW_SHOWNOACTIVATE = 4;

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOOWNERZORDER = 0x0200;

    public static readonly IntPtr HWND_TOPMOST = new(-1);

    public const int WM_DESTROY = 0x0002;
    public const int WM_MOVE = 0x0003;
    public const int WM_SIZE = 0x0005;
    public const int WM_ACTIVATE = 0x0006;
    public const int WM_CLOSE = 0x0010;
    public const int WA_INACTIVE = 0;
    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    public const uint WINEVENT_OUTOFCONTEXT = 0;
    public const uint GA_ROOT = 2;
    public const int WM_KEYDOWN = 0x0100;
    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int WM_MBUTTONDOWN = 0x0207;
    public const int WM_XBUTTONDOWN = 0x020B;
    public const int WH_MOUSE_LL = 14;
    public const int HC_ACTION = 0;
    public const int WM_SETTINGCHANGE = 0x001A;
    public const int WM_MOUSEACTIVATE = 0x0021;
    public const int WM_COPYDATA = 0x004A;
    public const int WM_NCHITTEST = 0x0084;
    public const int WM_NCACTIVATE = 0x0086;
    public const int WM_NCLBUTTONDOWN = 0x00A1;
    public const int WM_POWERBROADCAST = 0x0218;
    public const int WM_TIMER = 0x0113;
    public const int WM_IME_CONTROL = 0x0283;
    public const int WM_DPICHANGED = 0x02E0;
    public const int WM_THEMECHANGED = 0x031A;
    public const int WM_DWMCOLORIZATIONCOLORCHANGED = 0x0320;
    public const int IMC_GETCOMPOSITIONWINDOW = 0x000B;
    public const uint SMTO_ABORTIFHUNG = 0x0002;

    public const int PBT_APMRESUMESUSPEND = 0x0007;
    public const int PBT_APMRESUMEAUTOMATIC = 0x0012;

    public const int MA_NOACTIVATE = 3;
    public const int HTTRANSPARENT = -1;
    public const int HTCAPTION = 2;
    public const int VK_ESCAPE = 0x1B;

    public const int GCL_STYLE = -26;
    public const int CS_DROPSHADOW = 0x00020000;
    public const int CS_HREDRAW = 0x0002;
    public const int CS_VREDRAW = 0x0001;
    public const int IDC_ARROW = 32512;

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWA_BORDER_COLOR = 34;
    public const int DWMWA_COLOR_DEFAULT = unchecked((int)0xFFFFFFFF);
    public const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    public const int DWMWCP_DONOTROUND = 1;
    public const int DWMWCP_ROUNDSMALL = 3;
    public const int DWMSBT_NONE = 1;
    public const int DWMSBT_TRANSIENTWINDOW = 3;

    public const uint SPI_GETWORKAREA = 0x0030;
    public const uint SPI_GETHIGHCONTRAST = 0x0042;
    public const uint HCF_HIGHCONTRASTON = 0x00000001;
    public const int LOGPIXELSX = 88;
    public const int MONITOR_DEFAULTTONEAREST = 2;
    public const int MDT_EFFECTIVE_DPI = 0;
    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new(-4);

    const string PersonalizeKey =
        @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    // EVENT_SYSTEM_FOREGROUND 回调在钩子线程；调用方必须自己 marshal 回 UI 线程。
    public delegate void WinEventDelegate(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime);

    // WH_MOUSE_LL 装在有消息循环的 UI 线程上。回调里必须尽快 CallNextHookEx。
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
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
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr dwExtraInfo;
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
    public struct COPYDATASTRUCT
    {
        public IntPtr dwData;
        public int cbData;
        public IntPtr lpData;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct COMPOSITIONFORM
    {
        public uint dwStyle;
        public POINT ptCurrentPos;
        public RECT rcArea;
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct HIGHCONTRAST
    {
        public uint cbSize;
        public uint dwFlags;
        public IntPtr lpszDefaultScheme;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern ushort RegisterClassExW(ref WNDCLASSEXW lpwcx);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowExW(
        int dwExStyle,
        string lpClassName,
        string lpWindowName,
        int dwStyle,
        int x,
        int y,
        int nWidth,
        int nHeight,
        IntPtr hWndParent,
        IntPtr hMenu,
        IntPtr hInstance,
        IntPtr lpParam);

    [DllImport("user32.dll")]
    public static extern bool DestroyWindow(IntPtr hWnd);

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
    public static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern void PostQuitMessage(int nExitCode);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr SetWinEventHook(
        uint eventMin,
        uint eventMax,
        IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc,
        uint idProcess,
        uint idThread,
        uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SetWindowsHookExW(
        int idHook,
        HookProc lpfn,
        IntPtr hMod,
        uint dwThreadId);

    [DllImport("user32.dll")]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT Point);

    [DllImport("user32.dll")]
    public static extern bool PtInRect(ref RECT lprc, POINT pt);

    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [DllImport("user32.dll", EntryPoint = "GetCursorPos")]
    static extern bool TryGetCursorPos(out POINT lpPoint);

    public const uint CF_UNICODETEXT = 13;

    [DllImport("user32.dll")]
    static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll")]
    static extern bool CloseClipboard();

    [DllImport("user32.dll")]
    static extern bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll")]
    static extern IntPtr GetClipboardData(uint uFormat);

    [DllImport("user32.dll")]
    static extern bool EmptyClipboard();

    [DllImport("user32.dll")]
    static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("kernel32.dll")]
    static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll")]
    static extern IntPtr GlobalFree(IntPtr hMem);

    [DllImport("kernel32.dll")]
    static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll")]
    static extern bool GlobalUnlock(IntPtr hMem);

    const uint GMEM_MOVEABLE = 0x0002;

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
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("Shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

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
    public static extern uint SetTimer(IntPtr hWnd, UIntPtr nIDEvent, uint uElapse, IntPtr lpTimerFunc);

    [DllImport("user32.dll")]
    public static extern bool KillTimer(IntPtr hWnd, UIntPtr nIDEvent);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, out RECT pvParam, uint fWinIni);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SystemParametersInfoW")]
    public static extern bool SystemParametersInfoHighContrast(
        uint uiAction,
        uint uiParam,
        ref HIGHCONTRAST pvParam,
        uint fWinIni);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern int GetDeviceCaps(IntPtr hdc, int nIndex);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    public static extern IntPtr LoadCursor(IntPtr hInstance, int lpCursorName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")]
    public static extern IntPtr GetClassLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetClassLongPtrW")]
    public static extern IntPtr SetClassLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string? lpClassName, string? lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, ref COPYDATASTRUCT lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int attrValue, int attrSize);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS pMarInset);

    public static void TryEnablePerMonitorV2()
    {
        try
        {
            SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
        catch
        {
        }
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

    public static RECT GetPrimaryWorkArea()
    {
        RECT rect = default;
        SystemParametersInfo(SPI_GETWORKAREA, 0, out rect, 0);
        return rect;
    }

    public static bool TryGetWindowWorkArea(IntPtr hwnd, out RECT work)
    {
        work = default;
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd))
            return false;
        IntPtr monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if (monitor == IntPtr.Zero)
            return false;
        MONITORINFO info = new() { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(monitor, ref info))
            return false;
        work = info.rcWork;
        return work.Width > 0 && work.Height > 0;
    }

    public static RECT GetWorkAreaFromPoint(int x, int y)
    {
        var pt = new POINT { X = x, Y = y };
        IntPtr monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info))
            return info.rcWork;
        return GetPrimaryWorkArea();
    }

    /// <summary>
    /// 只报告“现在”的光标，不能当成快捷键按下时的 MouseAtHotkey。
    /// </summary>
    public static POINT GetCursorPos()
    {
        return TryGetCursorPos(out POINT pt) ? pt : default;
    }

    public static bool TryReadLowLevelMousePoint(IntPtr lParam, out POINT pt)
    {
        pt = default;
        if (lParam == IntPtr.Zero)
            return false;
        try
        {
            var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            pt = info.pt;
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// 只在调用方明确要求时读 Unicode 文本。失败返回 null，不抛。
    /// 不能把剪贴板内容当成当前选区或鼠标下文本。
    /// </summary>
    public static string? TryReadClipboardUnicode(IntPtr owner, int maxChars)
    {
        if (maxChars <= 0)
            maxChars = 4000;
        try
        {
            if (!IsClipboardFormatAvailable(CF_UNICODETEXT))
                return null;
            if (!OpenClipboard(owner))
                return null;
            try
            {
                IntPtr handle = GetClipboardData(CF_UNICODETEXT);
                if (handle == IntPtr.Zero)
                    return null;
                IntPtr data = GlobalLock(handle);
                if (data == IntPtr.Zero)
                    return null;
                try
                {
                    string? text = Marshal.PtrToStringUni(data);
                    if (string.IsNullOrEmpty(text))
                        return text;
                    return text.Length <= maxChars ? text : text[..maxChars];
                }
                finally
                {
                    GlobalUnlock(handle);
                }
            }
            finally
            {
                CloseClipboard();
            }
        }
        catch (Exception ex)
        {
            HudLog.Line("clipboard-read-failed=" + ex.GetType().Name);
            return null;
        }
    }

    /// <summary>
    /// 只在调用方明确要求时写 Unicode 文本。失败返回 false，不抛。
    /// 成功后剪贴板接管分配的内存，不要 GlobalFree。
    /// 空串 / 占位文案不要走到这里。
    /// </summary>
    public static bool TryWriteClipboardUnicode(IntPtr owner, string text)
    {
        if (string.IsNullOrEmpty(text))
            return false;
        try
        {
            if (!OpenClipboard(owner))
                return false;
            try
            {
                if (!EmptyClipboard())
                    return false;

                int bytes = (text.Length + 1) * 2;
                IntPtr handle = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)(uint)bytes);
                if (handle == IntPtr.Zero)
                    return false;

                IntPtr data = GlobalLock(handle);
                if (data == IntPtr.Zero)
                {
                    GlobalFree(handle);
                    return false;
                }

                try
                {
                    Marshal.Copy(text.ToCharArray(), 0, data, text.Length);
                    Marshal.WriteInt16(data, text.Length * 2, 0);
                }
                finally
                {
                    GlobalUnlock(handle);
                }

                // SetClipboardData 成功后内存归系统，失败才自己释放。
                if (SetClipboardData(CF_UNICODETEXT, handle) == IntPtr.Zero)
                {
                    GlobalFree(handle);
                    return false;
                }
                return true;
            }
            finally
            {
                CloseClipboard();
            }
        }
        catch (Exception ex)
        {
            HudLog.Line("clipboard-write-failed=" + ex.GetType().Name);
            return false;
        }
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

    public static int HiWord(IntPtr value) =>
        unchecked((short)((value.ToInt64() >> 16) & 0xFFFF));

    public static int LoWord(IntPtr value) =>
        unchecked((short)(value.ToInt64() & 0xFFFF));

    /// <summary>
    /// hwnd 是 root 本身，或 Island / InputSite 这种子窗口。
    /// 点面板标题栏、正文、按钮时前台可能是子 HWND，不能当成“失焦”。
    /// </summary>
    public static bool BelongsToWindow(IntPtr root, IntPtr hwnd)
    {
        if (root == IntPtr.Zero || hwnd == IntPtr.Zero)
            return false;
        if (hwnd == root)
            return true;

        try
        {
            if (GetAncestor(hwnd, GA_ROOT) == root)
                return true;
        }
        catch
        {
        }

        IntPtr current = hwnd;
        for (int i = 0; i < 16 && current != IntPtr.Zero; i++)
        {
            if (current == root)
                return true;
            try
            {
                current = GetParent(current);
            }
            catch
            {
                break;
            }
        }
        return false;
    }

    /// <summary>
    /// 点是否落在 root 窗口矩形或它的子 HWND 上。
    /// 同一应用里点别处不会换前台，前台钩子看不到；外面点击必须用这个。
    /// </summary>
    public static bool PointHitsWindow(IntPtr root, POINT pt)
    {
        if (root == IntPtr.Zero)
            return false;

        try
        {
            if (GetWindowRect(root, out RECT rect) && PtInRect(ref rect, pt))
                return true;
        }
        catch
        {
        }

        try
        {
            return BelongsToWindow(root, WindowFromPoint(pt));
        }
        catch
        {
            return false;
        }
    }

    public static bool IsMouseButtonDown(int msg)
    {
        return msg is WM_LBUTTONDOWN or WM_RBUTTONDOWN or WM_MBUTTONDOWN or WM_XBUTTONDOWN;
    }

    public static string? PtrToString(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero)
            return null;
        return Marshal.PtrToStringUni(ptr);
    }

    /// <summary>
    /// 只跟「默认应用模式」，不跟任务栏用的 Windows 模式。
    /// </summary>
    public static bool AppsUseDarkMode()
    {
        return ReadPersonalizeDword("AppsUseLightTheme", fallback: 1) == 0;
    }

    public static bool TransparencyEnabled()
    {
        return ReadPersonalizeDword("EnableTransparency", fallback: 1) == 1;
    }

    public static bool HighContrastEnabled()
    {
        try
        {
            var hc = new HIGHCONTRAST
            {
                cbSize = (uint)Marshal.SizeOf<HIGHCONTRAST>()
            };
            if (SystemParametersInfoHighContrast(SPI_GETHIGHCONTRAST, hc.cbSize, ref hc, 0))
                return (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
        }
        catch
        {
        }
        return false;
    }

    public static string GetWindowClassName(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return "";
        var sb = new StringBuilder(256);
        int n = GetClassNameW(hwnd, sb, sb.Capacity);
        return n > 0 ? sb.ToString() : "";
    }

    public static bool IsIslandVisualSite(string className)
    {
        return className is "Microsoft.UI.Content.DesktopChildSiteBridge"
            or "InputSiteWindowClass";
    }

    public static int QueryDwmCorner(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return -1;
        try
        {
            if (DwmGetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, out int value, sizeof(int)) == 0)
                return value;
        }
        catch
        {
        }
        return -1;
    }

    public static void ForEachTopLevelWindow(Action<IntPtr> action)
    {
        var windows = new List<IntPtr>();
        EnumWindowsProc callback = (hWnd, _) =>
        {
            windows.Add(hWnd);
            return true;
        };
        try
        {
            EnumWindows(callback, IntPtr.Zero);
        }
        catch
        {
            return;
        }
        GC.KeepAlive(callback);
        foreach (IntPtr hwnd in windows)
            action(hwnd);
    }

    public static void ForEachChildWindow(IntPtr parent, Action<IntPtr> action)
    {
        if (parent == IntPtr.Zero)
            return;

        var children = new List<IntPtr>();
        EnumWindowsProc callback = (hWnd, _) =>
        {
            children.Add(hWnd);
            return true;
        };
        try
        {
            EnumChildWindows(parent, callback, IntPtr.Zero);
        }
        catch
        {
            return;
        }
        GC.KeepAlive(callback);
        foreach (IntPtr child in children)
            action(child);
    }

    static int ReadPersonalizeDword(string name, int fallback)
    {
        try
        {
            object? value = Registry.GetValue(PersonalizeKey, name, fallback);
            return value is int i ? i : fallback;
        }
        catch
        {
            return fallback;
        }
    }

    public static void DisableDropShadow(IntPtr hwnd)
    {
        try
        {
            IntPtr style = GetClassLongPtr(hwnd, GCL_STYLE);
            long next = style.ToInt64() & ~CS_DROPSHADOW;
            if (next == style.ToInt64())
                return;
            SetClassLongPtr(hwnd, GCL_STYLE, new IntPtr(next));
        }
        catch
        {
        }
    }

    public static void ApplyDwmChrome(IntPtr hwnd, bool? dark = null, int? backdrop = null)
    {
        if (hwnd == IntPtr.Zero)
            return;

        bool useDark = dark ?? AppsUseDarkMode();
        int backdropType = backdrop ?? DWMSBT_TRANSIENTWINDOW;

        try
        {
            int darkMode = useDark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int));
        }
        catch { }

        try
        {
            DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdropType, sizeof(int));
        }
        catch { }

        try
        {
            int corner = HighContrastEnabled() ? DWMWCP_DONOTROUND : DWMWCP_ROUNDSMALL;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
        }
        catch { }

        try
        {
            int border = DWMWA_COLOR_DEFAULT;
            DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
        }
        catch { }

        try
        {
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

        DisableDropShadow(hwnd);
    }

    /// <summary>
    /// 可选：给 Island 站点 HWND 再打一次 DWM chrome。
    /// 实测子窗口不接受 ROUNDSMALL，真正裁圆的是宿主。不要 SetWindowRgn。
    /// </summary>
    public static void ApplyIslandSiteChrome(IntPtr hwnd, bool? dark = null)
    {
        if (hwnd == IntPtr.Zero)
            return;
        if (!IsIslandVisualSite(GetWindowClassName(hwnd)))
            return;

        bool useDark = dark ?? AppsUseDarkMode();
        int backdropType = DWMSBT_NONE;
        int corner = HighContrastEnabled() ? DWMWCP_DONOTROUND : DWMWCP_ROUNDSMALL;

        try
        {
            int darkMode = useDark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int));
        }
        catch { }

        try
        {
            DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdropType, sizeof(int));
        }
        catch { }

        try
        {
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
        }
        catch { }

        try
        {
            int border = DWMWA_COLOR_DEFAULT;
            DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
        }
        catch { }

        try
        {
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

        DisableDropShadow(hwnd);
    }

    public static void ShowNoActivate(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return;

        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    public static void HideNoActivate(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return;
        ShowWindow(hwnd, SW_HIDE);
    }

    public static string? ReadCopyData(IntPtr lParam)
    {
        if (lParam == IntPtr.Zero)
            return null;
        var cds = Marshal.PtrToStructure<COPYDATASTRUCT>(lParam);
        if (cds.lpData == IntPtr.Zero || cds.cbData <= 0)
            return null;
        int chars = cds.cbData / 2;
        return Marshal.PtrToStringUni(cds.lpData, chars);
    }
}
