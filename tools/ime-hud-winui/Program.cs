using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using WinRT;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 正式 WinUI Island Renderer 入口。
/// 默认常驻：HWND + Island 只创建一次，隐藏等待 WM_COPYDATA。
/// Application 只用来挂 ThemeResource，不创建 Microsoft.UI.Xaml.Window。
/// 标题 / mutex 都是 Lat3ncyImeHudWinUi。只查找本 Renderer，不查找其他窗口。
/// </summary>
internal static class Program
{
    // Application.Start 回调返回后消息循环还在跑，必须把 host 钉在静态字段上。
    static HudHost? s_host;
    static WindowsXamlManager? s_xamlManager;
    static Mutex? s_residentMutex;

    [STAThread]
    static int Main(string[] args)
    {
        HudLog.Line("main");
        try
        {
            // unpackaged WinUI 查 ms-appx 主题时会看当前目录的 resources.pri。
            // Start-Process 默认 cwd 是调用方目录，必须先切到 exe 所在目录。
            Directory.SetCurrentDirectory(AppContext.BaseDirectory);
            HudLog.Line("cwd=" + Directory.GetCurrentDirectory());
        }
        catch (Exception ex)
        {
            HudLog.Line("cwd-failed=" + ex.Message);
        }

        bool selfTest = HasFlag(args, "--self-test");
        int cycleRounds = ReadIntOption(args, "--cycle", fallback: 0, flagDefault: 200);
        string? startupCommand = ExtractCommand(args);
        if (HasFlag(args, "--quit"))
            startupCommand = "QUIT";

        HudLog.Line("options self-test=" + selfTest
            + " cycle=" + cycleRounds
            + " command=" + (startupCommand ?? "")
            + " transparency=" + Native.TransparencyEnabled()
            + " high-contrast=" + Native.HighContrastEnabled());

        // 不创建窗口，只校验协议常量和独立标题 / mutex。
        if (selfTest)
        {
            int code = Protocol.SelfTest();
            HudLog.Line("self-test=" + code);
            return code;
        }

        Native.TryEnablePerMonitorV2();
        HudLog.Line("dpi-ok");
        ComWrappersSupport.InitializeComWrappers();
        HudLog.Line("comwrappers-ok");

        // 第二个进程只转发到本 Renderer 的 HWND，不查找其他窗口。
        if (!TryClaimResident(startupCommand, cycleRounds > 0))
            return cycleRounds > 0 ? 1 : 0;

        int exitCode = 1;
        try
        {
            Application.Start(_ =>
            {
                DispatcherQueue queue = DispatcherQueue.GetForCurrentThread()
                    ?? throw new InvalidOperationException("Application.Start 后没有 DispatcherQueue");
                SynchronizationContext.SetSynchronizationContext(
                    new DispatcherQueueSynchronizationContext(queue));
                HudLog.Line("dispatcher-ok");

                new HudApp();
                HudLog.Line("application-ok");
                exitCode = RunHost(cycleRounds, startupCommand);
            });
            HudLog.Line("loop-exit");
            try { s_host?.Dispose(); } catch { }
            HudLog.Line("host-unpin-ok");
            if (s_host?.CycleFailed == true)
                return 2;
            return exitCode;
        }
        catch (Exception ex)
        {
            HudLog.Line("fatal=" + ex);
            return 1;
        }
        finally
        {
            try { s_residentMutex?.ReleaseMutex(); } catch { }
            try { s_residentMutex?.Dispose(); } catch { }
            s_residentMutex = null;
        }
    }

    /// <summary>
    /// 拿到 mutex 的才真正建 HWND。拿不到就转发命令然后退出。
    /// --cycle 遇到已有实例不能转发，直接失败，避免打到常驻窗口上。
    /// </summary>
    static bool TryClaimResident(string? startupCommand, bool cycle)
    {
        var mutex = new Mutex(true, Protocol.MutexName, out bool created);
        if (created)
        {
            s_residentMutex = mutex;
            HudLog.Line("resident-mutex=claimed");
            return true;
        }

        mutex.Dispose();
        if (cycle)
        {
            HudLog.Line("cycle-abort existing-instance");
            return false;
        }

        bool forwarded = Protocol.TryForwardToExisting(startupCommand);
        HudLog.Line("resident-mutex=existing forwarded=" + forwarded
            + " command=" + (startupCommand ?? ""));
        return false;
    }

