using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Lat3ncyToolbox.ImeHudWinUi;

internal static class SettingsUi
{
    public static ToggleSwitch Toggle(bool value)
    {
        var input = new ToggleSwitch { IsOn = value, MinWidth = 44, Width = 44,
            OnContent = null, OffContent = null, HorizontalAlignment = HorizontalAlignment.Right,
            HorizontalContentAlignment = HorizontalAlignment.Right };
        input.Loaded += (_, _) => SettingsToggleLayout.TrimTextColumn(input);
        return input;
    }
    public static TextBlock Hint(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap,
        FontSize = 12, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };

    public static Border Card(UIElement content) => new() { Child = content, Padding = new Thickness(16, 12, 16, 12),
        CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1),
        Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
        BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"] };

    public static Grid Row(string label, FrameworkElement editor, string help = "")
    {
        var row = new Grid { ColumnSpacing = 20, RowSpacing = 8, MinHeight = 40 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var copy = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        copy.Children.Add(new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap });
        if (help.Length > 0) copy.Children.Add(Hint(help));
        row.Children.Add(copy); Grid.SetColumn(editor, 1); row.Children.Add(editor);
        editor.VerticalAlignment = VerticalAlignment.Center;
        row.SizeChanged += (_, _) =>
        {
            bool narrow = row.ActualWidth < 540 && editor is not ToggleSwitch;
            Grid.SetColumn(editor, narrow ? 0 : 1); Grid.SetRow(editor, narrow ? 1 : 0);
            Grid.SetColumnSpan(copy, narrow ? 2 : 1); Grid.SetColumnSpan(editor, narrow ? 2 : 1);
            editor.HorizontalAlignment = narrow ? HorizontalAlignment.Stretch : HorizontalAlignment.Right;
        };
        return row;
    }

    public static NumberBox Number(double value, bool integer, double minimum, double maximum) => new()
    {
        Value = value, Minimum = minimum, Maximum = maximum, SmallChange = integer ? 1 : .1,
        SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
        ValidationMode = NumberBoxValidationMode.Disabled, MinWidth = 160,
        NumberFormatter = new SettingsNumberFormatter(),
    };

    public static bool TryNumber(NumberBox box, bool integer, out double value)
    {
        // Collapsed Expanders defer template creation, including NumberBox.Text.
        if (!box.IsLoaded && string.IsNullOrEmpty(box.Text)) value = box.Value;
        else if (!double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out value)) return false;
        return double.IsFinite(value) && (!integer || value == Math.Truncate(value)) && value >= box.Minimum && value <= box.Maximum;
    }
}

/// <summary>Keep the native template/states, remove only its unused 12 DIP text column.</summary>
internal static class SettingsToggleLayout
{
    static FrameworkElement? Find(DependencyObject parent, string name)
    {
        if (parent is FrameworkElement element && element.Name == name) return element;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            if (Find(VisualTreeHelper.GetChild(parent, i), name) is FrameworkElement child) return child;
        return null;
    }
    internal static void TrimTextColumn(ToggleSwitch input)
    {
        if (Find(input, "SwitchAreaGrid") is Grid area && VisualTreeHelper.GetParent(area) is Grid layout
            && layout.ColumnDefinitions.Count == 3)
        {
            layout.ColumnDefinitions[1].Width = new GridLength(0); layout.ColumnDefinitions[1].MaxWidth = 0;
            layout.HorizontalAlignment = HorizontalAlignment.Right;
        }
    }
    internal static double TrackTrailingSpace(ToggleSwitch input) => Find(input, "OuterBorder") is FrameworkElement track
        ? input.ActualWidth - track.TransformToVisual(input).TransformPoint(new Windows.Foundation.Point()).X - track.ActualWidth : double.NaN;
}

internal sealed class SettingsNumberFormatter : Windows.Globalization.NumberFormatting.INumberFormatter2,
    Windows.Globalization.NumberFormatting.INumberParser
{
    public string FormatDouble(double value) => value.ToString("G", CultureInfo.CurrentCulture);
    public string FormatInt(long value) => value.ToString(CultureInfo.CurrentCulture);
    public string FormatUInt(ulong value) => value.ToString(CultureInfo.CurrentCulture);
    public double? ParseDouble(string text) => double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value) ? value : null;
    public long? ParseInt(string text) => long.TryParse(text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var value) ? value : null;
    public ulong? ParseUInt(string text) => ulong.TryParse(text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var value) ? value : null;
}

