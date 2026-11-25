using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace Lat3ncyToolbox.ImeHudWinUi;

internal sealed class MaintenanceSettingsForm
{
    public Expander Root { get; }
    readonly CancellationToken _lifetime;
    readonly Func<string, Task<JsonElement>> _reload;
    readonly Func<string, bool> _enabled;
    readonly Action<string> _navigate;
    readonly Func<Task<JsonElement>> _center;
    readonly Func<Task<JsonElement>> _cancel;
    readonly Dictionary<string, Button> _actions = new();
    readonly Button _diagnose = new() { Content = "完整离线检查", HorizontalAlignment = HorizontalAlignment.Left };
    readonly Button _copy = new() { Content = "复制检查摘要", IsEnabled = false };
    readonly InfoBar _feedback = new() { IsOpen = false, IsClosable = true };
    readonly StackPanel _diagnostics = new() { Spacing = 8 };
    readonly TextBlock _stage = new() { Text = "当前阶段：未运行" };
    readonly TextBlock _result = new() { Text = "结果：—" };
    readonly TextBlock _record = new() { Text = "记录：—" };
    readonly Button _cancelButton = new() { Content = "取消当前阶段", HorizontalAlignment = HorizontalAlignment.Left };
    readonly Button _recordButton = new() { Content = "查看失败记录", IsEnabled = false, HorizontalAlignment = HorizontalAlignment.Left };
    bool _busy, _centerBusy, _centerCancellable;
    string _report = "", _recordId = "", _failureText = "";
    static readonly Dictionary<string, string> Labels = new() { ["power"] = "电源管理", ["theme"] = "主题切换计划", ["rgb"] = "氛围灯" };
    public MaintenanceSettingsForm(CancellationToken lifetime, Func<string, Task<JsonElement>> reload, Func<string, bool> enabled, Action<string> navigate,
        Func<Task<JsonElement>> center, Func<Task<JsonElement>> cancel)
    {
        _lifetime = lifetime; _reload = reload; _enabled = enabled; _navigate = navigate; _center = center; _cancel = cancel;
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(SettingsUi.Hint("重载先保存当前输入，仅重新应用所选后台配置。功能关闭时不可重载；工具箱的录屏会话仍在等待或处理中时暂缓执行。"));
        Add("power", "重新读取电源超时、保持唤醒与设备唤醒策略。", content);
        Add("theme", "更新自动切换计划，不立即切换桌面主题。", content);
        Add("rgb", "重读灯光配置，可能短暂熄灯；未运行时下次启动读取。", content);
        var centerPanel = new StackPanel { Spacing = 6 };
        centerPanel.Children.Add(SettingsUi.Hint("维护任务中心显示构建、验证、部署与恢复的当前阶段和结果。取消只在部署前的可安全阶段提供。"));
        centerPanel.Children.Add(_stage); centerPanel.Children.Add(_result); centerPanel.Children.Add(_record);
        var centerActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        centerActions.Children.Add(_cancelButton); centerActions.Children.Add(_recordButton);
        centerPanel.Children.Add(centerActions);
        content.Children.Add(centerPanel);
        content.Children.Add(SettingsUi.Hint("离线检查核对配置、依赖元数据与临时目录可写性，不联网、不加载模型、不读取日志或捕获内容。"));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(_diagnose); actions.Children.Add(_copy);
        content.Children.Add(actions); content.Children.Add(_feedback); content.Children.Add(_diagnostics);
        Root = new Expander { Header = "维护操作", Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(_diagnose, "运行完整离线环境检查");
        AutomationProperties.SetName(_copy, "复制脱敏离线检查摘要");
        AutomationProperties.SetName(_cancelButton, "取消当前可安全阶段的维护任务");
        AutomationProperties.SetName(_recordButton, "查看维护失败记录");
        _cancelButton.Click += async (_, _) => await CancelAsync();
        _recordButton.Click += (_, _) => Feedback("失败记录：" + (_recordId.Length > 0 ? _recordId : "—") +
            (_failureText.Length > 0 ? "；" + FailureText(_failureText) : ""), InfoBarSeverity.Informational);
        Root.Expanding += async (_, _) => { UpdateButtons(); await ReadLastResultAsync(); await RefreshCenterAsync(); };
        Root.Loaded += (_, _) => UpdateButtons();
        _diagnose.Click += async (_, _) => await DiagnoseAsync();
        _copy.Click += (_, _) => CopySummary();
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
        _copy.IsEnabled = !_busy && _report.Length > 0;
        UpdateCenterButtons();
    }
    void UpdateCenterButtons()
    {
        _cancelButton.IsEnabled = !_centerBusy && !_lifetime.IsCancellationRequested && _centerCancellable;
        _recordButton.IsEnabled = !_centerBusy && _recordId.Length > 0;
    }
    async Task RefreshCenterAsync()
    {
        if (_centerBusy || _lifetime.IsCancellationRequested) return;
        _centerBusy = true; UpdateCenterButtons();
        try
        {
            var data = await _center();
            var state = data.GetProperty("state");
            string stage = state.GetProperty("stage").GetString() ?? "idle";
            string result = state.GetProperty("result").GetString() ?? "idle";
            _recordId = state.GetProperty("record").GetString() ?? "";
            _failureText = state.GetProperty("failure").GetString() ?? "";
            _centerCancellable = state.GetProperty("cancellable").GetBoolean();
            _stage.Text = "当前阶段：" + StageText(stage);
            _result.Text = "结果：" + ResultText(result) + (_failureText.Length > 0 ? "（" + FailureText(_failureText) + "）" : "");
            _record.Text = _recordId.Length > 0 ? "记录：" + _recordId : "记录：—";
        }
        catch { if (!_lifetime.IsCancellationRequested) _stage.Text = "当前阶段：无法读取"; }
        finally { _centerBusy = false; UpdateCenterButtons(); }
    }
    async Task CancelAsync()
    {
        if (_centerBusy || !_centerCancellable) return;
        _centerBusy = true; UpdateCenterButtons();
        try { await _cancel(); Feedback("已请求取消；仅在当前可安全阶段生效。", InfoBarSeverity.Informational); }
        catch (Exception error)
        {
            if (!_lifetime.IsCancellationRequested)
                Feedback(error.Message == "stage_not_cancellable" ? "当前阶段不可取消。" : "无法提交取消请求，请稍后重试。", InfoBarSeverity.Warning);
        }
        finally { _centerBusy = false; UpdateCenterButtons(); await RefreshCenterAsync(); }
    }
    static string StageText(string stage) => stage switch
    {
        "build" => "构建", "verify" => "验证", "deploy" => "部署", "restore" => "恢复", _ => "未运行",
    };
    static string ResultText(string result) => result switch
    {
        "running" => "进行中", "succeeded" => "成功", "failed" => "失败", "cancelled" => "已取消", _ => "未运行",
    };
    static string FailureText(string failure) => failure switch
    {
        "deploy_failed" => "部署失败", "restore_failed" => "恢复失败", "verification_failed" => "验证失败",
        "cancelled" => "已取消", _ => "未记录具体原因",
    };
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
        _busy = true; _report = ""; _diagnostics.Children.Clear(); UpdateButtons(); Feedback("正在检查本机环境…", InfoBarSeverity.Informational);
        try
        {
            var data = await PreferencesBridge.RunFullStatusAsync(_lifetime);
            if (_lifetime.IsCancellationRequested) return;
            var report = SettingsDiagnosticReport.From(data);
            _report = report.Summary;
            _diagnostics.Children.Add(SettingsUi.Hint("检查时间：" + report.CheckedAt));
            foreach (var item in report.Rows)
            {
                var panel = new StackPanel { Spacing = 6 };
                panel.Children.Add(SettingsUi.Row(item.Label, new TextBlock { Text = item.State, TextWrapping = TextWrapping.Wrap, MaxWidth = 280 }));
                panel.Children.Add(SettingsUi.Hint(item.Guidance));
                if (item.Mismatches > 0) panel.Children.Add(SettingsUi.Hint("不匹配的依赖数量：" + item.Mismatches));
                string module = item.Id;
                var open = new Button { Content = module switch { "translate" => "查看翻译设置", "tts" => "查看朗读设置", _ => "查看截图识别设置" }, HorizontalAlignment = HorizontalAlignment.Left };
                open.Click += (_, _) => _navigate(module);
                panel.Children.Add(open);
                _diagnostics.Children.Add(SettingsUi.Card(panel));
            }
            Feedback(report.NeedsAttention ? "离线检查完成，请按各项建议复查。可复制脱敏摘要。" : "离线检查通过；云端服务与硬件效果需单独验证。", report.NeedsAttention ? InfoBarSeverity.Warning : InfoBarSeverity.Success);
        }
        catch (OperationCanceledException) { }
        catch { if (!_lifetime.IsCancellationRequested) Feedback("无法完成离线检查，可稍后重试。", InfoBarSeverity.Error); }
        finally { _busy = false; if (!_lifetime.IsCancellationRequested) UpdateButtons(); }
    }
    void CopySummary()
    {
        if (_busy || _report.Length == 0 || _lifetime.IsCancellationRequested) return;
        try
        {
            var package = new DataPackage(); package.SetText(_report); Clipboard.SetContent(package);
            Feedback("已复制脱敏检查摘要。", InfoBarSeverity.Success);
        }
        catch { Feedback("无法复制检查摘要，可稍后重试。", InfoBarSeverity.Warning); }
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
