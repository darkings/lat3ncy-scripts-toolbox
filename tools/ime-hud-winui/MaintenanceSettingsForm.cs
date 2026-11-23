using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

internal sealed class MaintenanceSettingsForm
{
    public Expander Root { get; }
    readonly CancellationToken _lifetime;
    readonly Func<string, Task<JsonElement>> _reload;
    readonly Func<string, bool> _enabled;
    readonly Dictionary<string, Button> _actions = new();
    readonly Button _diagnose = new() { Content = "完整离线检查", HorizontalAlignment = HorizontalAlignment.Left };
    readonly InfoBar _feedback = new() { IsOpen = false, IsClosable = true };
    readonly StackPanel _diagnostics = new() { Spacing = 8 };
    bool _busy;
    static readonly Dictionary<string, string> Labels = new() { ["power"] = "电源管理", ["theme"] = "主题切换计划", ["rgb"] = "氛围灯" };
    public MaintenanceSettingsForm(CancellationToken lifetime, Func<string, Task<JsonElement>> reload, Func<string, bool> enabled)
    {
        _lifetime = lifetime; _reload = reload; _enabled = enabled;
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(SettingsUi.Hint("重载先保存当前输入，仅重新应用所选后台配置。功能关闭时不可重载；工具箱的录屏会话仍在等待或处理中时暂缓执行。"));
        Add("power", "重新读取电源超时、保持唤醒与设备唤醒策略。", content);
        Add("theme", "更新自动切换计划，不立即切换桌面主题。", content);
        Add("rgb", "重读灯光配置，可能短暂熄灯；未运行时下次启动读取。", content);
        content.Children.Add(SettingsUi.Hint("离线检查只读取本机配置与依赖元数据，不联网、不加载模型、不读取日志或捕获内容。"));
        content.Children.Add(_diagnose); content.Children.Add(_feedback); content.Children.Add(_diagnostics);
        Root = new Expander { Header = "维护操作", Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(_diagnose, "运行完整离线环境检查");
        Root.Expanding += async (_, _) => { UpdateButtons(); await ReadLastResultAsync(); };
        _diagnose.Click += async (_, _) => await DiagnoseAsync();
        UpdateButtons();
    }
    void Add(string module, string help, StackPanel content)
    {
        var button = new Button { Content = "重载", Style = (Style)Application.Current.Resources["AccentButtonStyle"] }; _actions[module] = button;
        AutomationProperties.SetName(button, "重载" + Labels[module]);
        button.Click += async (_, _) => await ReloadAsync(module);
        content.Children.Add(SettingsUi.Card(SettingsUi.Row(Labels[module], button, help)));
    }
    void UpdateButtons()
    {
        foreach (var (module, button) in _actions) button.IsEnabled = !_busy && _enabled(module);
        _diagnose.IsEnabled = !_busy;
    }
    void Feedback(string text, InfoBarSeverity severity)
    { _feedback.Message = text; _feedback.Severity = severity; _feedback.IsOpen = true; }
    async Task ReloadAsync(string module)
    {
        if (_busy) return;
        _busy = true; UpdateButtons(); Feedback("正在重新应用" + Labels[module] + "…", InfoBarSeverity.Informational);
        try { PresentResult(await _reload(module)); }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!_lifetime.IsCancellationRequested) Feedback(ErrorText(error.Message), InfoBarSeverity.Warning); }
        finally { _busy = false; if (!_lifetime.IsCancellationRequested) UpdateButtons(); }
    }
    async Task ReadLastResultAsync()
    {
        if (_busy) return;
        try
        {
            var data = await PreferencesBridge.RunReloadAsync(null, _lifetime);
            if (!_lifetime.IsCancellationRequested)
            {
                var result = data.GetProperty("result");
                if (result.TryGetProperty("status", out var state) && state.GetString() == "completed") PresentResult(result, previous: true);
            }
        }
        catch { }
    }
    void PresentResult(JsonElement result, bool previous = false)
    {
        if (_lifetime.IsCancellationRequested) return;
        string[] completed = result.GetProperty("completed").GetString()!.Split(',');
        string[] failed = result.GetProperty("failed").GetString()!.Split(',');
        var messages = new List<string>();
        foreach (var (module, label) in Labels)
        {
            if (completed.Contains(module)) messages.Add(label + "重载完成");
            if (failed.Contains(module))
            {
                string reason = "operation_failed";
                if (result.TryGetProperty("errors", out var errors))
                {
                    if (errors.TryGetProperty(module, out var value)) reason = value.GetString()!;
                    else if (errors.TryGetProperty("busy", out _)) reason = "busy";
                }
                messages.Add(label + "：" + ReasonText(reason));
            }
        }
        if (messages.Count > 0) Feedback((previous ? "上次重载：" : "") + string.Join("；", messages), failed.Any(Labels.ContainsKey) ? InfoBarSeverity.Warning : InfoBarSeverity.Success);
    }
    async Task DiagnoseAsync()
    {
        if (_busy) return;
        _busy = true; UpdateButtons(); Feedback("正在检查本机环境…", InfoBarSeverity.Informational);
        try
        {
            var data = await PreferencesBridge.RunFullStatusAsync(_lifetime);
            if (_lifetime.IsCancellationRequested) return;
            _diagnostics.Children.Clear(); bool attention = false;
            foreach (var item in data.GetProperty("diagnostics").EnumerateArray())
            {
                string config = item.GetProperty("config_state").GetString()!;
                string runtime = item.GetProperty("runtime_state").GetString()!;
                bool ok = config is "ok" or "default" && runtime is "ok" or "not-applicable";
                attention |= !ok;
                string reason = item.GetProperty("runtime_reason").GetString()!;
                string text = config == "invalid" ? "配置格式需检查" : reason switch
                {
                    "dependencies" => "依赖版本需检查", "temp_unwritable" => "当前进程无法写临时目录",
                    "limited_integrity" => "设置进程权限受限，需在普通环境复查", _ => ok ? "检查通过" : "无法完整检查",
                };
                var panel = new StackPanel { Spacing = 6 };
                panel.Children.Add(SettingsUi.Row(item.GetProperty("label").GetString()!, new TextBlock { Text = text }));
                int count = item.GetProperty("dependency_mismatches").GetInt32();
                if (count > 0) panel.Children.Add(SettingsUi.Hint("不匹配的依赖数量：" + count));
                _diagnostics.Children.Add(SettingsUi.Card(panel));
            }
            Feedback(attention ? "离线检查完成，部分项目需检查；此结果不代表云端服务或硬件效果。" : "离线检查通过；云端服务与硬件效果需单独验证。", attention ? InfoBarSeverity.Warning : InfoBarSeverity.Success);
        }
        catch (OperationCanceledException) { }
        catch { if (!_lifetime.IsCancellationRequested) Feedback("无法完成离线检查，可稍后重试。", InfoBarSeverity.Error); }
        finally { _busy = false; if (!_lifetime.IsCancellationRequested) UpdateButtons(); }
    }
    static string ReasonText(string reason) => reason switch
    {
        "busy" => "已有后台重载正在执行", "capture_busy" => "录屏状态尚未结束，暂缓重载", "disabled" => "功能已关闭",
        "config_changed" => "配置已变化，请重新重载", "ownership" => "无法确认已安装任务属于本仓库", _ => "未能完成，请刷新状态后重试",
    };
    internal static string ErrorText(string code) => code switch
    {
        "reload_busy" => "已有后台重载正在执行，请完成后重试。",
        "reload_capture_busy" => "录屏会话仍在等待或处理中，暂缓后台重载。",
        "reload_capture_unavailable" => "无法确认录屏状态，暂缓后台重载。",
        "reload_disabled" => "所选功能已关闭，请先在对应页面启用。",
        "settings_not_saved" => "设置尚未保存，请修正标记的字段后重试。",
        "reload_timeout" => "后台操作尚未完成，可稍后刷新运行状态。",
        _ => "无法提交重载，请确认工具箱主进程正在运行后重试。",
    };
}
