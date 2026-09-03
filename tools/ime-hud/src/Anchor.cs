using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Lat3ncyToolbox.ImeHud;

/// <summary>
/// 输入锚点，屏幕物理像素，指向 caret 底部。
///
/// 顺序：AHK 传入坐标 → IMM 组词窗口（跨进程 TSF 近似）→ Win32 caret →
/// UIA TextPattern → UIA 焦点矩形 → 活动窗口底部。
///
/// 不能在本进程直接调目标线程的 ITfContextView::GetTextExt：
/// ITfThreadMgr 是按线程的，HUD 进程拿不到前台应用的 document。
/// IMM IMC_GETCOMPOSITIONWINDOW 才是外部进程能用的 TSF/IME 位置。
/// </summary>
internal static class Anchor
{
    public readonly struct Result
    {
        public int X { get; init; }
        public int Y { get; init; }
        public int Height { get; init; }
        public string Source { get; init; }
        public bool Ok => X != 0 || Y != 0;
    }

    public static Result Locate(int hintX = 0, int hintY = 0)
    {
        if (hintX != 0 || hintY != 0)
            return new Result { X = hintX, Y = hintY, Height = 20, Source = "hint" };

        IntPtr hwnd = Native.GetForegroundWindow();
        Result imm = TryImmComposition(hwnd);
        if (imm.Ok)
            return imm;

        Result caret = TryWin32Caret(hwnd);
        if (caret.Ok)
            return caret;

        Result uia = TryUia();
        if (uia.Ok)
            return uia;

        return TryWindowBottom(hwnd);
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
            return new Result { X = pt.X, Y = pt.Y, Height = Math.Max(12, height), Source = "tsf-imm" };
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
            return new Result { X = pt.X, Y = pt.Y, Height = height, Source = "win32-caret" };
        }
        catch
        {
            return default;
        }
    }

    static Result TryUia()
    {
        try
        {
            AutomationElement? focused = AutomationElement.FocusedElement;
            if (focused == null)
                return default;

            if (focused.TryGetCurrentPattern(TextPattern.Pattern, out object? patternObj)
                && patternObj is TextPattern textPattern)
            {
                TextPatternRange[] sel = textPattern.GetSelection();
                if (sel is { Length: > 0 })
                {
                    TextPatternRange range = sel[0];
                    range.ExpandToEnclosingUnit(TextUnit.Character);
                    System.Windows.Rect[] rects = range.GetBoundingRectangles();
                    if (rects is { Length: > 0 } && rects[0].Height > 0)
                    {
                        int x = (int)rects[0].Left;
                        int y = (int)(rects[0].Top + rects[0].Height);
                        if (x != 0 || y != 0)
                            return new Result { X = x, Y = y, Height = (int)rects[0].Height, Source = "uia-text" };
                    }
                }
            }

            System.Windows.Rect bounds = focused.Current.BoundingRectangle;
            if (bounds.Width > 5 && bounds.Height > 5 && bounds.Height <= 200 && bounds.Width < 8000)
            {
                int x = (int)(bounds.Left + bounds.Width / 2);
                int y = (int)bounds.Bottom;
                if (x != 0 || y != 0)
                    return new Result { X = x, Y = y, Height = (int)bounds.Height, Source = "uia-focus" };
            }
        }
        catch
        {
            // 部分沙箱/提升进程里 UIA 会抛，忽略后走窗口底部。
        }
        return default;
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
                Source = "window-bottom"
            };
        }
        catch
        {
            return default;
        }
    }
}
