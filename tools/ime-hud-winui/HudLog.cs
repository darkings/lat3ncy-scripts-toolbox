using System.Text;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// WinExe 没有控制台，结果写到 %TEMP%\ImeHudWinUi.log。
/// 第二个进程也会跑到这里，只能追加，不能冲掉主进程日志。
/// </summary>
internal static class HudLog
{
    static readonly string Path = System.IO.Path.Combine(
        System.IO.Path.GetTempPath(),
        "ImeHudWinUi.log");

    static HudLog()
    {
        Line("start pid=" + Environment.ProcessId + " t=" + DateTime.Now.ToString("O"));
    }

    public static void Line(string text)
    {
        try
        {
            File.AppendAllText(Path, Sanitize(text) + Environment.NewLine, Encoding.UTF8);
        }
        catch
        {
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
