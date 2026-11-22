using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Local drafts for tray preferences and independently gated AHK actions.</summary>
internal sealed class ControlSettingsForm
{
    public StackPanel Root { get; } = new() { Spacing = 16, Padding = new Thickness(24) };
    public string Revision { get; private set; }
    readonly Dictionary<string, (Control input, string original)> _inputs = new();
    readonly Dictionary<string, string> _defaults = new();
    readonly Dictionary<string, string> _labels = new();

    public ControlSettingsForm(JsonElement data, string page)
    {
        Revision = data.GetProperty("revision").GetString()!;
        JsonElement values = data.GetProperty("values");
        if (page == "general")
        {
            Root.Children.Add(Description("隐藏主托盘后，仍可通过 Raycast 的 Toolbox Settings 或翻译面板重新打开设置。图标跟随任务栏主题：深色使用白色，浅色使用黑色。"));
            AddCheck("tray_visible", "显示工具箱主托盘图标", values);
            return;
        }
        Root.Children.Add(Description("功能和快捷键可分别开关。默认键位沿用当前配置，修改不改写源码。使用 AHK 格式，例如 ^!F9（Ctrl+Alt+F9）或 ~CapsLock & f。CapsLock 基础键保留；输入法增强可关闭。"));
        foreach (JsonElement feature in data.GetProperty("features").EnumerateArray())
        {
            string id = feature.GetProperty("id").GetString()!;
            string label = feature.GetProperty("label").GetString()!;
            string kind = feature.GetProperty("kind").GetString()!;
            _labels[id] = label;
            Root.Children.Add(new TextBlock { Text = label, FontSize = 18, Margin = new Thickness(0, 8, 0, 0) });
            AddCheck("feature_" + id + "_enabled", "启用功能", values, label);
            if (kind == "resident") continue;
            AddCheck("hotkey_" + id + "_enabled", "启用快捷键", values, label);
            string key = "binding_" + id;
            string current = values.GetProperty(key).GetString()!;
            var input = new TextBox { Header = "快捷键", Text = current, MaxLength = 80, IsReadOnly = kind == "leader" };
            AutomationProperties.SetName(input, label + " 快捷键");
            AutomationProperties.SetAutomationId(input, key);
            Root.Children.Add(input); _inputs[key] = (input, current);
            string defaultBinding = feature.GetProperty("default").GetString()!;
            _defaults[key] = defaultBinding;
            string hint = "默认：" + defaultBinding;
            if (kind.StartsWith("editor-", StringComparison.Ordinal)) hint += "。这是发送给编辑器的键位，请同步编辑器内的复制路径绑定。";
            if (kind == "leader") hint += "。基础键供 Caps 组合键使用，不能更换。";
            Root.Children.Add(Description(hint));
        }
    }

    static TextBlock Description(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };

    void AddCheck(string key, string label, JsonElement values, string context = "")
    {
        bool value = values.GetProperty(key).GetBoolean();
        var input = new CheckBox { Content = label, IsChecked = value };
        AutomationProperties.SetName(input, context.Length > 0 ? context + " " + label : label);
        AutomationProperties.SetAutomationId(input, key);
        Root.Children.Add(input); _inputs[key] = (input, value ? "true" : "false");
    }

    public object ReadRequest()
    {
        var changes = new Dictionary<string, object>();
        foreach (var (key, field) in _inputs)
        {
            if (field.input is CheckBox check)
            {
                bool value = check.IsChecked == true;
                if ((value ? "true" : "false") != field.original) changes[key] = value;
            }
            else if (field.input is TextBox text && text.Text != field.original) changes[key] = text.Text;
        }
        return new { revision = Revision, changes };
    }

    public void RetargetOwnRevision(string oldRevision, string newRevision)
    {
        if (Revision == oldRevision) Revision = newRevision;
    }

    public void ResetBindings()
    {
        foreach (var (key, value) in _defaults) ((TextBox)_inputs[key].input).Text = value;
        foreach (var (key, field) in _inputs)
            if (key.StartsWith("hotkey_", StringComparison.Ordinal)) ((CheckBox)field.input).IsChecked = true;
    }

    public string? ConflictMessage(string code)
    {
        if (!code.StartsWith("hotkey_conflict_", StringComparison.Ordinal)) return null;
        string[] ids = code["hotkey_conflict_".Length..].Split('_');
        if (ids.Length != 2 || !_labels.TryGetValue(ids[0], out string? first) || !_labels.TryGetValue(ids[1], out string? second)) return null;
        return first + " 与 " + second + " 的快捷键冲突。请修改键位或关闭其中一个快捷键。";
    }
}
