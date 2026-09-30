using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Lat3ncyToolbox
{
    internal static class AnchorLocator
    {
        private const int COORD_BIAS = 2;

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO info);

        [DllImport("user32.dll")]
        private static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

        [DllImport("user32.dll")]
        private static extern bool IsChild(IntPtr parent, IntPtr child);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out POINT point);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(POINT point, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                SetProcessDpiAwarenessContext(new IntPtr(-4));
            }
            catch
            {
                SetProcessDPIAware();
            }

            IntPtr target = ParseHwnd(args);
            if (target == IntPtr.Zero)
                target = GetForegroundWindow();

            int x;
            int y;
            string source;
            if (TryCaret(target, out x, out y))
                source = "caret";
            else if (TrySelection(target, out x, out y))
                source = "selection";
            else if (TryFocusedBounds(target, out x, out y))
                source = "focus-bounds";
            else if (TryWindowBottom(target, out x, out y))
                source = "target-window-bottom";
            else if (TryMonitorFallback(target, out x, out y))
                source = "target-monitor-fallback";
            else
                return 2;

            Console.WriteLine(x.ToString(CultureInfo.InvariantCulture) + "|" + y.ToString(CultureInfo.InvariantCulture) + "|" + source);
            return 0;
        }

        private static IntPtr ParseHwnd(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i] ?? "";
                string value = "";
                if (arg.StartsWith("--hwnd=", StringComparison.OrdinalIgnoreCase))
                    value = arg.Substring(7);
                else if (string.Equals(arg, "--hwnd", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                    value = args[++i];
                if (value.Length == 0)
                    continue;
                long parsed;
                if (value.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
                {
                    if (!long.TryParse(value.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out parsed) || parsed <= 0)
                        continue;
                    return new IntPtr(parsed);
                }
                if (!long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed) || parsed <= 0)
                    continue;
                return new IntPtr(parsed);
            }
            return IntPtr.Zero;
        }

        private static bool BelongsTo(IntPtr child, IntPtr root)
        {
            if (child == IntPtr.Zero || root == IntPtr.Zero)
                return false;
            return child == root || IsChild(root, child);
        }

        private static bool TryCaret(IntPtr target, out int x, out int y)
        {
            x = 0;
            y = 0;
            GUITHREADINFO info = new GUITHREADINFO();
            info.cbSize = Marshal.SizeOf(info);
            if (!GetGUIThreadInfo(0, ref info) || info.hwndCaret == IntPtr.Zero)
                return false;
            if (target != IntPtr.Zero && !BelongsTo(info.hwndCaret, target))
                return false;
            if (info.rcCaret.Right <= info.rcCaret.Left || info.rcCaret.Bottom <= info.rcCaret.Top)
                return false;
            POINT point = new POINT();
            point.X = info.rcCaret.Left;
            point.Y = info.rcCaret.Bottom;
            if (!ClientToScreen(info.hwndCaret, ref point))
                return false;
            x = point.X;
            y = point.Y;
            return true;
        }

        private static bool TrySelection(IntPtr target, out int x, out int y)
        {
            x = 0;
            y = 0;
            try
            {
                AutomationElement focused = AutomationElement.FocusedElement;
                if (focused == null || !ElementBelongsTo(focused, target))
                    return false;
                object patternObject;
                if (!focused.TryGetCurrentPattern(TextPattern.Pattern, out patternObject))
                    return false;
                TextPattern pattern = patternObject as TextPattern;
                if (pattern == null)
                    return false;
                TextPatternRange[] ranges = pattern.GetSelection();
                if (ranges == null || ranges.Length == 0 || ranges[0] == null)
                    return false;
                TextPatternRange range = ranges[0];
                range.ExpandToEnclosingUnit(TextUnit.Character);
                Rect[] rectangles = range.GetBoundingRectangles();
                if (rectangles == null || rectangles.Length == 0 || rectangles[0].Height <= 0)
                    return false;
                x = (int)Math.Round(rectangles[0].Left);
                y = (int)Math.Round(rectangles[0].Top + rectangles[0].Height);
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static bool TryFocusedBounds(IntPtr target, out int x, out int y)
        {
            x = 0;
            y = 0;
            try
            {
                AutomationElement focused = AutomationElement.FocusedElement;
                if (focused == null || !ElementBelongsTo(focused, target))
                    return false;
                Rect bounds = focused.Current.BoundingRectangle;
                if (bounds.Width < 8 || bounds.Height < 8)
                    return false;
                x = (int)Math.Round(bounds.Left + bounds.Width / 2);
                y = (int)Math.Round(bounds.Top + bounds.Height * 0.85);
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static bool ElementBelongsTo(AutomationElement element, IntPtr target)
        {
            if (target == IntPtr.Zero)
                return true;
            try
            {
                IntPtr native = element.Current.NativeWindowHandle != 0
                    ? new IntPtr(element.Current.NativeWindowHandle)
                    : IntPtr.Zero;
                if (native != IntPtr.Zero && BelongsTo(native, target))
                    return true;
                AutomationElement walker = element;
                for (int i = 0; i < 12 && walker != null; i++)
                {
                    int handle = walker.Current.NativeWindowHandle;
                    if (handle != 0 && BelongsTo(new IntPtr(handle), target))
                        return true;
                    walker = TreeWalker.ControlViewWalker.GetParent(walker);
                }
            }
            catch
            {
            }
            return false;
        }

        private static bool TryWindowBottom(IntPtr hwnd, out int x, out int y)
        {
            x = 0;
            y = 0;
            RECT rect;
            if (hwnd == IntPtr.Zero || !GetWindowRect(hwnd, out rect))
                return false;
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            if (width < 32 || height < 32)
                return false;
            x = rect.Left + width / 2;
            y = rect.Top + (int)(height * 0.85);
            return true;
        }

        private static bool TryMonitorFallback(IntPtr hwnd, out int x, out int y)
        {
            x = 0;
            y = 0;
            POINT point = new POINT();
            RECT rect;
            if (hwnd != IntPtr.Zero && GetWindowRect(hwnd, out rect))
            {
                point.X = rect.Left + Math.Max(0, rect.Right - rect.Left) / 2;
                point.Y = rect.Top + Math.Max(0, rect.Bottom - rect.Top) / 2;
            }
            else if (!GetCursorPos(out point))
            {
                return false;
            }
            IntPtr monitor = MonitorFromPoint(point, COORD_BIAS);
            if (monitor == IntPtr.Zero)
                return false;
            MONITORINFO info = new MONITORINFO();
            info.cbSize = Marshal.SizeOf(info);
            if (!GetMonitorInfo(monitor, ref info))
                return false;
            int width = info.rcWork.Right - info.rcWork.Left;
            int height = info.rcWork.Bottom - info.rcWork.Top;
            if (width <= 0 || height <= 0)
                return false;
            x = info.rcWork.Left + width / 2;
            y = info.rcWork.Top + (int)(height * 0.82);
            return true;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct GUITHREADINFO
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

        [StructLayout(LayoutKind.Sequential)]
        private struct MONITORINFO
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
        }
    }
}
