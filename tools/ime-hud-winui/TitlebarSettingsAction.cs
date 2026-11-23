using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

internal sealed class TitlebarSettingsAction
{
    public StackPanel Root { get; } = new() { Spacing = 8 };
    readonly Button _apply = new() { Content = "立即应用标题栏样式", HorizontalAlignment = HorizontalAlignment.Left };
    readonly InfoBar _result = new() { IsOpen = false, IsClosable = true };
    readonly Func<Task<JsonElement>> _run;
    readonly Func<bool> _enabled;
    readonly CancellationToken _lifetime;
    bool _busy;
    public TitlebarSettingsAction(Func<Task<JsonElement>> run, Func<bool> enabled, CancellationToken lifetime)
    {
        _run = run; _enabled = enabled; _lifetime = lifetime;
        Root.Children.Add(SettingsUi.Hint("保存只记录配置。点击后先保存输入，再对所列进程当前可见的窗口应用一次；不会重启应用或创建后台跟随任务。部分应用会自行重绘标题栏，实际效果取决于应用支持。"));
        Root.Children.Add(_apply); Root.Children.Add(_result);
        Root.Loaded += (_, _) => RefreshEnabled();
        _apply.Click += async (_, _) => await ApplyAsync();
    }
    public void RefreshEnabled() => _apply.IsEnabled = !_busy && _enabled();
    void Feedback(string message, InfoBarSeverity severity)
    { _result.Message = message; _result.Severity = severity; _result.IsOpen = true; }
    async Task ApplyAsync()
    {
        if (_busy || !_enabled()) return;
        _busy = true; RefreshEnabled(); Feedback("正在应用标题栏样式…", InfoBarSeverity.Informational);
        try
        {
            var result = await _run();
            if (_lifetime.IsCancellationRequested) return;
            string failed = result.GetProperty("failed").GetString()!;
            if (failed.Split(',').Contains("titlebar"))
            {
                string reason = result.TryGetProperty("errors", out var errors) && errors.TryGetProperty("titlebar", out var error) ? error.GetString()! : "operation_failed";
                Feedback(reason switch
                {
                    "no_windows" => "未找到匹配的可见窗口。请先打开目标应用，或检查进程名称。",
                    "disabled" => "手动标题栏或主题功能已关闭。", "titlebar_partial" => "部分窗口未能应用或读回验证失败，可稍后重试。",
                    "capture_busy" => "录屏会话仍在等待或处理中，暂缓应用。", "config_changed" => "配置已变化，请重新应用。",
                    _ => "未能应用标题栏样式。请检查配置与目标应用权限后重试。",
                }, InfoBarSeverity.Warning);
            }
            else
            {
                int count = result.TryGetProperty("details", out var details) && details.TryGetProperty("titlebar", out var detail) && detail.TryGetProperty("applied", out var applied) ? applied.GetInt32() : 0;
                Feedback("已应用并读回验证 " + count + " 个窗口。", InfoBarSeverity.Success);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!_lifetime.IsCancellationRequested) Feedback(MaintenanceSettingsForm.ErrorText(error.Message), InfoBarSeverity.Warning); }
        finally { _busy = false; if (!_lifetime.IsCancellationRequested) RefreshEnabled(); }
    }
}
