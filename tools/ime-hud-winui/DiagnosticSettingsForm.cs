using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>User-requested read-only metadata; never launches or restarts a feature.</summary>
internal sealed class DiagnosticSettingsForm
{
    public Expander Root { get; }
    readonly Button _refresh = new() { Content = "刷新状态", HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock _summary = SettingsUi.Hint("按刷新检查当前仓库的后台进程。不读取正文或密钥，不连接设备。氛围灯仅检查进程，不验证实际灯光。未运行或无法读取会分别标记。");
    readonly StackPanel _rows = new() { Spacing = 4 };
    readonly CancellationToken _lifetime;
    public DiagnosticSettingsForm(CancellationToken lifetime)
    {
        _lifetime = lifetime;
        var content = new StackPanel { Spacing = 12 }; content.Children.Add(_summary); content.Children.Add(_refresh); content.Children.Add(_rows);
        Root = new Expander { Header = "运行状态与版本", Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(_refresh, "刷新工具箱运行状态");
        _refresh.Click += async (_, _) => await RefreshAsync();
    }
    async Task RefreshAsync()
    {
        if (!_refresh.IsEnabled) return;
        _refresh.IsEnabled = false; _summary.Text = "正在检查本机运行状态…";
        try
        {
            JsonElement data = await PreferencesBridge.RunStatusAsync(_lifetime);
            if (_lifetime.IsCancellationRequested) return;
            _rows.Children.Clear();
            foreach (var item in data.GetProperty("components").EnumerateArray())
            {
                string state = item.GetProperty("state").GetString() ?? "";
                var text = new TextBlock { Text = StateLabel(state), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
                _rows.Children.Add(SettingsUi.Card(SettingsUi.Row(item.GetProperty("label").GetString()!, text)));
            }
            string commit = data.GetProperty("commit").GetString() ?? "";
            string stamp = data.GetProperty("source_stamp").GetString() ?? "";
            _rows.Children.Add(SettingsUi.Hint("仓库版本：" + (commit.Length == 40 ? commit[..8] : "无法确认") + " · 界面构建：" + (stamp.Length == 64 ? stamp[..12] : "尚无构建标记")));
            _summary.Text = "本机元数据检查完成。氛围灯仅检查进程，云端可用性与硬件效果需另行验证。";
        }
        catch (OperationCanceledException) { }
        catch { if (!_lifetime.IsCancellationRequested) _summary.Text = "暂时无法读取运行状态，可稍后刷新。设置仍可正常修改。"; }
        finally { _refresh.IsEnabled = true; }
    }
    internal static string StateLabel(string state) => state switch
    {
        "running" => "运行中", "not-running" or "missing" => "未运行", "ambiguous" => "发现多个进程",
        "outdated" => "运行中，版本待更新", "disabled" => "功能已关闭", "unresponsive" => "进程无响应", _ => "无法确认",
    };
}
