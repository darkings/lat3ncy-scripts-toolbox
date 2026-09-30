using System.Runtime.InteropServices;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 输入锚点，屏幕物理像素，指向 caret 底部。
/// 顺序：传入坐标 → IMM 组词窗口 → Win32 caret → 活动窗口底部。
/// 正式 Renderer 先不接 UIA，避免再引 WPF Automation。
/// </summary>
internal static class Anchor
{
    public readonly struct Result
    {
        public int X { get; init; }
        public int Y { get; init; }
        public int Height { get; init; }
        public string Source { get; init; }
        public bool Found { get; init; }
        public bool Ok => Found || X != 0 || Y != 0;
    }

    public static Result Locate(int hintX = 0, int hintY = 0)
    {
        return Locate(hintX, hintY, 0);
    }

    public static Result Locate(int hintX, int hintY, long targetHwnd)
    {
        if (hintX != 0 || hintY != 0)
            return new Result { X = hintX, Y = hintY, Height = 20, Source = "hint", Found = true };

        IntPtr target = targetHwnd == 0 ? IntPtr.Zero : new IntPtr(targetHwnd);
        if (target != IntPtr.Zero && !Native.IsWindow(target))
            target = IntPtr.Zero;
        IntPtr hwnd = target != IntPtr.Zero ? target : Native.GetForegroundWindow();
        Result imm = TryImmComposition(hwnd);
        if (imm.Ok)
            return imm;

        Result caret = TryWin32Caret(hwnd);
        if (caret.Ok)
            return caret;

        Result bottom = TryWindowBottom(hwnd);
        if (bottom.Ok)
            return target != IntPtr.Zero
                ? new Result { X = bottom.X, Y = bottom.Y, Height = bottom.Height, Source = "target-window-bottom" }
                : bottom;
        return default;
    }

    static Result TryImmComposition(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return default;
        try
        {
            IntPtr ime = Native.ImmGetDefaultIMEWnd(hwnd);
            if (ime == IntPtr.Zero)
                return default;

            var form = new Native.COMPOSITIONFORM();
            IntPtr sent = Native.SendMessageTimeout(
                ime,
                Native.WM_IME_CONTROL,
                new IntPtr(Native.IMC_GETCOMPOSITIONWINDOW),
                ref form,
                Native.SMTO_ABORTIFHUNG,
                50,
                out _);
            if (sent == IntPtr.Zero)
                return default;
            if (form.ptCurrentPos.X == 0 && form.ptCurrentPos.Y == 0
                && form.rcArea.Width == 0 && form.rcArea.Height == 0)
                return default;

            uint tid = Native.GetWindowThreadProcessId(hwnd, out _);
            var gui = new Native.GUITHREADINFO { cbSize = Marshal.SizeOf<Native.GUITHREADINFO>() };
            IntPtr target = hwnd;
            if (tid != 0 && Native.GetGUIThreadInfo(tid, ref gui) && gui.hwndFocus != IntPtr.Zero)
                target = gui.hwndFocus;

            var pt = form.ptCurrentPos;
            if (form.rcArea.Height > 0)
            {
                pt.X = form.rcArea.Left;
                pt.Y = form.rcArea.Bottom;
            }
            if (!Native.ClientToScreen(target, ref pt))
                return default;
            if (pt.X == 0 && pt.Y == 0)
                return default;

            int height = form.rcArea.Height > 0 ? form.rcArea.Height : 20;
            return new Result { X = pt.X, Y = pt.Y, Height = Math.Max(12, height), Source = "tsf-imm", Found = true };
        }
        catch
        {
            return default;
        }
    }

    static Result TryWin32Caret(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return default;
        try
        {
            uint tid = Native.GetWindowThreadProcessId(hwnd, out _);
            if (tid == 0)
                return default;

            var gui = new Native.GUITHREADINFO
            {
                cbSize = Marshal.SizeOf<Native.GUITHREADINFO>()
            };
            if (!Native.GetGUIThreadInfo(tid, ref gui) || gui.hwndCaret == IntPtr.Zero)
                return default;

            var pt = new Native.POINT { X = gui.rcCaret.Left, Y = gui.rcCaret.Bottom };
            if (!Native.ClientToScreen(gui.hwndCaret, ref pt))
                return default;
            if (pt.X == 0 && pt.Y == 0)
                return default;

            int height = Math.Max(12, gui.rcCaret.Height);
            return new Result { X = pt.X, Y = pt.Y, Height = height, Source = "win32-caret", Found = true };
        }
        catch
        {
            return default;
        }
    }

    static Result TryWindowBottom(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return default;
        try
        {
            if (!Native.GetWindowRect(hwnd, out Native.RECT rc))
                return default;
            if (rc.Width < 50 || rc.Height < 50)
                return default;
            return new Result
            {
                X = rc.Left + rc.Width / 2,
                Y = rc.Top + (int)(rc.Height * 0.85),
                Height = 0,
                Source = "window-bottom",
                Found = true
            };
        }
        catch
        {
            return default;
        }
    }
}
