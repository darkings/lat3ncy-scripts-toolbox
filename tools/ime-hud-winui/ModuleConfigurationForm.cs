using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Typed native editors; one cached draft per module.</summary>
internal sealed class ModuleConfigurationForm
{
    public StackPanel Root { get; } = new() { Spacing = 8, Padding = new Thickness(24, 12, 24, 20) };
    public string Revision { get; private set; }
    public string Effect { get; }
    readonly List<Field> _fields = new();
    public bool HasChanges { get; private set; }
    public event Action? Edited;
    void MarkEdited() { HasChanges = true; Edited?.Invoke(); }

    public ModuleConfigurationForm(JsonElement data, AppWindow? owner = null, string? firstGroupTitle = null)
    {
        Revision = data.GetProperty("revision").GetString()!;
        Effect = data.GetProperty("module").GetString() switch
        {
            "theme" => "保存后在下一次主题操作中使用。更改自动切换时间后，需重新应用切换计划。",
            "power" => "保存后需重新启动电源管理。保存本身不会改变系统电源设置。",
            "rgb" => "保存后需重新启动氛围灯。保存本身不会连接设备或改变灯光。",
            _ => data.GetProperty("effect").GetString()!,
        };
        if (Effect.Length > 0) Root.Children.Add(SettingsUi.Hint(Effect));
        string previous = "";
        StackPanel? groupPanel = null;
        foreach (JsonElement spec in data.GetProperty("fields").EnumerateArray())
        {
            string key = spec.GetProperty("key").GetString()!;
            string group = key.Contains('.') ? key[..key.LastIndexOf('.')] : "general";
            if (group != previous)
            {
                groupPanel = new StackPanel { Spacing = 4 };
                Root.Children.Add(new Expander { Header = previous.Length == 0 && firstGroupTitle != null ? firstGroupTitle : GroupLabel(group), Content = groupPanel,
                    IsExpanded = previous.Length == 0 || group == "schedule", HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 4, 0, 0) });
                previous = group;
            }
            var field = new Field(spec.Clone(), owner, MarkEdited); _fields.Add(field); groupPanel!.Children.Add(field.Root);
        }
        if (data.GetProperty("config").GetString() is string source && source.Length > 0) Root.Children.Add(new Expander { Header = "配置来源", Content = SettingsUi.Hint(source),
            HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 8, 0, 0) });
    }

    public bool IsNonDefault => _fields.Any(item => item.IsNonDefault);
    public void AcceptUnchanged() => HasChanges = false;
    public void RestoreDefaults() { foreach (var item in _fields) item.RestoreDefault(); }
    public void AcceptCommitted(JsonElement data)
    {
        Revision = data.GetProperty("revision").GetString()!;
        foreach (var spec in data.GetProperty("fields").EnumerateArray()) _fields.First(item => item.Key == spec.GetProperty("key").GetString()).AcceptCommitted(spec);
        HasChanges = _fields.Any(item => !item.TryRead(out _, out bool changed, false) || changed);
    }
    public void RetargetRevision(string previous, string current) { if (Revision == previous) Revision = current; }

    static string GroupLabel(string group) => group switch
    {
        "general" => "常规", "cache" => "缓存", "tencent" => "腾讯云", "aliyun" => "阿里云",
        "models.default" => "标准 OCR 模型", "models.mobile" => "轻量 OCR 模型", "preferred" => "首选设备与匹配",
        "behavior" => "运行行为", "tts" => "朗读联动", "schedule" => "自动切换时间", "mode_settings" => "深浅色联动",
        "wallpaper" => "桌面与锁屏壁纸", "theme_settings" => "Windows 主题", "cursor" => "鼠标指针方案",
        "keyboard_backlight" => "键盘背光", "power" => "睡眠与显示器", "caffeine" => "保持唤醒", "wake" => "设备与定时唤醒",
        "capture" => "屏幕采样", "process" => "颜色与暗场处理", "openrgb" => "OpenRGB 灯光", "hi75" => "HI75 键盘灯光", _ => "其他设置",
    };

    internal static string ChoiceLabel(string key, JsonElement value)
    {
        string raw = value.ValueKind == JsonValueKind.String ? value.GetString()! : value.GetRawText();
        return (key, raw) switch
        {
            ("general.switch_type", "mode") => "切换深浅色模式", ("general.switch_type", "theme") => "切换主题文件",
            ("schedule.trigger_mode", "sun") => "跟随日出日落", ("schedule.trigger_mode", "fixed") => "指定时间",
            ("ocr", "system") => "Windows 系统识别", ("ocr", "rapidocr") => "本地 RapidOCR",
            ("engine", "tencent") => "腾讯云", ("engine", "aliyun") => "阿里云", ("engine", "google_gtx") => "Google", ("engine", "mymemory") => "MyMemory",
            ("engine", "auto") => "本地优先，失败后在线回退", ("engine", "winrt") => "仅本地", ("engine", "edge") => "在线 Edge",
            ("source_language", "auto") => "自动识别", ("target_language", "auto") => "中英自动互译",
            (_, "zh") when key.EndsWith("_language") => "中文", (_, "en") when key.EndsWith("_language") => "英文",
            ("model", "default") => "标准模型", ("model", "mobile") => "轻量模型",
            (_, "light") when key.StartsWith("cursor.") => "浅色", (_, "dark") when key.StartsWith("cursor.") => "深色",
            (_, "0") when key.EndsWith("_level") => "关闭", (_, "1") when key.EndsWith("_level") => "低亮度",
            (_, "2") when key.EndsWith("_level") => "高亮度", ("capture.backend", "auto") => "自动选择",
            ("capture.backend", "mss") => "MSS（推荐）", ("capture.backend", "pil") => "Pillow",
            ("capture.backend", "dxcam") => "DXCam", _ => raw,
        };
    }

    public object? ReadRequest()
    {
        var changes = new Dictionary<string, object?>();
        foreach (Field field in _fields)
        {
            if (!field.TryRead(out object? value, out bool changed)) { HudLog.Line("settings-editor-invalid key=" + field.Key); return null; }
            if (changed) changes[field.Key] = value;
        }
        return new { revision = Revision, changes };
    }

    internal void VerifyEditorRoundTrips()
    {
        foreach (Field field in _fields) field.VerifyRoundTrip();
        if (JsonSerializer.SerializeToElement(ReadRequest()).GetProperty("changes").EnumerateObject().Any())
            throw new InvalidOperationException("editor_roundtrip_changed_draft");
    }

    public bool ShowValidation(string code)
    {
        Field? field = _fields.FirstOrDefault(item => code == "invalid_" + item.Key);
        if (field == null) return false;
        field.ShowError("此值不符合格式或范围，请按说明修正。", false); return true;
    }

    internal void SetProbeValue(string key, object value) => _fields.Single(item => item.Key == key).SetProbeValue(value);

    sealed class Field
    {
        JsonElement _spec;
        readonly Control _input;
        readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        readonly string _original;
        readonly bool _readonly;
        bool _edited;
        readonly Action _editedAction;
        public string Key { get; }
        public Border Root { get; }

        public Field(JsonElement spec, AppWindow? owner, Action edited)
        {
            _spec = spec; _editedAction = edited; Key = spec.GetProperty("key").GetString()!;
            _readonly = spec.GetProperty("readonly").GetBoolean();
            string label = spec.GetProperty("label").GetString()!;
            string kind = spec.GetProperty("type").GetString()!;
            JsonElement value = spec.GetProperty("value");
            _original = value.ValueKind == JsonValueKind.String ? value.GetString()! : value.GetRawText();
            JsonElement choices = spec.GetProperty("choices");
            if (Key == "model") choices = JsonSerializer.SerializeToElement(new[] { "default", "mobile" });
            if (Key is "cursor.light_color" or "cursor.dark_color") choices = JsonSerializer.SerializeToElement(new[] { "light", "dark" });
            FrameworkElement editor;
            if (kind == "bool") _input = SettingsUi.Toggle(value.GetBoolean());
            else if (choices.ValueKind == JsonValueKind.Array)
            {
                var combo = new ComboBox { MinWidth = 180 };
                foreach (JsonElement option in choices.EnumerateArray())
                {
                    var item = new ComboBoxItem { Content = ChoiceLabel(Key, option), Tag = option.Clone() }; combo.Items.Add(item);
                    if (JsonElement.DeepEquals(option, value)) combo.SelectedItem = item;
                }
                if (combo.SelectedItem == null)
                {
                    var item = new ComboBoxItem { Content = "当前：" + _original, Tag = value.Clone() }; combo.Items.Add(item); combo.SelectedItem = item;
                }
                _input = combo;
            }
            else if (kind is "int" or "number")
                _input = SettingsUi.Number(value.GetDouble(), kind == "int",
                    spec.GetProperty("minimum").ValueKind == JsonValueKind.Null ? -1e12 : spec.GetProperty("minimum").GetDouble(),
                    spec.GetProperty("maximum").ValueKind == JsonValueKind.Null ? 1e12 : spec.GetProperty("maximum").GetDouble());
            else if (Key is "schedule.fixed_light_time" or "schedule.fixed_dark_time"
                && TimeSpan.TryParseExact(_original, @"hh\:mm", CultureInfo.InvariantCulture, out TimeSpan time))
                _input = new TimePicker { ClockIdentifier = "24HourClock", SelectedTime = time, MinuteIncrement = 1 };
            else if (kind is "list" or "map") _input = new SettingsListEditor(value, kind == "map");
            else _input = new TextBox { Text = _original, MinWidth = 200, MaxLength = Math.Max(_original.Length, 2048), IsReadOnly = _readonly };
            _input.IsEnabled = !_readonly; editor = _input;
            if (_input is NumberBox percent && Key is "openrgb.brightness" or "hi75.brightness")
            {
                var slider = new Slider { Minimum = 0, Maximum = 100, StepFrequency = 1, Value = percent.Value, MinWidth = 160 };
                AutomationProperties.SetName(slider, label);
                slider.ValueChanged += (_, _) => { if (percent.Value != slider.Value) percent.Value = slider.Value; };
                percent.ValueChanged += (_, _) => { if (double.IsFinite(percent.Value) && slider.Value != percent.Value) slider.Value = percent.Value; };
                var panel = new StackPanel { Spacing = 4 }; panel.Children.Add(slider); panel.Children.Add(percent); editor = panel;
            }
            void Changed() { _edited = true; edited(); }
            if (_input is ToggleSwitch toggle) toggle.Toggled += (_, _) => Changed();
            else if (_input is ComboBox choice) choice.SelectionChanged += (_, _) => Changed();
            else if (_input is NumberBox number) { number.ValueChanged += (_, _) => Changed(); number.KeyDown += (_, _) => Changed(); }
            else if (_input is TimePicker timePicker) timePicker.SelectedTimeChanged += (_, _) => Changed();
            else if (_input is SettingsListEditor list) list.Edited += Changed;
            else if (_input is TextBox entry) entry.TextChanged += (_, _) => Changed();
            if (_input is TextBox text && PathKind(Key) is string pathKind && owner != null && !_readonly)
            {
                var panel = new Grid { ColumnSpacing = 8, MinWidth = 260 };
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                text.MinWidth = 0; panel.Children.Add(text);
                var browse = new Button { Content = "浏览…" }; Grid.SetColumn(browse, 1); panel.Children.Add(browse);
                AutomationProperties.SetName(browse, label + " 浏览");
                browse.Click += async (_, _) =>
                {
                    browse.IsEnabled = false;
                    try
                    {
                        string? path = pathKind == "folder"
                            ? (await new Microsoft.Windows.Storage.Pickers.FolderPicker(owner.Id).PickSingleFolderAsync())?.Path
                            : (await new Microsoft.Windows.Storage.Pickers.FileOpenPicker(owner.Id).PickSingleFileAsync())?.Path;
                        if (path != null) text.Text = path;
                    }
                    catch { ShowError("无法打开选择器，可直接填写路径。"); }
                    finally { browse.IsEnabled = true; }
                };
                editor = panel;
            }
            AutomationProperties.SetAutomationId(_input, Key); AutomationProperties.SetName(_input, label);
            string hint = spec.GetProperty("help").GetString() ?? "";
            if (_readonly) hint = "兼容项，只读。" + hint;
            var content = new StackPanel { Spacing = 6 };
            content.Children.Add(SettingsUi.Row(label.Replace("（每行一个）", "").Replace("（JSON 对象）", ""), editor, hint));
            content.Children.Add(_error); Root = SettingsUi.Card(content);
            string detail = hint + " 配置键：" + Key;
            if (spec.GetProperty("minimum").ValueKind != JsonValueKind.Null)
                detail += $"；范围：{spec.GetProperty("minimum")} 至 {spec.GetProperty("maximum")}";
            ToolTipService.SetToolTip(Root, detail); AutomationProperties.SetHelpText(_input, detail);
        }

        static string? PathKind(string key) => key switch
        {
            "wallpaper.directory" or "cursor.light_dir" or "cursor.dark_dir" or "caffeine.coffee_dir" => "folder",
            "wallpaper.light_wallpaper" or "wallpaper.dark_wallpaper" or "theme_settings.light_theme_file" or "theme_settings.dark_theme_file" or "hi75.exe" => "file",
            _ when key.StartsWith("models.") => "file", _ => null,
        };

        public bool TryRead(out object? value, out bool changed, bool reportErrors = true)
        {
            value = null; changed = false; if (reportErrors) _error.Visibility = Visibility.Collapsed;
            if (_readonly || !_edited) return true;
            string kind = _spec.GetProperty("type").GetString()!;
            try
            {
                if (_input is ToggleSwitch toggle) value = toggle.IsOn;
                else if (_input is ComboBox combo) value = (JsonElement)((ComboBoxItem)combo.SelectedItem).Tag;
                else if (_input is TimePicker time) value = time.SelectedTime?.ToString(@"hh\:mm", CultureInfo.InvariantCulture) ?? throw new FormatException();
                else if (_input is NumberBox number)
                {
                    if (!SettingsUi.TryNumber(number, kind == "int", out double parsed)) throw new FormatException();
                    if (parsed == _spec.GetProperty("value").GetDouble()) return true;
                    value = kind == "int" ? (object)(long)parsed : parsed;
                }
                else if (_input is SettingsListEditor list)
                {
                    if (!list.Dirty) return true;
                    value = list.Read();
                }
                else value = ((TextBox)_input).Text;
                changed = !JsonElement.DeepEquals(_spec.GetProperty("value"), JsonSerializer.SerializeToElement(value));
                return true;
            }
            catch (Exception error) when (error is FormatException or OverflowException or JsonException)
            {
                if (reportErrors) ShowError(kind == "map" ? "请填写不重复的灯区名称和有效 LED 数量。" : "请输入范围内的有效值。", false); return false;
            }
        }
        public bool IsNonDefault => !_readonly && (!TryRead(out object? value, out _, false)
            || !JsonElement.DeepEquals(value == null ? _spec.GetProperty("value") : JsonSerializer.SerializeToElement(value), _spec.GetProperty("default")));
        public void AcceptCommitted(JsonElement data)
        {
            bool valid = TryRead(out object? current, out _, false);
            var value = current == null ? _spec.GetProperty("value") : JsonSerializer.SerializeToElement(current);
            _spec = data.Clone(); _edited = !valid || !JsonElement.DeepEquals(value, data.GetProperty("value"));
        }
        public void RestoreDefault()
        {
            if (_readonly) return;
            JsonElement value = _spec.GetProperty("default");
            if (_input is ToggleSwitch toggle) toggle.IsOn = value.GetBoolean();
            else if (_input is ComboBox combo) combo.SelectedItem = combo.Items.Cast<ComboBoxItem>().First(item => JsonElement.DeepEquals((JsonElement)item.Tag, value));
            else if (_input is NumberBox number) { number.Value = value.GetDouble(); number.Text = number.Value.ToString("G", CultureInfo.CurrentCulture); }
            else if (_input is TimePicker time) time.SelectedTime = TimeSpan.ParseExact(value.GetString()!, @"hh\:mm", CultureInfo.InvariantCulture);
            else if (_input is SettingsListEditor list) list.ReplaceValues(value);
            else ((TextBox)_input).Text = value.GetString();
            _edited = true; _error.Visibility = Visibility.Collapsed; _editedAction();
        }
        internal void SetProbeValue(object value)
        {
            if (_input is ToggleSwitch toggle) toggle.IsOn = (bool)value;
            else if (_input is NumberBox number) { number.Value = Convert.ToDouble(value, CultureInfo.InvariantCulture); number.Text = number.Value.ToString("G", CultureInfo.CurrentCulture); }
            else if (_input is ComboBox combo) combo.SelectedItem = combo.Items.Cast<ComboBoxItem>().Single(item => JsonElement.DeepEquals((JsonElement)item.Tag, JsonSerializer.SerializeToElement(value)));
            else if (_input is TextBox text) text.Text = (string)value;
            else throw new InvalidOperationException("unsupported_probe_editor");
            _edited = true; _editedAction();
        }
        public void ShowError(string message, bool focus = true)
        {
            _error.Text = message; _error.Visibility = Visibility.Visible; AutomationProperties.SetHelpText(_input, message);
            for (DependencyObject? current = Root; current != null; current = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(current))
                if (current is Expander expander) expander.IsExpanded = true;
            if (focus) _input.DispatcherQueue.TryEnqueue(() => { _input.StartBringIntoView(); _input.Focus(FocusState.Programmatic); });
        }
        public void VerifyRoundTrip()
        {
            if (_readonly) return;
            if (_input is NumberBox number)
            {
                double original = number.Value;
                double next = original < number.Maximum ? Math.Min(number.Maximum, original + number.SmallChange) : Math.Max(number.Minimum, original - number.SmallChange);
                try
                {
                    number.Value = next;
                    if (!TryRead(out object? value, out bool changed) || (next != original && !changed)
                        || Convert.ToDouble(value ?? original, CultureInfo.InvariantCulture) != next)
                        throw new InvalidOperationException("number_editor_roundtrip_failed");
                }
                finally { number.Value = original; }
            }
            else if (_input is ToggleSwitch toggle)
            {
                bool original = toggle.IsOn;
                try { toggle.IsOn = !original; if (!TryRead(out object? value, out bool changed) || !changed || (bool)value! == original)
                    throw new InvalidOperationException("toggle_editor_roundtrip_failed"); }
                finally { toggle.IsOn = original; }
            }
            else if (_input is TimePicker time && time.SelectedTime is TimeSpan original)
            {
                try { time.SelectedTime = TimeSpan.FromMinutes((original.TotalMinutes + 1) % 1440);
                    if (!TryRead(out object? value, out bool changed) || !changed || value is not string)
                        throw new InvalidOperationException("time_editor_roundtrip_failed"); }
                finally { time.SelectedTime = original; }
            }
            else if (_input is ComboBox choice && choice.Items.Count > 1)
            {
                int originalIndex = choice.SelectedIndex;
                try { choice.SelectedIndex = (originalIndex + 1) % choice.Items.Count;
                    if (!TryRead(out object? value, out bool changed) || !changed || value is not JsonElement)
                        throw new InvalidOperationException("choice_editor_roundtrip_failed"); }
                finally { choice.SelectedIndex = originalIndex; }
            }
            else if (_input is SettingsListEditor list) list.VerifyRoundTrip();
        }
    }
}
