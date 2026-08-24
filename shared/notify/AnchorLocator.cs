using System;
using System.IO;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Runtime.InteropServices;

namespace Lat3ncyToolbox
{
    public class AnchorLocator
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

        [DllImport("user32.dll")]
        public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X, Y; }

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

        private const int COORD_BIAS = 8192;

        private static int Encode(int x, int y, int sourceId)
        {
            int bx = x + COORD_BIAS;
            int by = y + COORD_BIAS;
            if (bx < 0 || bx > 16383 || by < 0 || by > 16383) return 0;
            int ex = bx & 0x3FFF;
            int ey = (by & 0x3FFF) << 14;
            int es = (sourceId & 0x7) << 28;
            return ex | ey | es;
        }

        [STAThread]
        public static int Main(string[] args)
        {
            try
            {
                try
                {
                    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (IntPtr)(-4)
                    if (!SetProcessDpiAwarenessContext(new IntPtr(-4)))
                    {
                        SetProcessDPIAware();
                    }
                }
                catch
                {
                }

                IntPtr targetHwnd = IntPtr.Zero;
                if (args.Length > 0)
                {
                    long val;
                    if (long.TryParse(args[0], out val))
                    {
                        targetHwnd = new IntPtr(val);
                    }
                    else if (args[0].StartsWith("0x") && long.TryParse(args[0].Substring(2), System.Globalization.NumberStyles.HexNumber, null, out val))
                    {
                        targetHwnd = new IntPtr(val);
                    }
                }
                if (targetHwnd == IntPtr.Zero)
                {
                    targetHwnd = GetForegroundWindow();
                }

                // L1: Win32 Caret
                if (targetHwnd != IntPtr.Zero)
                {
                    try
                    {
                        uint pid;
                        uint tid = GetWindowThreadProcessId(targetHwnd, out pid);
                        if (tid != 0)
                        {
                            GUITHREADINFO gui = new GUITHREADINFO();
                            gui.cbSize = Marshal.SizeOf(gui);
                            if (GetGUIThreadInfo(tid, ref gui) && gui.hwndCaret != IntPtr.Zero)
                            {
                                POINT pt = new POINT { X = gui.rcCaret.Left, Y = gui.rcCaret.Bottom };
                                ClientToScreen(gui.hwndCaret, ref pt);
                                if (pt.X >= -8000 && pt.Y >= -8000 && pt.X <= 8000 && pt.Y <= 8000)
                                {
                                    return Encode(pt.X, pt.Y, 1);
                                }
                            }
                        }
                    }
                    catch
                    {
                    }
                }

                // L2 & L3 & L4: UI Automation
                try
                {
                    AutomationElement focused = AutomationElement.FocusedElement;
                    if (focused != null)
                    {
                        // 1. TextPattern (Edge / Chrome / Windows Terminal / Notepad / VS Code)
                        object textPatObj;
                        if (focused.TryGetCurrentPattern(TextPattern.Pattern, out textPatObj))
                        {
                            TextPattern tp = (TextPattern)textPatObj;
                            TextPatternRange[] sel = tp.GetSelection();
                            if (sel != null && sel.Length > 0)
                            {
                                TextPatternRange range = sel[0];
                                range.ExpandToEnclosingUnit(TextUnit.Character);
                                System.Windows.Rect[] rects = range.GetBoundingRectangles();
                                if (rects != null && rects.Length > 0 && rects[0].Height > 0)
                                {
                                    int cx = (int)rects[0].Left;
                                    int cy = (int)(rects[0].Top + rects[0].Height);
                                    if (cx >= -8000 && cy >= -8000 && cx <= 8000 && cy <= 8000)
                                    {
                                        return Encode(cx, cy, 2);
                                    }
                                }
                            }
                        }

                        // 2. BoundingRectangle (Focused Control / Input Box fallback)
                        System.Windows.Rect b = focused.Current.BoundingRectangle;
                        if (b.Width > 5 && b.Height > 5 && b.Height <= 200 && b.Width < 8000)
                        {
                            int cx = (int)(b.Left + b.Width / 2);
                            int cy = (int)b.Bottom;
                            if (cx >= -8000 && cy >= -8000 && cx <= 8000 && cy <= 8000)
                            {
                                return Encode(cx, cy, 3);
                            }
                        }
                    }
                }
                catch
                {
                }
            }
            catch
            {
            }

            return 0;
        }
    }
}
