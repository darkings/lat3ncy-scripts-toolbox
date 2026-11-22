using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>One cached draft per module; only allowlisted changed values leave the window.</summary>
internal sealed class ModuleConfigurationForm
{
    public StackPanel Root { get; } = new() { Spacing = 16, Padding = new Thickness(24) };
    public string Revision { get; }
    public string Effect { get; }
    readonly List<Field> _fields = new();

    public ModuleConfigurationForm(JsonElement data)
    {
        Revision = data.GetProperty("revision").GetString()!;
        Effect = data.GetProperty("effect").GetString()!;
        Root.Children.Add(new TextBlock { Text = data.GetProperty("title").GetString(), FontSize = 24 });
        Root.Children.Add(new TextBlock { Text = Effect, TextWrapping = TextWrapping.Wrap });
        Root.Children.Add(new TextBlock { Text = "配置文件：" + data.GetProperty("config").GetString(), TextWrapping = TextWrapping.Wrap });
        string previous = "";
        foreach (JsonElement spec in data.GetProperty("fields").EnumerateArray())
        {
            string key = spec.GetProperty("key").GetString()!;
            string group = key.Contains('.') ? key[..key.LastIndexOf('.')] : "常规";
            if (group != previous)
            {
                Root.Children.Add(new TextBlock { Text = group, FontSize = 18, Margin = new Thickness(0, 8, 0, 0) });
                previous = group;
            }
            var field = new Field(spec.Clone());
            _fields.Add(field); Root.Children.Add(field.Root);
        }
    }

    public object? ReadRequest()
    {
        var changes = new Dictionary<string, object?>();
        foreach (Field field in _fields)
        {
            if (!field.TryRead(out object? value, out bool changed)) return null;
            if (changed) changes[field.Key] = value;
        }
        return new { revision = Revision, changes };
    }

    public bool ShowValidation(string code)
    {
        Field? field = _fields.FirstOrDefault(item => code == "invalid_" + item.Key);
        if (field == null) return false;
        field.ShowError("此值不符合字段格式或范围，请按说明修正。");
        return true;
    }

    sealed class Field
    {
        readonly JsonElement _spec;
        readonly Control _input;
        readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap };
        readonly string _original;
        readonly bool _readonly;
        public string Key { get; }
        public StackPanel Root { get; } = new() { Spacing = 4 };

        public Field(JsonElement spec)
        {
            _spec = spec;
            Key = spec.GetProperty("key").GetString()!;
            _readonly = spec.GetProperty("readonly").GetBoolean();
            string label = spec.GetProperty("label").GetString()!;
            string kind = spec.GetProperty("type").GetString()!;
            JsonElement value = spec.GetProperty("value");
            _original = Display(value, kind);
            JsonElement choices = spec.GetProperty("choices");
            if (kind == "bool")
                _input = new CheckBox { Content = label, IsChecked = value.GetBoolean(), IsEnabled = !_readonly };
            else if (choices.ValueKind == JsonValueKind.Array)
            {
                var combo = new ComboBox { Header = label, HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = !_readonly };
                foreach (JsonElement option in choices.EnumerateArray())
                {
                    var item = new ComboBoxItem { Content = Display(option, kind), Tag = option.Clone() };
                    combo.Items.Add(item);
                    if (Display(option, kind) == _original) combo.SelectedItem = item;
                }
                if (combo.SelectedItem == null)
                {
                    var item = new ComboBoxItem { Content = "当前：" + _original, Tag = value.Clone() };
                    combo.Items.Add(item); combo.SelectedItem = item;
                }
                _input = combo;
            }
            else
            {
                bool multiline = kind is "list" or "map";
                var text = new TextBox { Header = label, AcceptsReturn = multiline,
                    TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
                    MaxLength = Math.Max(_original.Length, multiline ? 16384 : 2048), IsReadOnly = _readonly,
                    Text = _original,
                    MinHeight = multiline ? 88 : 0, MaxHeight = multiline ? 180 : double.PositiveInfinity };
                ScrollViewer.SetVerticalScrollBarVisibility(text, multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled);
                _input = text;
            }
            AutomationProperties.SetAutomationId(_input, Key);
            Root.Children.Add(_input);
            string hint = spec.GetProperty("help").GetString() ?? "";
            if (spec.GetProperty("minimum").ValueKind != JsonValueKind.Null)
                hint = $"范围：{spec.GetProperty("minimum")} 至 {spec.GetProperty("maximum")}。 " + hint;
            hint += (hint.Length > 0 ? "\n" : "") + (spec.GetProperty("source").GetString() == "config" ? "来源：配置文件" : "来源：内置缺省值");
            Root.Children.Add(new TextBlock { Text = hint, TextWrapping = TextWrapping.Wrap, FontSize = 12 });
            AutomationProperties.SetHelpText(_input, hint);
            Root.Children.Add(_error);
        }

        static string Display(JsonElement value, string kind) => kind == "list"
            ? string.Join('\n', value.EnumerateArray().Select(item => item.GetString()))
            : value.ValueKind == JsonValueKind.String ? value.GetString()! : value.GetRawText();

        public bool TryRead(out object? value, out bool changed)
        {
            value = null; changed = false; _error.Text = "";
            if (_readonly) return true;
            string kind = _spec.GetProperty("type").GetString()!;
            string current;
            if (_input is CheckBox check)
            {
                value = check.IsChecked == true; current = (bool)value ? "true" : "false";
            }
            else if (_input is ComboBox combo)
            {
                var selected = (JsonElement)((ComboBoxItem)combo.SelectedItem).Tag;
                value = selected; current = Display(selected, kind);
            }
            else
            {
                current = ((TextBox)_input).Text;
                if (kind is "list" or "map") current = current.Replace("\r\n", "\n").Replace('\r', '\n');
                if (current == _original) return true;
                try
                {
                    value = kind switch
                    {
                        "int" => long.Parse(current, NumberStyles.Integer, CultureInfo.InvariantCulture),
                        "number" => double.Parse(current, NumberStyles.Float, CultureInfo.InvariantCulture),
                        "list" => current.Split('\n').Select(line => line.Trim()).Where(line => line.Length > 0).ToArray(),
                        "map" => JsonSerializer.Deserialize<Dictionary<string, int>>(current) ?? throw new FormatException(),
                        _ => current,
                    };
                    if (kind is "int" or "number")
                    {
                        double number = Convert.ToDouble(value, CultureInfo.InvariantCulture);
                        if (!double.IsFinite(number)
                            || (_spec.GetProperty("minimum").ValueKind != JsonValueKind.Null && number < _spec.GetProperty("minimum").GetDouble())
                            || (_spec.GetProperty("maximum").ValueKind != JsonValueKind.Null && number > _spec.GetProperty("maximum").GetDouble()))
                            throw new FormatException();
                    }
                }
                catch (Exception error) when (error is FormatException or OverflowException or JsonException)
                {
                    _error.Text = kind == "map" ? "请输入有效的 JSON 对象，值为 LED 数量整数。" : "请按字段说明输入有效数值。";
                    AutomationProperties.SetHelpText(_input, _error.Text);
                    _input.Focus(FocusState.Programmatic); return false;
                }
            }
            changed = current != _original;
            return true;
        }

        public void ShowError(string message)
        {
            _error.Text = message;
            AutomationProperties.SetHelpText(_input, message);
            // The save finally block reenables the form before focus is useful.
            _input.DispatcherQueue.TryEnqueue(() => _input.Focus(FocusState.Programmatic));
        }
    }
}
