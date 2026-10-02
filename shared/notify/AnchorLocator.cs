using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Lat3ncyToolbox
{
    /// <summary>
    /// 输入锚点定位器。只输出“真实光标”优先的锚点，并在输出里带上来源，
    /// 让调用方能区分「跟光标」和「退化到窗口底部」。
    ///
    /// 输出（stdout，单行）：
    ///     OK|&lt;x&gt;|&lt;y&gt;|&lt;width&gt;|&lt;height&gt;|&lt;source&gt;|&lt;caretHeight&gt;
    ///     ERR|&lt;reason&gt;
    /// source：text-caret / imm-caret / win32-caret 为真实光标；
    ///         focus-text / focus-bounds / target-window-bottom / target-monitor-fallback 为退化来源。
    /// 兼容旧格式：不带 --ar 时打印 `x|y|source`。
    ///
    /// --watch 跟随模式（每行 flush）：
    ///     A|&lt;x&gt;|&lt;y&gt;|&lt;caretHeight&gt;|&lt;source&gt;  光标位置，变化时才输出
    ///     L|&lt;reason&gt;                             目标窗口已不是前台，停止跟随
    ///     E|&lt;reason&gt;                             正常结束（超时）
    ///
    /// 注意：本文件由 Windows 自带的 csc.exe（C# 5）编译，
    /// 只能用 C# 5 语法：不要用字符串内插、空条件运算符、out var、表达式体成员。
    /// </summary>
    internal static class AnchorLocator
    {
        private const int COORD_BIAS = 2;
        private const uint GA_ROOT = 2;
        private const int WM_IME_CONTROL = 0x0283;
        private const int IMC_GETCOMPOSITIONWINDOW = 0x000B;
        private const uint SMTO_ABORTIFHUNG = 0x0002;

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
        private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out POINT point);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(POINT point, uint flags);

        [DllImport("user32.dll")]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int maxCount);


        [DllImport("imm32.dll")]
        private static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
        private static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            int msg,
            IntPtr wParam,
            ref COMPOSITIONFORM lParam,
            uint flags,
            uint timeout,
            out IntPtr result);

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                SetProcessDpiAwarenessContext(new IntPtr(-4));
            }
            catch (Exception)
            {
                try
                {
                    SetProcessDPIAware();
                }
                catch (Exception)
                {
                }
            }

            if (HasFlag(args, "--self-test"))
                return SelfTest();

            bool structured = HasFlag(args, "--ar") || HasFlag(args, "--anchor-result");
            IntPtr target = ParseHwnd(args);
            if (target == IntPtr.Zero)
                target = GetForegroundWindow();

            if (HasFlag(args, "--watch"))
            {
                int interval = ReadIntOption(args, "--interval", 110, 40, 1000);
                int duration = ReadIntOption(args, "--duration", 1100, 200, 10000);
                return Watch(target, structured, interval, duration);
            }
            Probe probe = Locate(target);

            // --diagnose：把「为什么不是真光标」也打出来，方便定位
            // Chromium 这类不暴露 TextPattern 的应用。
            if (HasFlag(args, "--diagnose"))
            {
                var titleBuf = new StringBuilder(512);
                GetWindowTextW(target, titleBuf, titleBuf.Capacity);
                var classBuf = new StringBuilder(256);
                GetClassNameW(target, classBuf, classBuf.Capacity);
                RECT targetRect;
                GetWindowRect(target, out targetRect);
                Console.WriteLine("target=0x" + target.ToInt64().ToString("X")
                    + " class=" + classBuf.ToString()
                    + " title=" + titleBuf.ToString());
                Console.WriteLine("target-rect=" + targetRect.Left + "," + targetRect.Top
                    + " " + (targetRect.Right - targetRect.Left) + "x" + (targetRect.Bottom - targetRect.Top));
                Console.WriteLine("anchor=" + (probe.Ok ? probe.Source : "none")
                    + " real=" + (probe.Ok && IsRealCaretSource(probe.Source) ? 1 : 0)
                    + " x=" + Int(probe.X) + " y=" + Int(probe.Y));
                Console.WriteLine("text-caret-reason=" + (s_textCaretReason.Length > 0 ? s_textCaretReason : "ok"));
                Console.WriteLine("imm-reason=" + (s_immReason.Length > 0 ? s_immReason : "not-tried"));
            }

            Console.WriteLine(FormatLine(probe, structured));
            return probe.Ok ? 0 : 2;
        }

        private struct Probe
        {
            public int X;
            public int Y;
            public int Width;
            public int Height;
            public int CaretHeight;
            public string Source;
            public string Reason;

            public bool Ok
            {
                get { return !string.IsNullOrEmpty(Source); }
            }
        }

        public static bool IsRealCaretSource(string source)
        {
            if (source == "text-caret" || source == "imm-caret" || source == "win32-caret"
                || source == "value-caret")
                return true;
            return false;
        }

        // ================= 主链路 =================

        private static Probe Locate(IntPtr target)
        {
            if (target == IntPtr.Zero || !IsWindow(target))
            {
                Probe missing = new Probe();
                missing.Reason = "no-target-window";
                return missing;
            }

            // L1：TSF/UIA 文本光标。Chromium、Windows Terminal、WinUI3、VS Code 只能走这条。
            // Chromium 的无障碍树是延迟建的：第一次查询往往只拿到顶层窗口，
            // 隔几百毫秒再查就能拿到真正的 Edit 插入点。必须重试，否则会误判成"没有光标"。
            Probe text = TryTextCaretWithRetry(target);
            if (text.Ok)
                return text;

            // L1b：IMM 组词窗口。
            // 注意：Chromium 系应用的光标不走这里——它们只在「被认可的辅助技术客户端」
            // 面前建内容树，实测只有 PowerShell 宿主能读到插入点，所以那条路放在
            // AHK 侧（shared/notify/ime-hud.ahk 起 caret-uia.ps1 常驻助手）。
            // 本 exe 里再 spawn 一次 PowerShell 实测拿不到结果，已删除。
            Probe imm = TryImmComposition(target);
            if (imm.Ok)
                return imm;

            // L3：经典 Win32 caret（传统 Edit / RichEdit 控件）。
            Probe win32 = TryWin32Caret(target);
            if (win32.Ok)
                return win32;

            // L4：聚焦文本框本身（不是光标，但比整窗底部精确）。
            Probe focusText = TryFocusedTextBounds(target);
            if (focusText.Ok)
                return focusText;

            // L5：聚焦元素矩形。
            Probe focusBounds = TryFocusedBounds(target);
            if (focusBounds.Ok)
                return focusBounds;

            // L6/L7：窗口底部 / 显示器兜底。
            Probe bottom = TryWindowBottom(target);
            if (bottom.Ok)
                return bottom;

            return TryMonitorFallback(target);
        }

        /// <summary>
        /// 跟随模式。只输出真实光标来源；拿不到就输出 E|timeout-no-caret，
        /// 让调用方保持原锚点，不把退化坐标当成“跟随”。
        /// </summary>
        private static int Watch(IntPtr target, bool structured, int interval, int duration)
        {
            if (target == IntPtr.Zero || !IsWindow(target))
            {
                Console.WriteLine("L|no-target-window");
                return 2;
            }

            bool pushedAny = false;
            int lastX = int.MinValue;
            int lastY = int.MinValue;
            int lastHeight = int.MinValue;
            string lastSource = "";
            int deadline = Environment.TickCount + duration;
            while (Environment.TickCount < deadline)
            {
                IntPtr foreground = GetForegroundWindow();
                if (foreground != IntPtr.Zero && foreground != target
                    && !BelongsTo(foreground, target) && !BelongsTo(target, foreground))
                {
                    Console.WriteLine("L|foreground-changed");
                    Console.Out.Flush();
                    return 0;
                }

                // 跟随期间不要走完整的 Locate：它带重试和 helper 冷启动，
                // 一轮可能要 1.5s，跟不上。先用进程内的快路径，拿不到再让
                // helper 自己在一次进程里连续推位置（见 WatchViaHelper）。
                Probe probe = new Probe();
                Probe fast = TryTextCaret(target);
                if (fast.Ok && IsRealCaretSource(fast.Source))
                    probe = fast;
                else
                {
                    Probe win32 = TryWin32Caret(target);
                    if (win32.Ok)
                        probe = win32;
                }

                if (probe.Ok && IsRealCaretSource(probe.Source)
                    && (probe.X != lastX || probe.Y != lastY || probe.CaretHeight != lastHeight || probe.Source != lastSource))
                {
                    Console.WriteLine("A|" + Int(probe.X) + "|" + Int(probe.Y) + "|" + Int(Math.Max(0, probe.CaretHeight)) + "|" + probe.Source);
                    Console.Out.Flush();
                    lastX = probe.X;
                    lastY = probe.Y;
                    lastHeight = probe.CaretHeight;
                    lastSource = probe.Source;
                    pushedAny = true;
                }

                Thread.Sleep(Math.Max(20, interval));
            }

            Console.WriteLine(pushedAny ? "E|timeout-followed" : "E|timeout-no-caret");
            Console.Out.Flush();
            return 0;
        }


        private static string FormatLine(Probe probe, bool structured)
        {
            if (!probe.Ok)
                return structured ? "ERR|" + probe.Reason : "1|1|" + probe.Reason;
            if (structured)
                return FormatStructured(probe);
            return Int(probe.X) + "|" + Int(probe.Y) + "|" + probe.Source;
        }

        private static string FormatStructured(Probe probe)
        {
            return "OK|" + Int(probe.X) + "|" + Int(probe.Y) + "|" + Int(probe.Width) + "|" +
                Int(probe.Height) + "|" + probe.Source + "|" + Int(Math.Max(0, probe.CaretHeight));
        }

        private static string Int(int value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }

        public static bool HasFlag(string[] args, string flag)
        {
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] != null && string.Equals(args[i], flag, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            return false;
        }

        private static IntPtr ParseHwnd(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i] == null ? "" : args[i];
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

        private static int ReadIntOption(string[] args, string name, int fallback, int min, int max)
        {
            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i] == null ? "" : args[i];
                string value = "";
                if (arg.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
                    value = arg.Substring(name.Length + 1);
                else if (string.Equals(arg, name, StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                    value = args[i + 1];
                int parsed;
                if (value.Length > 0 && int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                    return Math.Max(min, Math.Min(max, parsed));
            }
            return fallback;
        }

        /// <summary>
        /// 子窗口归到顶层窗口。祖先链比较，不能只用 IsChild：
        /// 传进来的 target 经常本身就是顶层窗口。
        /// </summary>
        private static bool BelongsTo(IntPtr child, IntPtr root)
        {
            if (child == IntPtr.Zero || root == IntPtr.Zero)
                return false;
            if (child == root)
                return true;
            if (IsChild(root, child))
                return true;
            IntPtr childRoot = GetAncestor(child, GA_ROOT);
            IntPtr targetRoot = GetAncestor(root, GA_ROOT);
            return childRoot != IntPtr.Zero && childRoot == targetRoot;
        }

        private static bool InsideWindow(IntPtr hwnd, int x, int y)
        {
            RECT rect;
            if (!GetWindowRect(hwnd, out rect))
                return true;
            return x >= rect.Left - 2 && x <= rect.Right + 2 && y >= rect.Top - 2 && y <= rect.Bottom + 2;
        }

        // ================= L1：TSF / UIA 文本光标 =================

        /// <summary>
        /// 最近一次拿不到文本光标的原因，写进 ERR 行方便定位。
        /// 例如 Chromium 没开无障碍时是 "no-textpattern"。
        /// </summary>
        private static string s_textCaretReason = "";

        /// <summary>
        /// Chromium 的辅助功能树按需延迟建立：第一轮探测常常只返回顶层窗口，
        /// 之后才出现真正的文本控件。这里重试若干次，命中即返回。
        /// 实测（DSH / Chromium）：第 2 次、间隔约 250ms 就能拿到 Edit 的插入点。
        /// </summary>
        private static Probe TryTextCaretWithRetry(IntPtr target)
        {
            const int maxAttempts = 3;
            const int delayMs = 250;

            Probe best = new Probe();
            for (int attempt = 1; attempt <= maxAttempts; attempt++)
            {
                Probe probe = TryTextCaret(target);
                if (probe.Ok && IsRealCaretSource(probe.Source))
                    return probe;
                if (probe.Ok && !best.Ok)
                    best = probe;
                if (attempt < maxAttempts)
                    Thread.Sleep(delayMs);
            }
            return best;
        }

        /// <summary>最近一次 IMM 组词窗口探测结果，诊断用。</summary>
        private static string s_immReason = "";


        /// <summary>
        /// 只接受真实文本插入点。任何“整窗/整控件矩形”一律拒绝，
        /// 因为那正是 Chromium 下退化到窗口底部的原因。
        /// </summary>
        private static Probe TryTextCaret(IntPtr target)
        {
            Probe none = new Probe();
            s_textCaretReason = "";

            RECT windowRect;
            bool hasWindowRect = GetWindowRect(target, out windowRect);
            int maxInset = 200;
            if (hasWindowRect)
            {
                int windowHeight = windowRect.Bottom - windowRect.Top;
                maxInset = Math.Max(120, Math.Min(windowHeight / 3, 600));
            }

            AutomationElement element = null;
            try
            {
                // Chromium 的无障碍树是延迟建的：第一轮通常只有顶层窗口 + 渲染宿主，
                // 隔几百毫秒再查才会出现真正的 Edit 插入点（所以外面有重试）。
                AutomationElement root = AutomationElement.FromHandle(target);

                // 目标窗口自己的输入控件优先。它不依赖全局焦点：
                // 别的窗口抢了前台时，这里仍然能查到目标窗口的插入点。
                element = FindEditElement(root);
                if (element == null)
                    element = FindTextFocusedElement(root);
                if (element == null)
                    element = AutomationElement.FocusedElement;
            }
            catch (Exception ex)
            {
                s_textCaretReason = "uia-error:" + ex.GetType().Name;
                return none;
            }

            if (element == null)
            {
                s_textCaretReason = "no-focused-element";
                return none;
            }

            bool hasTextPattern = SupportsTextPattern(element);
            Rect caret = FindCaretRect(element);
            if (double.IsNaN(caret.Left) || caret.Height <= 0)
            {
                // 这是 Chromium 的典型结果：焦点元素要么是顶层窗口，
                // 要么是 Chrome_RenderWidgetHostHWND，都不带 TextPattern。
                s_textCaretReason = "no-textpattern elem=" + DescribeElement(element)
                    + " hasPattern=" + (hasTextPattern ? 1 : 0);
                return none;
            }

            int x = (int)Math.Round(caret.Left);
            int y = (int)Math.Round(caret.Top + caret.Height);
            int caretHeight = (int)Math.Round(caret.Height);

            // 防误判：退化的“整窗前 N 像素”结果必须丢掉。
            if (hasWindowRect)
            {
                if (caret.Top - windowRect.Top > maxInset || windowRect.Bottom - caret.Bottom > maxInset)
                {
                    s_textCaretReason = "caret-far-from-window";
                    return none;
                }
                if (caret.Height > (windowRect.Bottom - windowRect.Top) / 2)
                {
                    s_textCaretReason = "caret-too-tall";
                    return none;
                }
                if (!InsideWindow(target, x, y))
                {
                    s_textCaretReason = "caret-outside-window";
                    return none;
                }
            }

            Probe probe = new Probe();
            probe.X = x;
            probe.Y = y;
            probe.Width = Math.Max(1, (int)Math.Round(caret.Width));
            probe.Height = 0;
            probe.CaretHeight = caretHeight;
            probe.Source = "text-caret";
            return probe;
        }

        /// <summary>给诊断用：焦点元素长什么样。</summary>
        private static string DescribeElement(AutomationElement element)
        {
            try
            {
                string type = element.Current.ControlType == null
                    ? "?"
                    : element.Current.ControlType.ProgrammaticName.Replace("ControlType.", "");
                string cls = element.Current.ClassName == null ? "" : element.Current.ClassName;
                string name = element.Current.Name == null ? "" : element.Current.Name;
                if (name.Length > 24)
                    name = name.Substring(0, 24);
                Rect bounds = element.Current.BoundingRectangle;
                return type + "/" + cls + "/(w" + (int)bounds.Width + "h" + (int)bounds.Height + ")"
                    + (name.Length > 0 ? "/" + name : "");
            }
            catch (Exception)
            {
                return "<unreadable>";
            }
        }

        /// <summary>
        /// 先从 window 往下找带键盘焦点 / TextPattern 的元素。
        /// Chromium 的 FocusedElement 经常只返回顶层窗口，必须自己走树。
        /// </summary>
        private static AutomationElement FindTextFocusedElement(AutomationElement root)
        {
            if (root == null)
                return null;

            AutomationElement focused = FindByKeyboardFocus(root, 0, 24);
            if (focused != null)
                return focused;

            return FindTextPatternElement(root, 0, 24);
        }

        private static AutomationElement FindByKeyboardFocus(AutomationElement element, int depth, int budget)
        {
            if (element == null || depth > 6 || budget <= 0)
                return null;
            try
            {
                // 不要用 IsKeyboardFocusable 过滤：Chromium 的元素经常报 false。
                // HasKeyboardFocus 最可靠；拿不到时才退一步接受可聚焦的文本控件。
                if (element.Current.HasKeyboardFocus)
                    return element;
                if (element.Current.IsKeyboardFocusable
                    && element.Current.ControlType == ControlType.Edit
                    && SupportsTextPattern(element))
                    return element;
            }
            catch (Exception)
            {
                return null;
            }

            return WalkChildren(element, depth, budget, true);
        }

        private static AutomationElement FindTextPatternElement(AutomationElement element, int depth, int budget)
        {
            if (element == null || depth > 6 || budget <= 0)
                return null;
            if (SupportsTextPattern(element))
                return element;

            return WalkChildren(element, depth, budget, false);
        }

        /// <summary>
        /// 找目标窗口里的输入控件（Edit / Document + TextPattern）。
        /// 不依赖全局焦点：Chromium 里就算别的窗口抢了前台，
        /// 目标窗口的 UIA 树仍然能查到它自己的输入控件。
        /// </summary>
        private static AutomationElement FindEditElement(AutomationElement root)
        {
            if (root == null)
                return null;
            return FindEditElementCore(root, 0, 64, null);
        }

        private static AutomationElement FindEditElementCore(
            AutomationElement element, int depth, int budget, AutomationElement first)
        {
            if (element == null || depth > 8 || budget <= 0)
                return first;
            try
            {
                if (SupportsTextPattern(element))
                {
                    bool isEdit = element.Current.ControlType == ControlType.Edit
                        || element.Current.ControlType == ControlType.Document;
                    if (isEdit && first == null)
                        first = element;
                    if (isEdit && element.Current.HasKeyboardFocus)
                        return element;
                }
            }
            catch (Exception)
            {
                return first;
            }

            TreeWalker walker = TreeWalker.ControlViewWalker;
            AutomationElement child;
            try
            {
                child = walker.GetFirstChild(element);
            }
            catch (Exception)
            {
                return first;
            }

            int remaining = budget;
            while (child != null && remaining > 0)
            {
                AutomationElement hit = FindEditElementCore(child, depth + 1, remaining - 1, first);
                if (hit != null && hit != first)
                    return hit;
                first = hit ?? first;
                try
                {
                    child = walker.GetNextSibling(child);
                }
                catch (Exception)
                {
                    break;
                }
                remaining--;
            }
            return first;
        }

        private static AutomationElement WalkChildren(AutomationElement element, int depth, int budget, bool focusLookup)
        {
            TreeWalker walker = TreeWalker.ControlViewWalker;
            AutomationElement child;
            try
            {
                child = walker.GetFirstChild(element);
            }
            catch (Exception)
            {
                return null;
            }

            int remaining = budget;
            while (child != null && remaining > 0)
            {
                AutomationElement hit = focusLookup
                    ? FindByKeyboardFocus(child, depth + 1, remaining - 1)
                    : FindTextPatternElement(child, depth + 1, remaining - 1);
                if (hit != null)
                    return hit;
                try
                {
                    child = walker.GetNextSibling(child);
                }
                catch (Exception)
                {
                    break;
                }
                remaining--;
            }
            return null;
        }

        private static bool SupportsTextPattern(AutomationElement element)
        {
            try
            {
                object pattern;
                return element.TryGetCurrentPattern(TextPattern.Pattern, out pattern);
            }
            catch (Exception)
            {
                return false;
            }
        }

        /// <summary>
        /// 先 TextPattern2.GetCaretRange（真正的插入点），再退回 TextPattern.GetSelection。
        /// </summary>
        private static Rect FindCaretRect(AutomationElement element)
        {
            Rect fromCaretRange = TryPattern2CaretRange(element);
            if (!double.IsNaN(fromCaretRange.Left))
                return fromCaretRange;

            try
            {
                object patternObject;
                if (!element.TryGetCurrentPattern(TextPattern.Pattern, out patternObject))
                    return EmptyRect();
                TextPattern pattern = patternObject as TextPattern;
                if (pattern == null)
                    return EmptyRect();

                TextPatternRange[] ranges = pattern.GetSelection();
                if (ranges == null || ranges.Length == 0 || ranges[0] == null)
                    return EmptyRect();

                return LastUsableRect(ranges[0].GetBoundingRectangles());
            }
            catch (Exception)
            {
                return EmptyRect();
            }
        }

        /// <summary>
        /// 真正的插入点：TextPattern2.GetCaretRange。TextPattern2 不是所有
        /// .NET Framework / Windows 版本都有，所以用反射拿，缺失时静默退到 GetSelection。
        /// </summary>
        private static Rect TryPattern2CaretRange(AutomationElement element)
        {
            try
            {
                object patternObject;
                if (!element.TryGetCurrentPattern(TextPattern.Pattern, out patternObject) || patternObject == null)
                    return EmptyRect();

                System.Reflection.MethodInfo method = patternObject.GetType().GetMethod(
                    "GetCaretRange",
                    new Type[] { typeof(bool).MakeByRefType() });
                if (method == null)
                    return EmptyRect();

                object[] callArgs = new object[] { false };
                object rangeObject = method.Invoke(patternObject, callArgs);
                TextPatternRange range = rangeObject as TextPatternRange;
                if (range == null)
                    return EmptyRect();
                return LastUsableRect(range.GetBoundingRectangles());
            }
            catch (Exception)
            {
                return EmptyRect();
            }
        }

        /// <summary>
        /// 折叠光标的矩形高度可能是 0，取范围内最后一个有效矩形。
        /// </summary>
        private static Rect LastUsableRect(Rect[] rectangles)
        {
            if (rectangles == null || rectangles.Length == 0)
                return EmptyRect();
            Rect best = EmptyRect();
            for (int i = 0; i < rectangles.Length; i++)
            {
                Rect rect = rectangles[i];
                if (rect.IsEmpty || rect.Height <= 0)
                    continue;
                best = rect;
            }
            return best;
        }

        private static Rect EmptyRect()
        {
            return new Rect(double.NaN, double.NaN, 0, 0);
        }

        // ================= L2：IMM 组词窗口 =================

        private static Probe TryImmComposition(IntPtr hwnd)
        {
            Probe none = new Probe();
            s_immReason = "";
            try
            {
                IntPtr ime = ImmGetDefaultIMEWnd(hwnd);
                if (ime == IntPtr.Zero)
                {
                    s_immReason = "no-ime-window";
                    return none;
                }

                COMPOSITIONFORM form = new COMPOSITIONFORM();
                form.dwStyle = 0;
                form.ptCurrentPos = new POINT();
                form.rcArea = new RECT();
                IntPtr result;
                IntPtr sent = SendMessageTimeout(
                    ime, WM_IME_CONTROL, new IntPtr(IMC_GETCOMPOSITIONWINDOW), ref form,
                    SMTO_ABORTIFHUNG, 50, out result);
                if (sent == IntPtr.Zero)
                {
                    s_immReason = "IMC_GETCOMPOSITIONWINDOW=failed";
                    return none;
                }

                int areaHeight = form.rcArea.Bottom - form.rcArea.Top;
                if (form.ptCurrentPos.X == 0 && form.ptCurrentPos.Y == 0 && areaHeight == 0)
                {
                    s_immReason = "empty-composition-form";
                    return none;
                }

                uint processId;
                uint tid = GetWindowThreadProcessId(hwnd, out processId);
                GUITHREADINFO gui = new GUITHREADINFO();
                gui.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
                IntPtr focusWindow = hwnd;
                if (tid != 0 && GetGUIThreadInfo(tid, ref gui) && gui.hwndFocus != IntPtr.Zero)
                    focusWindow = gui.hwndFocus;

                POINT pt = form.ptCurrentPos;
                if (areaHeight > 0)
                {
                    pt.X = form.rcArea.Left;
                    pt.Y = form.rcArea.Bottom;
                }
                if (!ClientToScreen(focusWindow, ref pt))
                {
                    s_immReason = "ClientToScreen=failed";
                    return none;
                }
                if (pt.X == 0 && pt.Y == 0)
                {
                    s_immReason = "zero-point";
                    return none;
                }

                s_immReason = "ok";
                Probe probe = new Probe();
                probe.X = pt.X;
                probe.Y = pt.Y;
                probe.Width = 2;
                probe.Height = 0;
                probe.CaretHeight = Math.Max(12, areaHeight);
                probe.Source = "imm-caret";
                return probe;
            }
            catch (Exception ex)
            {
                s_immReason = "error:" + ex.GetType().Name;
                return none;
            }
        }

        // ================= L3：Win32 caret =================

        private static Probe TryWin32Caret(IntPtr target)
        {
            Probe none = new Probe();
            try
            {
                uint processId;
                uint tid = GetWindowThreadProcessId(target, out processId);
                GUITHREADINFO info = new GUITHREADINFO();
                info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
                if (!GetGUIThreadInfo(tid, ref info) || info.hwndCaret == IntPtr.Zero)
                    return none;
                if (!BelongsTo(info.hwndCaret, target))
                    return none;
                if (info.rcCaret.Right <= info.rcCaret.Left || info.rcCaret.Bottom <= info.rcCaret.Top)
                    return none;

                POINT point = new POINT();
                point.X = info.rcCaret.Left;
                point.Y = info.rcCaret.Bottom;
                if (!ClientToScreen(info.hwndCaret, ref point))
                    return none;
                if (point.X == 0 && point.Y == 0)
                    return none;

                Probe probe = new Probe();
                probe.X = point.X;
                probe.Y = point.Y;
                probe.Width = 2;
                probe.Height = 0;
                probe.CaretHeight = Math.Max(12, info.rcCaret.Bottom - info.rcCaret.Top);
                probe.Source = "win32-caret";
                return probe;
            }
            catch (Exception)
            {
                return none;
            }
        }

        // ================= L4/L5：聚焦元素 =================

        private static Probe TryFocusedTextBounds(IntPtr target)
        {
            Probe none = new Probe();
            try
            {
                AutomationElement focused = AutomationElement.FocusedElement;
                if (focused == null || !ElementBelongsTo(focused, target))
                    return none;
                if (!SupportsTextPattern(focused))
                    return none;
                return FromElement(focused, "focus-text");
            }
            catch (Exception)
            {
                return none;
            }
        }

        private static Probe TryFocusedBounds(IntPtr target)
        {
            Probe none = new Probe();
            try
            {
                AutomationElement focused = AutomationElement.FocusedElement;
                if (focused == null || !ElementBelongsTo(focused, target))
                    return none;
                return FromElement(focused, "focus-bounds");
            }
            catch (Exception)
            {
                return none;
            }
        }

        private static Probe FromElement(AutomationElement element, string source)
        {
            Probe none = new Probe();
            Rect bounds = element.Current.BoundingRectangle;
            if (bounds.Width < 8 || bounds.Height < 8)
                return none;
            Probe probe = new Probe();
            probe.X = (int)Math.Round(bounds.Left + bounds.Width / 2);
            probe.Y = (int)Math.Round(bounds.Top + bounds.Height * 0.85);
            probe.Width = (int)Math.Round(bounds.Width);
            probe.Height = (int)Math.Round(bounds.Height);
            probe.CaretHeight = 0;
            probe.Source = source;
            return probe;
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
            catch (Exception)
            {
            }
            return false;
        }

        // ================= L6/L7：退化来源 =================

        private static Probe TryWindowBottom(IntPtr hwnd)
        {
            Probe none = new Probe();
            RECT rect;
            if (hwnd == IntPtr.Zero || !GetWindowRect(hwnd, out rect))
                return none;
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            if (width < 32 || height < 32)
                return none;
            Probe probe = new Probe();
            probe.X = rect.Left + width / 2;
            probe.Y = rect.Top + (int)(height * 0.85);
            probe.Width = width;
            probe.Height = height;
            probe.CaretHeight = 0;
            probe.Source = "target-window-bottom";
            return probe;
        }

        private static Probe TryMonitorFallback(IntPtr hwnd)
        {
            Probe none = new Probe();
            POINT point = new POINT();
            RECT rect;
            if (hwnd != IntPtr.Zero && GetWindowRect(hwnd, out rect))
            {
                point.X = rect.Left + Math.Max(0, rect.Right - rect.Left) / 2;
                point.Y = rect.Top + Math.Max(0, rect.Bottom - rect.Top) / 2;
            }
            else if (!GetCursorPos(out point))
            {
                return none;
            }
            IntPtr monitor = MonitorFromPoint(point, COORD_BIAS);
            if (monitor == IntPtr.Zero)
                return none;
            MONITORINFO info = new MONITORINFO();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfo(monitor, ref info))
                return none;
            int width = info.rcWork.Right - info.rcWork.Left;
            int height = info.rcWork.Bottom - info.rcWork.Top;
            if (width <= 0 || height <= 0)
                return none;
            Probe probe = new Probe();
            probe.X = info.rcWork.Left + width / 2;
            probe.Y = info.rcWork.Top + (int)(height * 0.82);
            probe.Width = width;
            probe.Height = height;
            probe.CaretHeight = 0;
            probe.Source = "target-monitor-fallback";
            return probe;
        }

        // ================= 自检（不碰 UIA） =================

        private static int SelfTest()
        {
            string[] realSources = new string[] { "text-caret", "imm-caret", "win32-caret" };
            for (int i = 0; i < realSources.Length; i++)
            {
                if (!IsRealCaretSource(realSources[i]))
                    return 1;
            }

            string[] degradedSources = new string[]
            {
                "focus-text", "focus-bounds", "target-window-bottom", "target-monitor-fallback"
            };
            for (int i = 0; i < degradedSources.Length; i++)
            {
                if (IsRealCaretSource(degradedSources[i]))
                    return 2;
            }

            if (IsRealCaretSource("") || IsRealCaretSource("hint"))
                return 3;

            Probe structured = new Probe();
            structured.X = 10;
            structured.Y = 20;
            structured.Width = 2;
            structured.Height = 0;
            structured.CaretHeight = 24;
            structured.Source = "text-caret";
            if (FormatStructured(structured) != "OK|10|20|2|0|text-caret|24")
                return 4;

            if (ParseHwnd(new string[] { "--hwnd", "0x20186" }).ToInt64() != 0x20186)
                return 5;
            if (ParseHwnd(new string[] { "--hwnd=12345" }).ToInt64() != 12345)
                return 6;
            if (ParseHwnd(new string[] { "0x20186" }).ToInt64() != 0)
                return 7;

            if (!double.IsNaN(EmptyRect().Left))
                return 8;

            Probe missing = new Probe();
            missing.Reason = "no-target-window";
            if (FormatLine(missing, true) != "ERR|no-target-window")
                return 9;
            if (FormatLine(missing, false) != "1|1|no-target-window")
                return 10;

            Console.WriteLine("anchor-locator self-test ok");
            return 0;
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
        private struct COMPOSITIONFORM
        {
            public int dwStyle;
            public POINT ptCurrentPos;
            public RECT rcArea;
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