using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
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
    readonly Button _restore = new() { Content = "预览 TOML 设置", AccessKey = "T" };
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
    readonly NavigationView _navigation;
    readonly StackPanel _brandName = new() { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
    readonly Dictionary<string, ModuleConfigurationForm> _moduleForms = new();
    readonly Dictionary<string, ControlSettingsForm> _controlForms = new();
    readonly StackPanel _moduleSwitches = new() { Spacing = 12, Padding = new Thickness(24, 0, 24, 8) };
    readonly Action? _controlsChanged;
    readonly bool _readOnlyProbe;
    string _controlsRevision = "";
    string _module = "text";
    Task _moduleLoad = Task.CompletedTask;
    string _revision = "";
    string _baseRevision = "";
    bool _resetPending;
    bool _busy;
    bool _closed;
    bool _brandLogoLoaded;
    public bool SettingsLoaded { get; private set; }
    internal bool DefaultsPreviewed => _resetPending;
    internal bool BrandLogoLoaded => _brandLogoLoaded;

    public ToolboxSettingsWindow(Action? controlsChanged = null, bool readOnlyProbe = false)
    {
        _controlsChanged = controlsChanged;
        _readOnlyProbe = readOnlyProbe;
        Title = "工具箱设置";
        IntPtr hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        HudApp.TryEnsureControlsResources("settings-window");
        _navigation = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Auto,
            IsSettingsVisible = false,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            OpenPaneLength = 240,
            CompactModeThresholdWidth = 600,
            ExpandedModeThresholdWidth = 880,
            Header = "翻译与朗读",
        };
        double scale = Math.Max(96, Native.GetDpiForWindow(hwnd)) / 96.0;
        Native.RECT work = Native.TryGetWindowWorkArea(hwnd, out var area) ? area : Native.GetPrimaryWorkArea();
        AppWindow.Resize(new SizeInt32(Math.Min((int)(1040 * scale), Math.Max(320, work.Right - work.Left - 40)),
                                      Math.Min((int)(800 * scale), Math.Max(320, work.Bottom - work.Top - 40))));
        var root = new Grid { MaxWidth = 960, HorizontalAlignment = HorizontalAlignment.Stretch };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        AddNavigationItem("常规", "general", Symbol.Setting);
        AddNavigationItem("功能与快捷键", "hotkeys", Symbol.Keyboard);
        AddNavigationItem("翻译与朗读", "text", Symbol.Document);
        AddNavigationItem("翻译高级", "translate", Symbol.Globe);
        AddNavigationItem("朗读高级", "tts", Symbol.Volume);
        AddNavigationItem("截图识别", "ocr", Symbol.Camera);
        AddNavigationItem("音频切换", "audio", Symbol.Switch);
        AddNavigationItem("主题、壁纸与背光", "theme", Symbol.Pictures);
        AddNavigationItem("电源与唤醒", "power", Symbol.Clock);
        AddNavigationItem("氛围灯", "rgb", Symbol.Highlight);
        SelectModule("text");
        AutomationProperties.SetName(_navigation, "设置分类导航");
        _navigation.PaneHeader = CreateBrandHeader();
        _navigation.PaneOpened += (_, _) => UpdateBrandHeader();
        _navigation.PaneClosed += (_, _) => UpdateBrandHeader();
        _navigation.DisplayModeChanged += (_, _) => UpdateBrandHeader();
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
        root.Children.Add(_moduleSwitches);
        Grid.SetRow(_scroll, 1);
        root.Children.Add(_scroll);

        var footer = new StackPanel { Spacing = 12, Padding = new Thickness(24, 12, 24, 20) };
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        footer.Children.Add(_status);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        root.SizeChanged += (_, _) => buttons.Orientation = root.ActualWidth < 400 ? Orientation.Vertical : Orientation.Horizontal;
        buttons.Children.Add(_save); buttons.Children.Add(_reload);
        var close = new Button { Content = "关闭" };
        close.Click += (_, _) => Close();
        buttons.Children.Add(close); footer.Children.Add(buttons);
        footer.Children.Add(_restore);
        Grid.SetRow(footer, 2); root.Children.Add(footer);
        _navigation.Content = root; Content = _navigation;
        _save.Click += async (_, _) => await SaveAsync();
        _reload.Click += async (_, _) => await ReloadAsync();
        _restore.Click += async (_, _) =>
        {
            if (_module == "hotkeys" && _controlForms.TryGetValue(_module, out var shortcuts))
            {
                shortcuts.ResetBindings(); _status.Text = "已恢复默认快捷键预览，保存后生效；功能开关保持当前输入。";
            }
            else await PreviewDefaultsAsync();
        };
        _navigation.SelectionChanged += (_, _) => _moduleLoad = SwitchModuleAsync();
        Closed += (_, _) => { _closed = true; _lifetime.Cancel(); HudLog.Line("settings-closed"); };
        SetBusy(true);
        _ = ReloadAsync();
    }

    void AddNavigationItem(string label, string module, Symbol symbol)
    {
        _navigation.MenuItems.Add(new NavigationViewItem
        {
            Content = label, Tag = module, Icon = new SymbolIcon(symbol),
        });
    }

    UIElement CreateBrandHeader()
    {
        var logo = new Image { Width = 32, Height = 32 };
        AutomationProperties.SetName(logo, "lat3ncy 工具箱 Logo");
        logo.ImageOpened += (_, _) => { _brandLogoLoaded = true; HudLog.Line("settings-brand-logo=loaded"); };
        logo.ImageFailed += (_, _) => HudLog.Line("settings-brand-logo=failed");
        logo.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "toolbox-logo.png")));
        _brandName.Children.Add(new TextBlock { Text = "lat3ncy", FontSize = 18 });
        _brandName.Children.Add(new TextBlock { Text = "工具箱设置", FontSize = 12 });
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(8, 12, 8, 16) };
        header.Children.Add(logo); header.Children.Add(_brandName);
        UpdateBrandHeader();
        return header;
    }

    void UpdateBrandHeader() => _brandName.Visibility = _navigation.IsPaneOpen ? Visibility.Visible : Visibility.Collapsed;

    void SelectModule(string module)
    {
        _navigation.SelectedItem = _navigation.MenuItems.Cast<NavigationViewItem>().Single(item => (string)item.Tag == module);
    }

    internal async Task VerifyNavigationLayoutAsync()
    {
        if (!_readOnlyProbe) throw new InvalidOperationException("probe_required");
        var original = AppWindow.Size;
        double scale = Math.Max(96, Native.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this))) / 96.0;
        try
        {
            foreach (var (width, mode) in new[] { (1040, NavigationViewDisplayMode.Expanded),
                (720, NavigationViewDisplayMode.Compact), (360, NavigationViewDisplayMode.Minimal) })
            {
                AppWindow.Resize(new SizeInt32((int)(width * scale), original.Height));
                await Task.Delay(120);
                if (_navigation.DisplayMode != mode || (string)((NavigationViewItem)_navigation.SelectedItem).Tag != "text")
                    throw new InvalidOperationException("navigation_layout_failed");
            }
            HudLog.Line("settings-navigation=passed expanded+compact+minimal");
        }
        finally { AppWindow.Resize(original); }
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
        foreach (Control toggle in _moduleSwitches.Children.OfType<Control>()) toggle.IsEnabled = !busy;
        foreach (NavigationViewItem item in _navigation.MenuItems) item.IsEnabled = !busy;
        bool loaded = _module == "text" ? _revision.Length > 0
            : _module is "general" or "hotkeys" ? _controlForms.ContainsKey(_module) : _moduleForms.ContainsKey(_module);
        _save.IsEnabled = !busy && loaded; _reload.IsEnabled = !busy;
        _restore.Visibility = _module is "text" or "hotkeys" ? Visibility.Visible : Visibility.Collapsed;
        _restore.Content = _module == "hotkeys" ? "恢复默认快捷键" : "预览 TOML 设置";
        _restore.IsEnabled = !busy && loaded;
    }

    async Task SwitchModuleAsync()
    {
        if (_busy) return;
        if (_navigation.SelectedItem is not NavigationViewItem selected) return;
        _module = (string)selected.Tag;
        _navigation.Header = selected.Content;
        if (_module is "general" or "hotkeys")
        {
            _moduleSwitches.Visibility = Visibility.Collapsed;
            if (_controlForms.TryGetValue(_module, out var controls))
            {
                _scroll.Content = controls.Root; SetBusy(false);
                _status.Text = "当前窗口保留了此页输入。保存应用，重新加载放弃修改。";
            }
            else await ReloadControlPageAsync();
        }
        else if (_module == "text")
        {
            _scroll.Content = _form;
            _status.Text = _resetPending ? "已预览 TOML 设置，尚未保存。重新加载可放弃。" : "当前窗口保留了各分类输入；关闭会放弃未保存内容。";
            SetBusy(false);
        }
        else if (_moduleForms.TryGetValue(_module, out var form))
        {
            _scroll.Content = form.Root;
            _status.Text = "已保留此页输入。保存仅应用当前分类，重新加载会放弃此页修改。";
            SetBusy(false);
        }
        else await ReloadModuleAsync();
        if (_module is not ("general" or "hotkeys")) await RefreshModuleSwitchesAsync();
        if (!_closed)
        {
            _scroll.ChangeView(null, 0, null);
            if (_navigation.DisplayMode != NavigationViewDisplayMode.Expanded) _navigation.IsPaneOpen = false;
        }
    }

    // Explicit lifecycle probe only: construct each real form, check that a
    // freshly loaded page submits no changes, then return to the preserved draft.
    internal async Task VerifyModulePagesAsync()
    {
        foreach (string module in new[] { "translate", "tts", "ocr", "audio", "theme", "power", "rgb" })
        {
            SelectModule(module);
            await _moduleLoad;
            if (!_moduleForms.TryGetValue(module, out var form)) throw new InvalidOperationException("module_load_failed");
            object? request = form.ReadRequest();
            if (request == null || JsonSerializer.SerializeToElement(request).GetProperty("changes").EnumerateObject().Any())
            {
                HudLog.Line("settings-module-draft-failed module=" + module);
                if (request != null)
                    foreach (var change in JsonSerializer.SerializeToElement(request).GetProperty("changes").EnumerateObject())
                        HudLog.Line("settings-module-draft-field module=" + module + " key=" + change.Name);
                throw new InvalidOperationException("module_draft_changed");
            }
        }
        foreach (string page in new[] { "general", "hotkeys" })
        {
            SelectModule(page); await _moduleLoad;
            if (!_controlForms.TryGetValue(page, out var form)
                || JsonSerializer.SerializeToElement(form.ReadRequest()).GetProperty("changes").EnumerateObject().Any())
                throw new InvalidOperationException("control_draft_changed");
        }
        SelectModule("text");
        await _moduleLoad;
        HudLog.Line("settings-module-pages=passed count=7 controls=2");
    }

    async Task ReloadControlPageAsync()
    {
        SetBusy(true); _status.Text = "正在读取功能与快捷键设置…";
        try
        {
            JsonElement data = await PreferencesBridge.RunControlsAsync(null, _lifetime.Token);
            if (_closed) return;
            var form = new ControlSettingsForm(data, _module);
            _controlForms[_module] = form; _scroll.Content = form.Root;
            _status.Text = "已读取。默认快捷键来自当前源码，保存不会改写源码。";
        }
        catch
        {
            if (!_closed)
            {
                if (!_controlForms.ContainsKey(_module)) _scroll.Content = new TextBlock { Text = "无法读取控制设置，请检查本仓库的控制配置后重新加载。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(24) };
                _status.Text = "读取失败，当前输入已保留。";
            }
        }
        finally { if (!_closed) SetBusy(false); }
    }

    async Task RefreshModuleSwitchesAsync()
    {
        _moduleSwitches.Visibility = Visibility.Visible;
        _moduleSwitches.Children.Clear(); SetBusy(true);
        try
        {
            JsonElement data = await PreferencesBridge.RunControlsAsync(null, _lifetime.Token);
            if (_closed) return;
            _controlsRevision = data.GetProperty("revision").GetString()!;
            JsonElement values = data.GetProperty("values");
            foreach (JsonElement module in data.GetProperty("modules").EnumerateArray())
            {
                string id = module.GetProperty("id").GetString()!;
                if (_module != id && !(_module == "text" && id is "translate" or "tts")) continue;
                string key = "module_" + id + "_enabled";
                var toggle = new ToggleSwitch { Header = "启用" + module.GetProperty("label").GetString(), IsOn = values.GetProperty(key).GetBoolean(), OnContent = "已启用", OffContent = "已关闭" };
                AutomationProperties.SetAutomationId(toggle, key);
                toggle.Toggled += async (_, _) => await SaveModuleSwitchAsync(key, toggle);
                _moduleSwitches.Children.Add(toggle);
            }
        }
        catch { if (!_closed) _moduleSwitches.Children.Add(new TextBlock { Text = "无法读取功能开关，请重新加载。" }); }
        finally { if (!_closed) SetBusy(false); }
    }

    void RetargetOwnControlRevision(string previous, string current)
    {
        foreach (var form in _controlForms.Values) form.RetargetOwnRevision(previous, current);
        if (_controlsRevision == previous) _controlsRevision = current;
    }

    async Task SaveModuleSwitchAsync(string key, ToggleSwitch toggle)
    {
        if (_readOnlyProbe || _busy || _controlsRevision.Length == 0) return;
        bool requested = toggle.IsOn;
        string revision = _controlsRevision;
        SetBusy(true); _status.Text = "正在应用功能开关…";
        try
        {
            var request = new { revision, changes = new Dictionary<string, object> { [key] = requested } };
            JsonElement saved = await PreferencesBridge.RunControlsAsync(request, _lifetime.Token);
            if (_closed) return;
            RetargetOwnControlRevision(revision, saved.GetProperty("revision").GetString()!);
            _controlsChanged?.Invoke();
            _status.Text = "已保存功能开关。快捷键自动加载，注册失败保留旧键位；后台功能在下次调用或现有循环生效。";
        }
        catch (Exception error)
        {
            if (!_closed)
            {
                toggle.IsOn = !requested;
                _status.Text = error.Message.StartsWith("hotkey_conflict_", StringComparison.Ordinal)
                    ? "启用后快捷键存在冲突，请先在功能与快捷键页调整。当前开关未保存。"
                    : "开关未保存，请重新加载后重试。当前运行策略保持。";
            }
        }
        finally { if (!_closed) SetBusy(false); }
    }

    async Task ReloadModuleAsync()
    {
        SetBusy(true); _status.Text = "正在读取模块配置…";
        try
        {
            JsonElement data = await PreferencesBridge.RunConfigurationAsync(_module, null, _lifetime.Token);
            if (_closed) return;
            var form = new ModuleConfigurationForm(data);
            _moduleForms[_module] = form; _scroll.Content = form.Root;
            _status.Text = "已读取配置。保存仅应用当前分类，不会立即执行系统或硬件操作。";
            HudLog.Line("settings-module-loaded module=" + _module);
        }
        catch
        {
            if (!_closed)
            {
                if (!_moduleForms.ContainsKey(_module))
                    _scroll.Content = new TextBlock { Text = "无法读取此模块。请检查配置格式和文件权限后重新加载。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(24) };
                _status.Text = "模块读取失败，已有输入保留。其他分类仍可使用。";
            }
        }
        finally { if (!_closed) SetBusy(false); }
    }

    async Task ReloadAsync()
    {
        if (_module is "general" or "hotkeys") { await ReloadControlPageAsync(); return; }
        if (_module != "text") { await ReloadModuleAsync(); await RefreshModuleSwitchesAsync(); return; }
        _revision = "";
        SettingsLoaded = false;
        SetBusy(true); _status.Text = "正在读取设置…";
        try
        {
            JsonElement data = await PreferencesBridge.RunAsync(null, _lifetime.Token);
            if (_closed) return;
            Populate(data); _status.Text = "已读取当前设置。";
            _resetPending = false;
            HudLog.Line("settings-loaded");
        }
        catch
        {
            if (!_closed) { _status.Text = "无法读取设置。请检查 Python 3.11+ 和本地配置，再重新加载。"; HudLog.Line("settings-load-failed"); }
        }
        finally { if (!_closed) SetBusy(false); }
        await RefreshModuleSwitchesAsync();
        SettingsLoaded = _revision.Length > 0;
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
        _baseRevision = data.GetProperty("base_revision").GetString()!;
    }

    internal async Task PreviewDefaultsAsync()
    {
        if (_busy || _revision.Length == 0 || _module != "text") return;
        SetBusy(true); _status.Text = "正在读取 TOML 设置…";
        try
        {
            JsonElement data = await PreferencesBridge.RunAsync(null, _lifetime.Token, defaults: true);
            if (_closed) return;
            if (data.GetProperty("revision").GetString() != _revision)
                throw new InvalidOperationException("settings_changed_reload");
            Populate(data); _resetPending = true;
            _status.Text = "已预览 TOML 设置，尚未保存。点击保存恢复，重新加载可放弃。密钥配置保持不变。";
            HudLog.Line("settings-defaults-previewed");
        }
        catch (Exception ex)
        {
            if (!_closed) _status.Text = ex.Message == "settings_changed_reload"
                ? "设置已被其他窗口修改。请重新加载后再预览。"
                : "无法预览 TOML 设置，当前输入已保留。请检查本地配置后重试。";
        }
        finally
        {
            if (!_closed)
            {
                SetBusy(false);
                if (_resetPending) _save.Focus(FocusState.Programmatic);
            }
        }
    }

    async Task SaveAsync()
    {
        if (_readOnlyProbe) return;
        if (_module is "general" or "hotkeys") { await SaveControlPageAsync(); return; }
        if (_module != "text") { await SaveModuleAsync(); return; }
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
            reset = _resetPending,
            base_revision = _baseRevision,
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
            Populate(data); _resetPending = false;
            _status.Text = "已保存，下次翻译或朗读生效。";
        }
        catch (Exception ex)
        {
            if (!_closed) _status.Text = ex.Message == "settings_changed_reload"
                ? "设置或配置文件已变化。请重新加载后再保存。"
                : "保存失败，当前输入已保留。请检查本地配置和文件权限后重试。";
        }
        finally { if (!_closed) SetBusy(false); }
    }

    async Task SaveControlPageAsync()
    {
        if (_busy || !_controlForms.TryGetValue(_module, out var form)) return;
        string revision = form.Revision;
        SetBusy(true); _status.Text = "正在保存控制设置…";
        try
        {
            JsonElement data = await PreferencesBridge.RunControlsAsync(form.ReadRequest(), _lifetime.Token);
            if (_closed) return;
            RetargetOwnControlRevision(revision, data.GetProperty("revision").GetString()!);
            var saved = new ControlSettingsForm(data, _module); _controlForms[_module] = saved; _scroll.Content = saved.Root;
            _controlsChanged?.Invoke();
            _status.Text = "已保存，快捷键自动加载；注册失败保留旧键位。默认键位仍保留在源码中。";
        }
        catch (Exception error)
        {
            if (!_closed) _status.Text = form.ConflictMessage(error.Message)
                ?? (error.Message == "settings_changed_reload" ? "控制设置已变化，请重新加载后再保存。当前输入已保留。"
                    : "保存失败，请检查快捷键格式和本地文件权限；当前输入已保留。");
        }
        finally { if (!_closed) SetBusy(false); }
    }

    async Task SaveModuleAsync()
    {
        if (_busy || !_moduleForms.TryGetValue(_module, out var form)) return;
        object? request = form.ReadRequest();
        if (request == null) { _status.Text = "请修正标记的字段后保存。"; return; }
        SetBusy(true); _status.Text = "正在保存当前分类…";
        try
        {
            JsonElement data = await PreferencesBridge.RunConfigurationAsync(_module, request, _lifetime.Token);
            if (_closed) return;
            var saved = new ModuleConfigurationForm(data);
            _moduleForms[_module] = saved; _scroll.Content = saved.Root;
            _status.Text = "已保存。" + saved.Effect;
            HudLog.Line("settings-module-saved module=" + _module);
        }
        catch (Exception error)
        {
            if (!_closed)
            {
                bool invalid = form.ShowValidation(error.Message);
                _status.Text = error.Message == "settings_changed_reload"
                    ? "配置已被其他窗口或编辑器修改。当前输入已保留，请重新加载后再保存。"
                    : error.Message == "protected_config_manual" ? "该配置是只读或加密文件，请使用原配置管理方式修改。当前输入已保留。"
                    : invalid ? "请修正标记的字段后保存，当前输入已保留。"
                    : "保存失败，当前输入和旧配置已保留。请检查字段范围、格式和文件权限后重试。";
            }
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
