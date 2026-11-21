using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>A normal, keyboard-accessible settings window; never edits credentials.</summary>
internal sealed class ToolboxSettingsWindow : Window
{
    readonly CancellationTokenSource _lifetime = new();
    readonly StackPanel _form = new() { Spacing = 16, Padding = new Thickness(24) };
    readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap };
    readonly Button _save = new() { Content = "保存", AccessKey = "S" };
    readonly Button _reload = new() { Content = "重新加载", AccessKey = "L" };
    readonly ComboBox _engine;
    readonly ComboBox _source;
    readonly ComboBox _target;
    readonly ComboBox _ttsEngine;
    readonly CheckBox _missing = new() { Content = "未配置云端密钥时使用 Google 保底" };
    readonly CheckBox _auth = new() { Content = "云端鉴权失败时静默使用 Google 保底" };
    readonly CheckBox _long = new() { Content = "允许长文分段翻译" };
    readonly TextBox _zhVoice = new() { Header = "中文音色", MaxLength = 128 };
    readonly TextBox _enVoice = new() { Header = "英文音色", MaxLength = 128 };
    readonly NumericField _rate = new("语速（-90 至 100，%）", -90, 100);
    readonly NumericField _pitch = new("音调（-100 至 100，Hz）", -100, 100);
    readonly NumericField _volume = new("音量调整（-100 至 100，%）", -100, 100);
    string _revision = "";
    bool _busy;
    bool _closed;
    public bool SettingsLoaded { get; private set; }

    public ToolboxSettingsWindow()
    {
        Title = "工具箱设置";
        IntPtr hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        double scale = Math.Max(96, Native.GetDpiForWindow(hwnd)) / 96.0;
        Native.RECT work = Native.TryGetWindowWorkArea(hwnd, out var area) ? area : Native.GetPrimaryWorkArea();
        AppWindow.Resize(new SizeInt32(Math.Min((int)(640 * scale), Math.Max(320, work.Right - work.Left - 40)),
                                      Math.Min((int)(800 * scale), Math.Max(320, work.Bottom - work.Top - 40))));
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _form.Children.Add(new TextBlock { Text = "翻译与朗读", FontSize = 24 });
        _form.Children.Add(new TextBlock
        {
            Text = "设置在下次请求生效。密钥仍从原配置或环境变量读取，不会写入此窗口。在线翻译和在线朗读会把文本发送给对应服务。",
            TextWrapping = TextWrapping.Wrap,
        });
        _engine = Choice("首选翻译引擎", ("腾讯云", "tencent"), ("Google", "google_gtx"), ("阿里云", "aliyun"), ("MyMemory", "mymemory"));
        _source = Choice("原文语言", ("自动识别中英", "auto"), ("中文", "zh"), ("英文", "en"));
        _target = Choice("目标语言", ("中英自动互译", "auto"), ("中文", "zh"), ("英文", "en"));
        foreach (UIElement element in new UIElement[] { _engine, _source, _target, _missing, _auth, _long })
            _form.Children.Add(element);
        _form.Children.Add(new TextBlock { Text = "朗读", FontSize = 20, Margin = new Thickness(0, 8, 0, 0) });
        _ttsEngine = Choice("朗读方式", ("本地优先，失败后在线回退", "auto"), ("仅本地 WinRT", "winrt"), ("在线 Edge", "edge"));
        foreach (UIElement element in new UIElement[] { _ttsEngine, _zhVoice, _enVoice, _rate.Root, _pitch.Root, _volume.Root })
            _form.Children.Add(element);
        _scroll.Content = _form;
        root.Children.Add(_scroll);

        var footer = new StackPanel { Spacing = 12, Padding = new Thickness(24, 12, 24, 20) };
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        footer.Children.Add(_status);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(_save); buttons.Children.Add(_reload);
        var close = new Button { Content = "关闭" };
        close.Click += (_, _) => Close();
        buttons.Children.Add(close); footer.Children.Add(buttons);
        Grid.SetRow(footer, 1); root.Children.Add(footer); Content = root;
        _save.Click += async (_, _) => await SaveAsync();
        _reload.Click += async (_, _) => await ReloadAsync();
        Closed += (_, _) => { _closed = true; _lifetime.Cancel(); HudLog.Line("settings-closed"); };
        SetBusy(true);
        _ = ReloadAsync();
    }

    static ComboBox Choice(string header, params (string label, string value)[] options)
    {
        var box = new ComboBox { Header = header, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var option in options)
            box.Items.Add(new ComboBoxItem { Content = option.label, Tag = option.value });
        return box;
    }

    static string Selected(ComboBox box) => (box.SelectedItem as ComboBoxItem)?.Tag as string ?? "";

    static void Select(ComboBox box, string? value)
    {
        box.SelectedItem = box.Items.Cast<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == value);
        if (box.SelectedItem == null)
            throw new InvalidOperationException("settings_unavailable");
    }

    void SetBusy(bool busy)
    {
        _busy = busy; _scroll.IsEnabled = !busy;
        _save.IsEnabled = !busy && _revision.Length > 0; _reload.IsEnabled = !busy;
    }

    async Task ReloadAsync()
    {
        _revision = "";
        SettingsLoaded = false;
        SetBusy(true); _status.Text = "正在读取设置…";
        try
        {
            JsonElement data = await PreferencesBridge.RunAsync(null, _lifetime.Token);
            if (_closed) return;
            Populate(data); _status.Text = "已读取当前设置。";
            SettingsLoaded = true;
            HudLog.Line("settings-loaded");
        }
        catch
        {
            if (!_closed) { _status.Text = "无法读取设置。请检查 Python 3.11+ 和本地配置，再重新加载。"; HudLog.Line("settings-load-failed"); }
        }
        finally { if (!_closed) SetBusy(false); }
    }

    void Populate(JsonElement data)
    {
        JsonElement translate = data.GetProperty("values").GetProperty("translate");
        JsonElement tts = data.GetProperty("values").GetProperty("tts");
        Select(_engine, translate.GetProperty("engine").GetString());
        Select(_source, translate.GetProperty("source_language").GetString());
        Select(_target, translate.GetProperty("target_language").GetString());
        _missing.IsChecked = translate.GetProperty("fallback_without_credentials").GetBoolean();
        _auth.IsChecked = translate.GetProperty("fallback_on_auth_error").GetBoolean();
        _long.IsChecked = translate.GetProperty("long_text_enabled").GetBoolean();
        Select(_ttsEngine, tts.GetProperty("engine").GetString());
        _zhVoice.Text = tts.GetProperty("zh_voice").GetString();
        _enVoice.Text = tts.GetProperty("en_voice").GetString();
        _rate.Load(tts.GetProperty("rate").GetString()!, "%");
        _pitch.Load(tts.GetProperty("pitch").GetString()!, "Hz");
        _volume.Load(tts.GetProperty("volume").GetString()!, "%");
        _revision = data.GetProperty("revision").GetString()!;
    }

    async Task SaveAsync()
    {
        if (_busy || _revision.Length == 0) return;
        NumericField? invalid = new[] { _rate, _pitch, _volume }.FirstOrDefault(field => !field.Validate());
        if (invalid != null)
        {
            _status.Text = "请修正标记的数值后保存。";
            invalid.Input.Focus(FocusState.Programmatic); return;
        }
        if (string.IsNullOrWhiteSpace(_zhVoice.Text) || string.IsNullOrWhiteSpace(_enVoice.Text))
        {
            _status.Text = "中英文音色不能为空。";
            (string.IsNullOrWhiteSpace(_zhVoice.Text) ? _zhVoice : _enVoice).Focus(FocusState.Programmatic); return;
        }
        var request = new
        {
            revision = _revision,
            changes = new
            {
                translate = new { engine = Selected(_engine), source_language = Selected(_source), target_language = Selected(_target),
                    fallback_without_credentials = _missing.IsChecked == true, fallback_on_auth_error = _auth.IsChecked == true,
                    long_text_enabled = _long.IsChecked == true },
                tts = new { engine = Selected(_ttsEngine), zh_voice = _zhVoice.Text, en_voice = _enVoice.Text,
                    rate = _rate.Value("%"), pitch = _pitch.Value("Hz"), volume = _volume.Value("%") },
            },
        };
        SetBusy(true); _status.Text = "正在保存…";
        try
        {
            JsonElement data = await PreferencesBridge.RunAsync(request, _lifetime.Token);
            if (_closed) return;
            Populate(data); _status.Text = "已保存，下次翻译或朗读生效。";
        }
        catch (Exception ex)
        {
            if (!_closed) _status.Text = ex.Message == "settings_changed_reload"
                ? "设置已被其他窗口修改。请重新加载后再保存。"
                : "保存失败，当前输入已保留。请检查本地配置和文件权限后重试。";
        }
        finally { if (!_closed) SetBusy(false); }
    }

    sealed class NumericField
    {
        readonly int _minimum;
        readonly int _maximum;
        readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap };
        public TextBox Input { get; }
        public StackPanel Root { get; } = new() { Spacing = 4 };
        public NumericField(string label, int minimum, int maximum)
        {
            _minimum = minimum; _maximum = maximum;
            Input = new TextBox { Header = label, MaxLength = 4 };
            Input.LostFocus += (_, _) => Validate();
            Root.Children.Add(Input); Root.Children.Add(_error);
        }
        public void Load(string value, string suffix) { Input.Text = value[..^suffix.Length]; _error.Text = ""; }
        public bool Validate()
        {
            bool ok = int.TryParse(Input.Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int value)
                && value >= _minimum && value <= _maximum;
            _error.Text = ok ? "" : $"请输入 {_minimum} 至 {_maximum} 的整数。";
            AutomationProperties.SetHelpText(Input, _error.Text);
            return ok;
        }
        public string Value(string suffix) => int.Parse(Input.Text, CultureInfo.InvariantCulture).ToString("+0;-0;+0", CultureInfo.InvariantCulture) + suffix;
    }
}