/// <summary>Structured editable rows instead of a raw multiline array/JSON field.</summary>
internal sealed class SettingsListEditor : UserControl
{
    readonly StackPanel _rows = new() { Spacing = 6 };
    readonly List<(TextBox name, NumberBox? count)> _items = new();
    readonly bool _map;
    public bool Dirty { get; private set; }
    public event Action? Edited;
    void Changed() { if (!_loading) { Dirty = true; Edited?.Invoke(); } }
    bool _loading = true;
    public SettingsListEditor(JsonElement value, bool map)
    {
        _map = map;
        var root = new StackPanel { Spacing = 8 }; root.Children.Add(_rows);
        if (map) foreach (var item in value.EnumerateObject()) Add(item.Name, item.Value.GetInt32());
        else foreach (var item in value.EnumerateArray()) Add(item.GetString()!, 0);
        var add = new Button { Content = map ? "添加灯区" : "添加一项" };
        add.Click += (_, _) => { Add("", map ? 1 : 0); Changed(); _items[^1].name.Focus(FocusState.Programmatic); };
        root.Children.Add(add); Content = root; _loading = false;
    }
    void Add(string text, int value)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBox { Text = text, PlaceholderText = _map ? "灯区名称" : "匹配关键词", MaxLength = _map ? 64 : 128 };
        name.TextChanged += (_, _) => Changed();
        row.Children.Add(name);
        NumberBox? count = _map ? SettingsUi.Number(value, true, 0, 4096) : null;
        if (count != null) { count.MinWidth = 112; count.ValueChanged += (_, _) => Changed();
            Grid.SetColumn(count, 1); row.Children.Add(count); AutomationProperties.SetName(count, "LED 数量"); }
        var remove = new Button { Content = new SymbolIcon(Symbol.Delete) };
        AutomationProperties.SetName(remove, "移除此项"); ToolTipService.SetToolTip(remove, "移除此项");
        remove.Click += (_, _) => { _items.RemoveAll(item => item.name == name); _rows.Children.Remove(row); Changed(); };
        Grid.SetColumn(remove, 2); row.Children.Add(remove);
        _items.Add((name, count)); _rows.Children.Add(row);
    }
    public object Read()
    {
        if (!_map) return _items.Select(item => item.name.Text.Trim()).Where(text => text.Length > 0).ToArray();
        var result = new Dictionary<string, int>();
        foreach (var item in _items)
        {
            string name = item.name.Text.Trim();
            if (!Regex.IsMatch(name, "^[A-Za-z0-9_-]{1,64}$") || !SettingsUi.TryNumber(item.count!, true, out double count) || !result.TryAdd(name, (int)count))
                throw new FormatException("invalid_map_row");
        }
        return result;
    }
    internal void VerifyRoundTrip()
    {
        int before = _items.Count;
        _loading = true;
        try
        {
            string key = "Probe" + Guid.NewGuid().ToString("N"); Add(key, 17);
            object value = Read();
            if (_map ? !((Dictionary<string, int>)value).ContainsKey(key) : !((string[])value).Contains(key))
                throw new InvalidOperationException("list_editor_roundtrip_failed");
        }
        finally { if (_items.Count > before) { _items.RemoveAt(_items.Count - 1); _rows.Children.RemoveAt(_rows.Children.Count - 1); } _loading = false; }
    }
    internal void ReplaceValues(JsonElement value)
    {
        _loading = true; _items.Clear(); _rows.Children.Clear();
        if (_map) foreach (var item in value.EnumerateObject()) Add(item.Name, item.Value.GetInt32());
        else foreach (var item in value.EnumerateArray()) Add(item.GetString()!, 0);
        _loading = false; Changed();
    }
}