    static string? ExtractCommand(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            string token = args[i];
            if (token.StartsWith("--", StringComparison.Ordinal))
            {
                if (token.Equals("--state", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                    return "STATE|" + args[i + 1];
                if (token.Equals("--panel", StringComparison.OrdinalIgnoreCase))
                    return BuildPanelOpenCommand(args, i + 1);
                if (token.Equals("--panel-clipboard", StringComparison.OrdinalIgnoreCase))
                    return "PANEL|OPEN|||||clipboard";
                if (token.Equals("--panel-text", StringComparison.OrdinalIgnoreCase))
                    return BuildPanelTextCommand(args, i + 1);
                if (token.Equals("--panel-result", StringComparison.OrdinalIgnoreCase))
                    return BuildPanelResultCommand(args, i + 1);
                if (token.Equals("--panel-copy-source", StringComparison.OrdinalIgnoreCase))
                    return "PANEL|COPY|source";
                if (token.Equals("--panel-copy-result", StringComparison.OrdinalIgnoreCase))
                    return "PANEL|COPY|result";
                continue;
            }
            if (token.StartsWith("STATE", StringComparison.OrdinalIgnoreCase)
                || token.StartsWith("PANEL", StringComparison.OrdinalIgnoreCase)
                || token.Equals("HIDE", StringComparison.OrdinalIgnoreCase)
                || token.Equals("PING", StringComparison.OrdinalIgnoreCase)
                || token.Equals("QUIT", StringComparison.OrdinalIgnoreCase))
            {
                return token;
            }
        }
        return null;
    }

    /// <summary>
    /// --panel 后面可选 x y dpi source。没有坐标就发 PANEL|OPEN，由定位层走 caret / 窗口 / 屏幕中心。
    /// 不要在这里读当前鼠标去填 mouse-at-hotkey。
    /// </summary>
    static string BuildPanelOpenCommand(string[] args, int start)
    {
        var parts = new List<string> { "PANEL", "OPEN" };
        for (int i = start; i < args.Length && parts.Count < 6; i++)
        {
            string token = args[i];
            if (token.StartsWith("--", StringComparison.Ordinal))
                break;
            parts.Add(token);
        }
        return string.Join("|", parts);
    }

    /// <summary>
    /// --panel-text 后面整段当显式原文。不要在这里读剪贴板。
    /// </summary>
    static string BuildPanelTextCommand(string[] args, int start)
    {
        string payload = start < args.Length
            ? string.Join(" ", args[start..])
            : "";
        return "PANEL|OPEN|||||explicit|" + payload;
    }

    /// <summary>
    /// --panel-result 后面整段当显式译文。不调用翻译服务，也不读剪贴板。
    /// 只发 RESULT，不重开面板、不改原文。
    /// </summary>
    static string BuildPanelResultCommand(string[] args, int start)
    {
        string payload = start < args.Length
            ? string.Join(" ", args[start..])
            : "";
        return "PANEL|RESULT|explicit|" + payload;
    }

    static bool HasFlag(string[] args, string flag)
    {
        foreach (string arg in args)
        {
            if (arg.Equals(flag, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    static int ReadIntOption(string[] args, string name, int fallback, int flagDefault)
    {
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (arg.Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 < args.Length && int.TryParse(args[i + 1], out int value))
                    return value;
                return flagDefault;
            }
            if (arg.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase)
                && int.TryParse(arg[(name.Length + 1)..], out int inline))
            {
                return inline;
            }
        }
        return fallback;
    }

    static int RunHost(int cycleRounds, string? startupCommand)
    {
        try
        {
            s_xamlManager = WindowsXamlManager.InitializeForCurrentThread();
            HudLog.Line("xaml-manager-ok");
            s_host = new HudHost();
            HudLog.Line("host-ok");

            if (cycleRounds > 0)
            {
                s_host.RunCycleThenExit(cycleRounds);
            }
            else
            {
                HudLog.Line("resident-idle title=" + Protocol.WindowTitle);
                if (!string.IsNullOrWhiteSpace(startupCommand))
                    s_host.DispatchCommand(startupCommand);
            }

            return s_host.CycleFailed ? 2 : 0;
        }
        catch (Exception ex)
        {
            HudLog.Line("fatal=" + ex);
            try { Application.Current?.Exit(); } catch { }
            return 1;
        }
    }
}
