using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

internal sealed class CaptureActivitySettingsForm
{
    public StackPanel Root { get; } = new() { Spacing = 8, Padding = new Thickness(24, 0, 24, 20) };
    readonly Button _refresh = new() { Content = "刷新处理结果", HorizontalAlignment = HorizontalAlignment.Left };
    readonly StackPanel _rows = new() { Spacing = 8 };
    readonly TextBlock _summary = SettingsUi.Hint("查看最近一次工具箱处理结果；不包含图片、视频、文件名或路径。未发现新文件时，无法单独判断是否取消或未保存。");
    readonly CancellationToken _lifetime;
    public CaptureActivitySettingsForm(CancellationToken lifetime)
    {
        _lifetime = lifetime;
        var content = new StackPanel { Spacing = 12 }; content.Children.Add(_summary); content.Children.Add(_refresh); content.Children.Add(_rows);
        var expander = new Expander { Header = "最近捕获处理", Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        Root.Children.Add(expander);
        AutomationProperties.SetName(_refresh, "刷新截图和录屏处理结果");
        expander.Expanding += async (_, _) => await RefreshAsync();
        _refresh.Click += async (_, _) => await RefreshAsync();
    }
    async Task RefreshAsync()
    {
        if (!_refresh.IsEnabled) return;
        _refresh.IsEnabled = false;
        try
        {
            var data = await PreferencesBridge.RunCaptureActivityAsync(_lifetime);
            if (_lifetime.IsCancellationRequested) return;
            _summary.Text = "最近一次工具箱处理结果；刷新可查看变化。不记录内容、文件名或路径。";
            _rows.Children.Clear();
            foreach (var item in data.GetProperty("items").EnumerateArray())
            {
                string state = item.GetProperty("state").GetString()!;
                string reason = item.GetProperty("reason").GetString()!;
                var content = new StackPanel { Spacing = 8 };
                content.Children.Add(SettingsUi.Row(item.GetProperty("mode").GetString() == "Screenshot" ? "截图" : "录屏",
                    new TextBlock { Text = StateLabel(state, reason), TextWrapping = TextWrapping.Wrap }));
                if (state is not ("none" or "unavailable"))
                    content.Children.Add(SettingsUi.Hint("剪贴板：" + Outcome(item.GetProperty("clipboard").GetString()!) + " · 额外目录：" + Outcome(item.GetProperty("extra_copy").GetString()!)));
                if (DateTimeOffset.TryParse(item.GetProperty("updated_utc").GetString(), CultureInfo.InvariantCulture, DateTimeStyles.None, out var time))
                    content.Children.Add(SettingsUi.Hint("更新时间（北京时间）：" + time.ToOffset(TimeSpan.FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)));
                _rows.Children.Add(SettingsUi.Card(content));
            }
        }
        catch (OperationCanceledException) { }
        catch { if (!_lifetime.IsCancellationRequested) _summary.Text = "暂时无法读取处理记录，可稍后刷新。"; }
        finally { _refresh.IsEnabled = true; }
    }
    static string Outcome(string state) => state switch { "off" => "已关闭", "success" => "完成", "failed" => "失败", "pending" => "等待处理", _ => "未执行" };
    internal static string StateLabel(string state, string reason) => (state, reason) switch
    {
        ("waiting", _) => "等待系统保存", ("processing", _) => "等待文件完成并处理", ("completed", _) => "处理完成",
        ("partial", _) => "部分处理失败", ("failed", "launch_failed") => "捕获或监视未能启动", ("failed", _) => "处理失败",
        ("timeout", "no_file") => "未发现新文件（可能取消、未保存或超时）", ("timeout", _) => "文件在等待期限内未完成",
        ("stopped", _) => "处理已停止", ("processing_disabled", _) => "工具箱后续处理已关闭",
        ("interrupted", _) => "等待已结束，未收到处理结果", ("none", _) => "暂无处理记录", _ => "无法读取处理记录",
    };
}