/// <summary>Choose modifiers and a key without sending a shortcut to the desktop.</summary>
internal sealed class SettingsHotkeyEditor : UserControl
{
    readonly ComboBox _modifier = new() { MinWidth = 170 };
    readonly ComboBox _key = new() { IsEditable = true, MinWidth = 110 };
    string _original = "";
    bool _loading;
    public event Action? Edited;
    void Changed() { if (!_loading) Edited?.Invoke(); }
    public SettingsHotkeyEditor(string binding)
    {
        foreach (string modifier in new[] { "caps", "", "^", "!", "+", "#", "^!", "^+", "!+", "^!+", "^#", "!#", "+#", "^!#", "^+#", "!+#", "^!+#" })
            _modifier.Items.Add(new ComboBoxItem { Tag = modifier, Content = modifier == "caps" ? "CapsLock" : modifier == "" ? "无修饰键" :
                string.Join(" + ", modifier.Select(c => c switch { '^' => "Ctrl", '!' => "Alt", '+' => "Shift", _ => "Win" })) });
        foreach (string key in Enumerable.Range('A', 26).Select(c => ((char)c).ToString()).Concat(Enumerable.Range(0, 10).Select(n => n.ToString()))
            .Concat(Enumerable.Range(1, 24).Select(n => "F" + n)).Concat(new[] { "Tab", "Space", "Enter", "Esc", "Backspace", "Delete", "Home", "End", "PgUp", "PgDn", "Up", "Down", "Left", "Right", ".", ",", "/", "` / ~" })) _key.Items.Add(key);
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        panel.Children.Add(_modifier); panel.Children.Add(_key); Content = panel;
        AutomationProperties.SetName(_modifier, "组合修饰键"); AutomationProperties.SetName(_key, "主键");
        _modifier.SelectionChanged += (_, _) => Changed();
        _key.SelectionChanged += (_, _) => Changed();
        _key.TextSubmitted += (_, _) => Changed();
        _key.RegisterPropertyChangedCallback(ComboBox.TextProperty, (_, _) => Changed());
        _key.LostFocus += (_, _) => { if (_key.Text != DisplayKey(CurrentKey(_original))) Changed(); };
        panel.SizeChanged += (_, _) => panel.Orientation = panel.ActualWidth < 290 ? Orientation.Vertical : Orientation.Horizontal;
        Set(binding);
    }
    static string CurrentKey(string value) => value.Contains('&') ? value.Split('&')[1].Trim().ToUpperInvariant()
        : Regex.Replace(value, @"^[~$!^+#]*", "").ToUpperInvariant();
    static string Canonical(string value) => (value.Contains('&') ? "caps" :
        new string("^!+#".Where(c => value.TakeWhile(token => "~$!^+#".Contains(token)).Contains(c)).ToArray())) + ":" + CurrentKey(value);
    static string DisplayKey(string key) => key == "SC029" ? "` / ~" : key;
    public static string Describe(string binding)
    {
        string key = DisplayKey(CurrentKey(binding));
        if (binding.Contains('&')) return "CapsLock + " + key;
        string[] modifiers = binding.TakeWhile(c => "~$!^+#".Contains(c)).Where(c => "^!+#".Contains(c))
            .Select(c => c switch { '^' => "Ctrl", '!' => "Alt", '+' => "Shift", _ => "Win" }).ToArray();
        return string.Join(" + ", modifiers.Append(key));
    }
    public void Set(string binding)
    {
        _loading = true; _original = binding;
        string modifiers = binding.Contains('&') ? "caps" : new string("^!+#".Where(c => binding.TakeWhile(c => "~$!^+#".Contains(c)).Contains(c)).ToArray());
        _modifier.SelectedItem = _modifier.Items.Cast<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == modifiers);
        _key.Text = DisplayKey(CurrentKey(binding)); _loading = false;
    }
    public string Value
    {
        get
        {
            string value = ((_modifier.SelectedItem as ComboBoxItem)?.Tag as string == "caps" ? "~CapsLock & "
                : (_modifier.SelectedItem as ComboBoxItem)?.Tag as string ?? "") + (_key.Text.Trim() == "` / ~" ? "sc029" : _key.Text.Trim());
            return string.Equals(Canonical(value), Canonical(_original), StringComparison.OrdinalIgnoreCase)
                ? _original : value;
        }
    }
}
