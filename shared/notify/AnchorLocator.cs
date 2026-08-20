using System;
using System.IO;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Runtime.InteropServices;

namespace Lat3ncyToolbox
{
    public class AnchorLocator
    {
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

        private static int Encode(int x, int y, int sourceId)
        {
            if (x <= 0 || y <= 0 || x > 10000 || y > 10000) return 0;
            int ex = x & 0x3FFF;
            int ey = (y & 0x3FFF) << 14;
            int es = (sourceId & 0xF) << 28;
            return ex | ey | es;
        }

        [STAThread]
        public static int Main(string[] args)
        {
            try
            {
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
                                if (pt.X > 0 && pt.Y > 0 && pt.X < 10000 && pt.Y < 10000)
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
                                    if (cx > 0 && cy > 0 && cx < 10000 && cy < 10000)
                                    {
                                        return Encode(cx, cy, 2);
                                    }
                                }
                            }
                        }

                        // 2. BoundingRectangle (Focused Control / Input Box fallback)
                        System.Windows.Rect b = focused.Current.BoundingRectangle;
                        if (b.Width > 10 && b.Height > 10 && b.Width < 1920 && b.Height < 1080)
                        {
                            int cx = (int)(b.Left + b.Width / 2);
                            int cy = (int)b.Bottom;
                            if (cx > 0 && cy > 0 && cx < 10000 && cy < 10000)
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
