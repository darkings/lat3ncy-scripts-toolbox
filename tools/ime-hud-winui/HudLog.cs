using System.Text;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// WinExe 没有控制台，结果写日志文件。
///
/// 写两个位置：
///   1. %LOCALAPPDATA%\lat3ncy-toolbox\ImeHudWinUi.log —— 主日志，不会被 Temp 清理
///   2. %TEMP%\ImeHudWinUi.log —— 兼容旧路径
/// 任何一处写失败都静默跳过，不影响 HUD。
/// 第二个进程（转发命令）也走这里，只能追加。
/// </summary>
internal static class HudLog
{
    static readonly string[] Paths = ResolvePaths();

    static string[] ResolvePaths()
    {
        var list = new List<string>();

        // 1. 可执行文件同目录：沙箱/受限令牌下唯一稳定可写的位置（本机实测）。
        try
        {
            if (!string.IsNullOrEmpty(AppContext.BaseDirectory))
                list.Add(System.IO.Path.Combine(AppContext.BaseDirectory, "ImeHudWinUi.log"));
        }
        catch
        {
        }

        // 2. %LOCALAPPDATA%：正式会话的主日志，不会被 Temp 清理。
        try
        {
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrEmpty(localAppData))
            {
                string dir = System.IO.Path.Combine(localAppData, "lat3ncy-toolbox");
                System.IO.Directory.CreateDirectory(dir);
                list.Add(System.IO.Path.Combine(dir, "ImeHudWinUi.log"));
            }
        }
        catch
        {
        }

        // 3. %TEMP%：兼容旧路径。
        try
        {
            list.Add(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ImeHudWinUi.log"));
        }
        catch
        {
        }

        return list.ToArray();
    }

    static HudLog()
    {
        Line("start pid=" + Environment.ProcessId + " t=" + DateTime.Now.ToString("O"));
    }

    public static void Line(string text)
    {
        string payload = Sanitize(text) + Environment.NewLine;
        foreach (string path in Paths)
        {
            try
            {
                File.AppendAllText(path, payload, Encoding.UTF8);
            }
            catch
            {
            }
        }
    }

    /// <summary>
    /// 关键路径的结构化观测日志。当前实现和 Line 一样落盘，
    /// 单独一个入口是为了以后能按开关降噪，不要在这里加过滤逻辑。
    /// </summary>
    public static void Info(string key, string detail)
    {
        Line(Sanitize(key) + " " + Sanitize(detail));
    }

    static string Sanitize(string text)
    {
        if (string.IsNullOrEmpty(text))
            return "";
        return text.Replace("\0", "").TrimEnd();
    }
}
