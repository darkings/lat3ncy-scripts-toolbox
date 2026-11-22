using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Local drafts for tray preferences and independently gated AHK actions.</summary>
internal sealed class ControlSettingsForm
{
    public StackPanel Root { get; } = new() { Spacing = 8, Padding = new Thickness(24, 12, 24, 20) };
    public string Revision { get; private set; }
    readonly Dictionary<string, (Control input, string original)> _inputs = new();
    readonly Dictionary<string, string> _defaults = new();
    readonly Dictionary<string, string> _labels = new();
    public bool HasChanges => _inputs.Values.Any(entry => entry.input is ToggleSwitch toggle
        ? (toggle.IsOn ? "true" : "false") != entry.original
        : entry.input is SettingsHotkeyEditor hotkey && hotkey.Value != entry.original);
    public event Action? Edited;
    void MarkEdited() { Edited?.Invoke(); }

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
        Root.Children.Add(Description("展开功能即可设置快捷键。选择组合修饰键和主键，修改后自动保存；默认键位保持不变，CapsLock 基础键固定。"));
        foreach (JsonElement feature in data.GetProperty("features").EnumerateArray())
        {
            string id = feature.GetProperty("id").GetString()!;
            string label = feature.GetProperty("label").GetString()!;
            string kind = feature.GetProperty("kind").GetString()!;
            _labels[id] = label;
            var enabled = Switch("feature_" + id + "_enabled", values, label + " 启用功能");
            if (kind == "resident") { Root.Children.Add(SettingsUi.Card(SettingsUi.Row(label, enabled))); continue; }
            var detail = new StackPanel { Spacing = 10 };
            detail.Children.Add(SettingsUi.Row("启用快捷键", Switch("hotkey_" + id + "_enabled", values, label + " 启用快捷键")));
            string key = "binding_" + id;
            string current = values.GetProperty(key).GetString()!;
            if (kind != "leader")
            {
                var input = new SettingsHotkeyEditor(current);
                input.Edited += MarkEdited;
                AutomationProperties.SetName(input, label + " 快捷键"); AutomationProperties.SetAutomationId(input, key);
                detail.Children.Add(input); _inputs[key] = (input, current);
            }
            string defaultBinding = feature.GetProperty("default").GetString()!;
            if (kind != "leader") _defaults[key] = defaultBinding;
            string hint = "默认：" + (kind == "leader" ? "CapsLock" : SettingsHotkeyEditor.Describe(defaultBinding));
            if (kind.StartsWith("editor-", StringComparison.Ordinal)) hint += "。这是发送给编辑器的键位，请同步编辑器内的复制路径绑定。";
            if (kind == "leader") hint += "。基础键供 Caps 组合键使用，不能更换。";
            detail.Children.Add(Description(hint));
            Root.Children.Add(new Expander { Header = SettingsUi.Row(label, enabled), Content = detail,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
        }
    }

    static TextBlock Description(string text) => SettingsUi.Hint(text);

    ToggleSwitch Switch(string key, JsonElement values, string name)
    {
        bool value = values.GetProperty(key).GetBoolean();
        var input = SettingsUi.Toggle(value);
        input.Toggled += (_, _) => MarkEdited();
        AutomationProperties.SetName(input, name); AutomationProperties.SetAutomationId(input, key);
        _inputs[key] = (input, value ? "true" : "false"); return input;
    }

    void AddCheck(string key, string label, JsonElement values, string context = "")
    {
        var input = Switch(key, values, context.Length > 0 ? context + " " + label : label);
        Root.Children.Add(SettingsUi.Card(SettingsUi.Row(label, input)));
    }

    public object ReadRequest()
    {
        var changes = new Dictionary<string, object>();
        foreach (var (key, field) in _inputs)
        {
            if (field.input is ToggleSwitch check)
            {
                bool value = check.IsOn;
                if ((value ? "true" : "false") != field.original) changes[key] = value;
            }
            else if (field.input is SettingsHotkeyEditor hotkey && hotkey.Value != field.original) changes[key] = hotkey.Value;
        }
        return new { revision = Revision, changes };
    }

    public void RetargetOwnRevision(string oldRevision, string newRevision)
    {
        if (Revision == oldRevision) Revision = newRevision;
    }

    public void ResetBindings()
    {
        foreach (var (key, value) in _defaults) ((SettingsHotkeyEditor)_inputs[key].input).Set(value);
        foreach (var (key, field) in _inputs)
            if (key.StartsWith("hotkey_", StringComparison.Ordinal)) ((ToggleSwitch)field.input).IsOn = true;
        MarkEdited();
    }

    public bool IsNonDefault => _inputs.Any(item => item.Value.input is ToggleSwitch toggle ? !toggle.IsOn
        : item.Value.input is SettingsHotkeyEditor hotkey && hotkey.Value != _defaults[item.Key]);
    public void RestoreDefaults()
    {
        foreach (var entry in _inputs.Values) if (entry.input is ToggleSwitch toggle) toggle.IsOn = true;
        foreach (var (key, value) in _defaults) ((SettingsHotkeyEditor)_inputs[key].input).Set(value);
        MarkEdited();
    }
    public void AcceptCommitted(JsonElement data)
    {
        Revision = data.GetProperty("revision").GetString()!;
        JsonElement values = data.GetProperty("values");
        foreach (string key in _inputs.Keys.ToArray())
        {
            var entry = _inputs[key]; JsonElement value = values.GetProperty(key);
            _inputs[key] = (entry.input, value.ValueKind == JsonValueKind.String ? value.GetString()! : value.GetRawText());
        }
    }

    public string? ConflictMessage(string code)
    {
        if (!code.StartsWith("hotkey_conflict_", StringComparison.Ordinal)) return null;
        string[] ids = code["hotkey_conflict_".Length..].Split('_');
        if (ids.Length != 2 || !_labels.TryGetValue(ids[0], out string? first) || !_labels.TryGetValue(ids[1], out string? second)) return null;
        return first + " 与 " + second + " 的快捷键冲突。请修改键位或关闭其中一个快捷键。";
    }
}
