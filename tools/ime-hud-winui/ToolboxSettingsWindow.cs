using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Native settings with per-page drafts, serialized autosave and explicit reload.</summary>
internal sealed class ToolboxSettingsWindow : Window
{
    readonly CancellationTokenSource _lifetime = new();
    readonly SemaphoreSlim _writer = new(1, 1);
    readonly SemaphoreSlim _loader = new(1, 1);
    readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    readonly InfoBar _error = new() { IsOpen = false, IsClosable = true, Severity = InfoBarSeverity.Error };
    readonly Button _recover = new();
    readonly Dictionary<string, string> _saveErrors = new();
    string? _errorPage;
    readonly Button _restore = new() { Content = "默认", Visibility = Visibility.Collapsed };
    readonly Button _reload = new() { Content = "重载", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(8) };
    readonly NavigationView _navigation;
    readonly SettingsSearch _search;
    readonly Dictionary<string, Expander> _searchSections = new();
    int _searchNavigation;
    readonly TitleBar _titleBar;
    readonly TextBlock _pageTitle = new() { FontSize = 28, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel _pageActions = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
    readonly StackPanel _brandName = new() { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
    readonly Dictionary<string, ModuleConfigurationForm> _moduleForms = new();
    readonly Dictionary<string, PreferenceSettingsForm> _preferenceForms = new();
    readonly Dictionary<string, ControlSettingsForm> _controlForms = new();
    readonly Dictionary<string, UIElement> _pages = new();
    readonly Dictionary<string, bool> _moduleValues = new();
    readonly Dictionary<string, bool> _moduleOriginals = new();
    readonly Dictionary<string, string> _moduleRevisions = new();
    readonly HashSet<string> _pending = new();
    readonly HashSet<string> _resetPreferences = new();
    readonly Action? _controlsChanged;
    readonly bool _readOnlyProbe;
    readonly DispatcherQueueTimer _debounce;
    readonly DispatcherQueueTimer _reloadPoll;
    CredentialsSettingsForm? _credentials;
    string _controlsRevision = "";
    string _module = "translate";
    Task _moduleLoad = Task.CompletedTask;
    bool _suppress;
    bool _closed;
    bool _allowClose;
    bool _closing;
    bool _brandLogoLoaded;
    bool _defaultsPreviewed;
    bool _reloading;
    bool _startingReload;
    TaskCompletionSource<JsonElement>? _reloadCompletion;
    string _reloadId = "";
    DateTime _reloadStarted;
    IntPtr _windowIcon;
    internal bool WindowIconReady => _windowIcon != IntPtr.Zero;
    public bool SettingsLoaded { get; private set; }
    internal bool DefaultsPreviewed => _defaultsPreviewed;
    internal bool BrandLogoLoaded => _brandLogoLoaded;

    public ToolboxSettingsWindow(Action? controlsChanged = null, bool readOnlyProbe = false)
    {
        _controlsChanged = controlsChanged; _readOnlyProbe = readOnlyProbe;
        Title = "工具箱设置";
        IntPtr hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Native.SyncWindowTitleTheme(hwnd); HudApp.TryEnsureControlsResources("settings-window");
        _reload.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        _titleBar = new TitleBar { Title = Title, IsPaneToggleButtonVisible = true,
            IconSource = new ImageIconSource { ImageSource = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "toolbox-logo.png"))) } };
        _navigation = new NavigationView { PaneDisplayMode = NavigationViewPaneDisplayMode.Auto, IsSettingsVisible = false,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed, OpenPaneLength = 240, CompactModeThresholdWidth = 600,
            ExpandedModeThresholdWidth = 880, IsPaneToggleButtonVisible = false, IsTitleBarAutoPaddingEnabled = false, AlwaysShowHeader = false };
        _navigation.Resources["NavigationViewContentPresenterMargin"] = new Thickness(0);
        _search = new SettingsSearch(RevealSearchAsync, message => { if (!_closed) _status.Text = message; }, _lifetime.Token);
        _navigation.AutoSuggestBox = _search.Box;
        _titleBar.PaneToggleRequested += (_, _) => _navigation.IsPaneOpen = !_navigation.IsPaneOpen;
        var pageHeader = new Grid { ColumnSpacing = 16, Margin = new Thickness(24, 20, 24, 12) };
        pageHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pageHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titleGroup = new Grid { ColumnSpacing = 12, HorizontalAlignment = HorizontalAlignment.Left };
        titleGroup.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleGroup.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_restore, 1);
        titleGroup.Children.Add(_pageTitle); titleGroup.Children.Add(_restore);
        _restore.VerticalAlignment = VerticalAlignment.Center;
        ToolTipService.SetToolTip(_restore, "恢复当前功能的默认设置，保留翻译密钥");
        pageHeader.Children.Add(titleGroup); Grid.SetColumn(_pageActions, 1); pageHeader.Children.Add(_pageActions);
        pageHeader.SizeChanged += (_, _) => _pageTitle.MaxWidth = Math.Max(64, pageHeader.ActualWidth - 140);
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(pageHeader); Grid.SetRow(_scroll, 1); root.Children.Add(_scroll);
        var feedback = new StackPanel { Spacing = 4, Padding = new Thickness(24, 4, 24, 12) };
        AutomationProperties.SetLiveSetting(_status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        feedback.Children.Add(_status); feedback.Children.Add(_error); Grid.SetRow(feedback, 2); root.Children.Add(feedback);
        _error.ActionButton = _recover;
        _recover.Click += async (_, _) => await RecoverAsync();
        _navigation.Content = root; _navigation.PaneFooter = _reload;
        AddNavigationItem("常规", "general", Symbol.Setting);
        AddNavigationItem("功能与快捷键", "hotkeys", Symbol.Keyboard);
        AddNavigationItem("翻译设置", "translate", Symbol.Globe);
        AddNavigationItem("朗读设置", "tts", Symbol.Volume);
        AddNavigationItem("截图识别", "ocr", Symbol.Camera);
        AddNavigationItem("截图与录屏", "capture", Symbol.Video);
        AddNavigationItem("音频切换", "audio", Symbol.Switch);
        AddNavigationItem("主题、壁纸与背光", "theme", Symbol.Pictures);
        AddNavigationItem("电源与唤醒", "power", Symbol.Clock);
        AddNavigationItem("氛围灯", "rgb", Symbol.Highlight);
        AutomationProperties.SetName(_navigation, "设置分类导航");
        _navigation.PaneHeader = CreateBrandHeader();
        _navigation.PaneOpened += (_, _) => UpdateBrandHeader(); _navigation.PaneClosed += (_, _) => UpdateBrandHeader();
        _navigation.DisplayModeChanged += (_, _) => UpdateBrandHeader();
        var windowRoot = new Grid(); windowRoot.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        windowRoot.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        windowRoot.Children.Add(_titleBar); Grid.SetRow(_navigation, 1); windowRoot.Children.Add(_navigation);
        Content = windowRoot; ExtendsContentIntoTitleBar = true; SetTitleBar(_titleBar); AppWindow.IsShownInSwitchers = true;
        var findSettings = new KeyboardAccelerator { Key = Windows.System.VirtualKey.F, Modifiers = Windows.System.VirtualKeyModifiers.Control };
        findSettings.Invoked += (_, args) => { _navigation.IsPaneOpen = true; _search.Box.Focus(FocusState.Keyboard); args.Handled = true; };
        windowRoot.KeyboardAccelerators.Add(findSettings);
        double scale = Math.Max(96, Native.GetDpiForWindow(hwnd)) / 96.0;
        Native.RECT work = Native.TryGetWindowWorkArea(hwnd, out var area) ? area : Native.GetPrimaryWorkArea();
        int width = Math.Min((int)(1040 * scale), Math.Max(320, work.Width - 40));
        int height = Math.Min((int)(800 * scale), Math.Max(320, work.Height - 40));
        AppWindow.MoveAndResize(new RectInt32(work.Left + (work.Width - width) / 2, work.Top + (work.Height - height) / 2, width, height));
        _debounce = DispatcherQueue.CreateTimer(); _debounce.Interval = TimeSpan.FromMilliseconds(650); _debounce.IsRepeating = false;
        _debounce.Tick += async (_, _) =>
        {
            // Do not commit partial numbers, paths, endpoints or credentials while typing.
            if (FocusManager.GetFocusedElement(windowRoot.XamlRoot) is TextBox or PasswordBox) return;
            await FlushAsync();
        };
        windowRoot.LostFocus += (_, _) => { if (_pending.Count > 0) { _debounce.Stop(); _debounce.Start(); } };
        windowRoot.KeyDown += (sender, args) => { if (args.Key == Windows.System.VirtualKey.Enter && _pending.Count > 0) _ = FlushAsync(); };
        _reloadPoll = DispatcherQueue.CreateTimer(); _reloadPoll.Interval = TimeSpan.FromSeconds(1);
        _reloadPoll.Tick += async (_, _) => await RefreshReloadAsync();
        _reload.Click += async (_, _) => await ApplyReloadAsync();
        _restore.Click += async (_, _) => await RestoreDefaultsAsync();
        _navigation.SelectionChanged += (_, _) => _moduleLoad = SwitchModuleAsync();
        AppWindow.Closing += (sender, args) =>
        {
            if (_allowClose || _readOnlyProbe) return;
            args.Cancel = true;
            if (!_closing) _ = CloseAfterSaveAsync();
        };
        Closed += (_, _) => { _closed = true; _debounce.Stop(); _reloadPoll.Stop(); _lifetime.Cancel();
            _reloadCompletion?.TrySetCanceled(_lifetime.Token);
            ToolboxTray.ReleaseWindowIcon(_windowIcon); _windowIcon = IntPtr.Zero; HudLog.Line("settings-closed"); };
        _ = InitializeWindowIconAsync();
        SelectModule("translate");
    }

    void AddNavigationItem(string label, string module, Symbol symbol) => _navigation.MenuItems.Add(new NavigationViewItem { Content = label, Tag = module, Icon = new SymbolIcon(symbol) });
    void SelectModule(string module) => _navigation.SelectedItem = _navigation.MenuItems.Cast<NavigationViewItem>().Single(item => (string)item.Tag == module);
    async Task RevealSearchAsync(SettingsSearchItem item)
    {
        int generation = ++_searchNavigation;
        SelectModule(item.Page); await _moduleLoad;
        if (_closed || _module != item.Page || generation != _searchNavigation) return;
        if (!_pages.ContainsKey(item.Page)) { _status.Text = "此页未能载入，请检查配置后重新读取。"; return; }
        FrameworkElement? target = item.Kind switch
        {
            "field" => _moduleForms.GetValueOrDefault(item.Page)?.Reveal(item.Target),
            "preference" => _preferenceForms.GetValueOrDefault(item.Page)?.Reveal(item.Target),
            "control" => _controlForms.GetValueOrDefault(item.Page)?.Reveal(item.Target),
            "credential" => _credentials?.Reveal(item.Target),
            "module" => _pageActions.Children.OfType<ToggleSwitch>().FirstOrDefault(element => AutomationProperties.GetAutomationId(element) == item.Target),
            "section" => _searchSections.GetValueOrDefault(item.Page + ":" + item.Target),
            _ => null,
        };
        if (item.Kind == "page") _scroll.ChangeView(null, 0, null, true);
        else if (target == null) { _status.Text = "此设置暂时无法定位，可从当前分类继续查找。"; return; }
        if (target is Expander expander) expander.IsExpanded = true;
        if (target != null)
        {
            for (int i = 0; i < 20 && !target.IsLoaded && !_closed; i++) await Task.Delay(25);
            if (_closed || _module != item.Page || generation != _searchNavigation) return;
            if (!target.IsLoaded) { _status.Text = "设置控件尚未就绪，可稍后重试搜索。"; return; }
            if (target is Control control && control.IsEnabled) control.Focus(FocusState.Programmatic);
            if (item.Kind != "module")
            {
                // Expansion and editor focus can each request scrolling. Correct
                // after layout settles so the target stays clear of the footer.
                double previousExtent = -1; int stable = 0;
                for (int i = 0; i < 12; i++)
                {
                    var rectangle = new Windows.Foundation.Rect(0, 0, target.ActualWidth,
                        target is Expander || target.ActualHeight > _scroll.ViewportHeight * .7 ? Math.Min(48, target.ActualHeight) : target.ActualHeight);
                    target.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = .5, TargetRect = rectangle });
                    await Task.Delay(35);
                    if (_closed || _module != item.Page || generation != _searchNavigation) return;
                    var visible = target.TransformToVisual(_scroll).TransformBounds(rectangle);
                    bool inside = visible.Top >= 4 && visible.Bottom <= _scroll.ViewportHeight - 4;
                    stable = inside && Math.Abs(previousExtent - _scroll.ExtentHeight) < 1 ? stable + 1 : 0;
                    previousExtent = _scroll.ExtentHeight;
                    if (stable >= 2) break;
                }
            }
        }
        _status.Text = "已定位：" + item.Label;
    }
    UIElement CreateBrandHeader()
    {
        var logo = new Image { Width = 32, Height = 32 };
        AutomationProperties.SetName(logo, "lat3ncy 工具箱 Logo");
        logo.ImageOpened += (_, _) => _brandLogoLoaded = true;
        logo.ImageFailed += (_, _) => HudLog.Line("settings-brand-logo=failed");
        logo.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "toolbox-logo.png")));
        _brandName.Children.Add(new TextBlock { Text = "lat3ncy", FontSize = 18 });
        _brandName.Children.Add(new TextBlock { Text = "工具箱设置", FontSize = 12 });
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(8, 12, 8, 16) };
        panel.Children.Add(logo); panel.Children.Add(_brandName); return panel;
    }
    void UpdateBrandHeader() => _brandName.Visibility = _navigation.IsPaneOpen ? Visibility.Visible : Visibility.Collapsed;
    async Task InitializeWindowIconAsync()
    {
        try { IntPtr icon = await ToolboxTray.LoadWindowIconAsync(); if (_closed) { ToolboxTray.ReleaseWindowIcon(icon); return; }
            try { AppWindow.SetIcon(Microsoft.UI.Win32Interop.GetIconIdFromIcon(icon)); } catch { ToolboxTray.ReleaseWindowIcon(icon); throw; }
            _windowIcon = icon;
        } catch (Exception error) { HudLog.Line("settings-window-icon=failed kind=" + error.GetType().Name); }
    }
    internal void SyncTitleTheme() { if (!_closed) Native.SyncWindowTitleTheme(WinRT.Interop.WindowNative.GetWindowHandle(this)); }

    async Task EnsureControlsAsync()
    {
        if (_controlsRevision.Length > 0) return;
        JsonElement data = await PreferencesBridge.RunControlsAsync(null, _lifetime.Token);
        _controlsRevision = data.GetProperty("revision").GetString()!;
        foreach (var item in data.GetProperty("modules").EnumerateArray())
        {
            string id = item.GetProperty("id").GetString()!;
            _moduleValues[id] = _moduleOriginals[id] = data.GetProperty("values").GetProperty("module_" + id + "_enabled").GetBoolean();
            _moduleRevisions[id] = _controlsRevision;
        }
    }
    async Task SwitchModuleAsync()
    {
        if (_navigation.SelectedItem is not NavigationViewItem selected) return;
        string page = (string)selected.Tag; _module = page; _pageTitle.Text = selected.Content?.ToString();
        _scroll.Content = null; _pageActions.Children.Clear(); _restore.Visibility = Visibility.Collapsed;
        _status.Text = "正在读取设置…"; _error.IsOpen = false;
        try
        {
            await _loader.WaitAsync();
            try
            {
            await EnsureControlsAsync();
            if (!_pages.ContainsKey(page))
            {
                if (page is "general" or "hotkeys")
                {
                    var form = new ControlSettingsForm(await PreferencesBridge.RunControlsAsync(null, _lifetime.Token), page);
                    if (page == "general")
                    {
                        var diagnostic = new DiagnosticSettingsForm(_lifetime.Token).Root;
                        var maintenance = new MaintenanceSettingsForm(_lifetime.Token, RunMaintenanceReloadAsync,
                            module => _moduleValues.GetValueOrDefault(module) && !_reloading && !_startingReload, SelectModule).Root;
                        form.Root.Children.Add(diagnostic); form.Root.Children.Add(maintenance);
                        _searchSections["general:diagnostics"] = diagnostic; _searchSections["general:maintenance"] = maintenance;
                    }
                    form.Edited += () => Edited(page); _controlForms[page] = form; _pages[page] = form.Root;
                }
                else
                {
                    var panel = new StackPanel { Spacing = 0 };
                    if (page is "translate" or "tts")
                    {
                        var basics = new PreferenceSettingsForm(await PreferencesBridge.RunAsync(null, _lifetime.Token), page, AppWindow);
                        basics.Edited += () => Edited(page); _preferenceForms[page] = basics; panel.Children.Add(basics.Root);
                        if (page == "translate")
                        {
                            _credentials = new CredentialsSettingsForm(await PreferencesBridge.RunCredentialsAsync(null, _lifetime.Token));
                            _credentials.Edited += () => Edited(page); panel.Children.Add(_credentials.Root);
                        }
                    }
                    var advanced = new ModuleConfigurationForm(await PreferencesBridge.RunConfigurationAsync(page, null, _lifetime.Token), AppWindow,
                        page is "translate" or "tts" ? "高级设置" : null);
                    advanced.Edited += () => Edited(page); _moduleForms[page] = advanced; panel.Children.Add(advanced.Root); _pages[page] = panel;
                    if (page == "capture")
                    {
                        var activity = new CaptureActivitySettingsForm(_lifetime.Token).Root;
                        panel.Children.Add(activity); _searchSections["capture:capture_activity"] = activity.Children.OfType<Expander>().Single();
                    }
                }
            }
            }
            finally { _loader.Release(); }
            if (_closed || page != _module) return;
            _scroll.Content = _pages[page]; RebuildModuleSwitch(); UpdateDefault(); _status.Text = "修改后自动保存。";
            SettingsLoaded = true;
            if (_navigation.DisplayMode != NavigationViewDisplayMode.Expanded) _navigation.IsPaneOpen = false;
            await RefreshReloadAsync();
            if (!_readOnlyProbe) await FlushAsync();
        }
        catch { if (!_closed && page == _module) ShowError("无法读取此页，请检查本地配置和 Python 后重新读取。已有输入保留。", page); }
    }
    void RebuildModuleSwitch()
    {
        _pageActions.Children.Clear();
        if (!_moduleValues.TryGetValue(_module, out bool value)) return;
        string page = _module; var toggle = SettingsUi.Toggle(value);
        AutomationProperties.SetName(toggle, "启用" + _pageTitle.Text); AutomationProperties.SetAutomationId(toggle, "module_" + page + "_enabled");
        ToolTipService.SetToolTip(toggle, "启用或关闭此功能，自动保存");
        toggle.Toggled += (_, _) => { _moduleValues[page] = toggle.IsOn; Edited(page); };
        _pageActions.Children.Add(toggle);
    }
    void Edited(string page)
    {
        if (_suppress || _closed) return;
        _pending.Add(page); if (page == _module) UpdateDefault();
        if (_readOnlyProbe) return;
        _status.Text = "等待自动保存…"; _debounce.Stop(); _debounce.Start();
    }
    void UpdateDefault()
    {
        bool differs = (_moduleValues.TryGetValue(_module, out bool enabled) && !enabled)
            || _controlForms.GetValueOrDefault(_module)?.IsNonDefault == true
            || _preferenceForms.GetValueOrDefault(_module)?.IsNonDefault == true
            || _moduleForms.GetValueOrDefault(_module)?.IsNonDefault == true;
        _restore.Visibility = differs ? Visibility.Visible : Visibility.Collapsed;
    }
    async Task RestoreDefaultsAsync()
    {
        string page = _module; _suppress = true;
        try
        {
            _controlForms.GetValueOrDefault(page)?.RestoreDefaults();
            if (_preferenceForms.TryGetValue(page, out var preferences)) { preferences.RestoreDefaults(); _resetPreferences.Add(page); }
            _moduleForms.GetValueOrDefault(page)?.RestoreDefaults();
            if (_moduleValues.ContainsKey(page)) _moduleValues[page] = true;
            RebuildModuleSwitch(); UpdateDefault(); _defaultsPreviewed = true;
        }
        finally { _suppress = false; }
        Edited(page); if (!_readOnlyProbe) await FlushAsync();
    }
    internal Task PreviewDefaultsAsync() => RestoreDefaultsAsync();
    string PageLabel(string page) => _navigation.MenuItems.Cast<NavigationViewItem>().Single(item => (string)item.Tag == page).Content.ToString()!;
    void ShowError(string message, string? page = null)
    {
        _status.Text = _pending.Count > 0 ? "有更改尚未保存。" : "操作未完成。";
        _errorPage = page; _error.Message = page == null ? message : PageLabel(page) + "：" + message;
        _recover.Visibility = page == null ? Visibility.Collapsed : Visibility.Visible;
        _recover.Content = page == _module ? "丢弃此页输入并重读" : "查看" + (page == null ? "" : PageLabel(page));
        _error.IsOpen = true;
    }
    void PresentSaveErrors()
    {
        string? page = _saveErrors.ContainsKey(_module) ? _module : _saveErrors.Keys.FirstOrDefault();
        if (page != null) ShowError(_saveErrors[page], page);
    }
    async Task RecoverAsync()
    {
        string? page = _errorPage;
        if (page == null || _closed) return;
        _recover.IsEnabled = false;
        try
        {
            if (page != _module) { SelectModule(page); await _moduleLoad; }
            else await RereadAsync(page);
        }
        catch { if (!_closed) ShowError("重新读取失败，当前输入已保留。请检查配置和 Python 后重试。", page); }
        finally { _recover.IsEnabled = true; }
    }
    void RetargetControls(string oldRevision, string current)
    {
        foreach (var form in _controlForms.Values) form.RetargetOwnRevision(oldRevision, current);
        foreach (string page in _moduleRevisions.Keys.ToArray()) if (_moduleRevisions[page] == oldRevision) _moduleRevisions[page] = current;
        if (_controlsRevision == oldRevision) _controlsRevision = current;
    }
    void RetargetTranslation(string oldRevision, string current)
    { _moduleForms.GetValueOrDefault("translate")?.RetargetRevision(oldRevision, current); _credentials?.RetargetRevision(oldRevision, current); }
    static bool HasChanges(object request) => JsonSerializer.SerializeToElement(request).GetProperty("changes").EnumerateObject().Any();

    async Task<bool> FlushAsync()
    {
        if (_readOnlyProbe || _closed) return true;
        await _writer.WaitAsync();
        bool success = true;
        try
        {
            foreach (string page in _pending.ToArray())
            {
                _pending.Remove(page);
                try { await SavePageAsync(page); _saveErrors.Remove(page); }
                catch (Exception error)
                {
                    _pending.Add(page); success = false;
                    bool invalid = _moduleForms.GetValueOrDefault(page)?.ShowValidation(error.Message) == true;
                    string? conflict = _controlForms.GetValueOrDefault(page)?.ConflictMessage(error.Message);
                    _saveErrors[page] = conflict ?? (error.Message == "settings_changed_reload" ? "配置已被其他窗口修改，当前输入已保留。可重新读取此页后修改。"
                        : invalid ? "请修正标记的字段，修正后自动保存。" : "自动保存失败，当前输入已保留。请检查配置格式和目录写入权限。");
                    HudLog.Line("settings-autosave=failed page=" + page + " kind=" + error.GetType().Name);
                }
            }
            if (success) { _status.Text = "已自动保存。"; _error.IsOpen = false; }
            PresentSaveErrors();
            UpdateDefault(); await RefreshReloadAsync();
        }
        finally { _writer.Release(); }
        return success;
    }
    async Task SavePageAsync(string page)
    {
        if (_moduleValues.TryGetValue(page, out bool enabled) && enabled != _moduleOriginals[page])
        {
            string previous = _moduleRevisions[page];
            var data = await PreferencesBridge.RunControlsAsync(new { revision = previous, changes = new Dictionary<string, object> { ["module_" + page + "_enabled"] = enabled } }, _lifetime.Token);
            _moduleOriginals[page] = enabled; RetargetControls(previous, data.GetProperty("revision").GetString()!); _controlsChanged?.Invoke();
        }
        if (_controlForms.TryGetValue(page, out var controls) && controls.HasChanges)
        {
            string previous = controls.Revision; var data = await PreferencesBridge.RunControlsAsync(controls.ReadRequest(), _lifetime.Token);
            RetargetControls(previous, data.GetProperty("revision").GetString()!); controls.AcceptCommitted(data); _controlsChanged?.Invoke();
        }
        if (_preferenceForms.TryGetValue(page, out var prefs) && (prefs.HasChanges || _resetPreferences.Contains(page)))
        {
            bool reset = _resetPreferences.Contains(page);
            object request = prefs.ReadRequest(reset) ?? throw new InvalidOperationException("invalid_field");
            string previous = prefs.Revision; var data = await PreferencesBridge.RunAsync(request, _lifetime.Token);
            _suppress = true; try { prefs.AcceptCommitted(data); } finally { _suppress = false; }
            foreach (var form in _preferenceForms.Values) form.RetargetRevision(previous, prefs.Revision);
            if (reset) _resetPreferences.Remove(page);
        }
        if (_moduleForms.TryGetValue(page, out var config) && config.HasChanges)
        {
            object request = config.ReadRequest() ?? throw new InvalidOperationException("invalid_field");
            if (HasChanges(request))
            {
                string previous = config.Revision; var data = await PreferencesBridge.RunConfigurationAsync(page, request, _lifetime.Token);
                config.AcceptCommitted(data); if (page == "translate") RetargetTranslation(previous, config.Revision);
            }
            else config.AcceptUnchanged();
        }
        if (page == "translate" && _credentials != null)
            foreach (string provider in _credentials.DirtyProviders)
            {
                var request = JsonSerializer.SerializeToElement(_credentials.ReadRequest(provider)); string previous = _credentials.Revision;
                var data = await PreferencesBridge.RunCredentialsAsync(request, _lifetime.Token);
                _suppress = true; try { _credentials.AcceptCommitted(data, request); } finally { _suppress = false; }
                RetargetTranslation(previous, _credentials.Revision);
            }
    }
    async Task RereadAsync(string page)
    {
        await _writer.WaitAsync();
        try
        {
            // Read first: a failed read must not discard drafts. Rebase only the requested
            // page; other module switches retain their drafts and conflict revisions.
            var data = await PreferencesBridge.RunControlsAsync(null, _lifetime.Token);
            if (page is not ("general" or "hotkeys"))
                await PreferencesBridge.RunConfigurationAsync(page, null, _lifetime.Token);
            if (page is "translate" or "tts") await PreferencesBridge.RunAsync(null, _lifetime.Token);
            if (page == "translate") await PreferencesBridge.RunCredentialsAsync(null, _lifetime.Token);
            if (_moduleValues.ContainsKey(page))
            {
                _moduleValues[page] = _moduleOriginals[page] = data.GetProperty("values").GetProperty("module_" + page + "_enabled").GetBoolean();
                _moduleRevisions[page] = data.GetProperty("revision").GetString()!;
            }
            _pending.Remove(page); _saveErrors.Remove(page); _resetPreferences.Remove(page); _pages.Remove(page); _moduleForms.Remove(page);
            _preferenceForms.Remove(page); _controlForms.Remove(page); if (page == "translate") _credentials = null;
        }
        finally { _writer.Release(); }
        if (_module == page) await SwitchModuleAsync();
    }
    async Task RefreshReloadAsync()
    {
        if (_closed) return;
        try
        {
            var data = await PreferencesBridge.RunReloadAsync(null, _lifetime.Token);
            var pending = data.GetProperty("pending").EnumerateArray().ToArray();
            _reload.Visibility = pending.Length > 0 || _reloading ? Visibility.Visible : Visibility.Collapsed;
            ToolTipService.SetToolTip(_reload, "重新应用：" + string.Join("、", pending.Select(item => item.GetProperty("label").GetString())));
            if (_reloading)
            {
                var result = data.GetProperty("result");
                if (result.TryGetProperty("id", out var id) && id.GetString() == _reloadId && result.GetProperty("status").GetString() == "completed")
                {
                    _reloading = false; _reloadPoll.Stop(); _reload.IsEnabled = true; _reload.Content = "重载";
                    _reload.Visibility = pending.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
                    _reloadCompletion?.TrySetResult(result.Clone());
                    if (result.GetProperty("failed").GetString()?.Length > 0) ShowError("部分功能未能重载，已保留待重载状态。请确认功能已启用且任务属于当前仓库。");
                    else _status.Text = "重载完成。";
                }
                else if (DateTime.UtcNow - _reloadStarted > TimeSpan.FromSeconds(150))
                { _reloading = false; _reloadPoll.Stop(); _reload.IsEnabled = true; _reload.Content = "重载"; _reloadCompletion?.TrySetException(new InvalidOperationException("reload_timeout")); ShowError("重载未完成，请确认工具箱 AHK 主进程正在运行后重试。"); }
            }
        }
        catch { if (_reloading) _status.Text = "正在等待重载结果…"; }
    }
    async Task ApplyReloadAsync()
    {
        try { await StartReloadAsync(null); }
        catch (Exception error) { ShowError(MaintenanceSettingsForm.ErrorText(error.Message)); }
    }
    async Task<JsonElement> RunMaintenanceReloadAsync(string module)
    {
        if (module is not ("power" or "theme" or "rgb")) throw new InvalidOperationException("invalid_module");
        if (!await StartReloadAsync(new[] { module })) throw new InvalidOperationException("settings_unavailable");
        return await _reloadCompletion!.Task.WaitAsync(TimeSpan.FromSeconds(160), _lifetime.Token);
    }
    async Task<bool> StartReloadAsync(string[]? modules)
    {
        if (_readOnlyProbe) return false;
        if (_reloading || _startingReload) throw new InvalidOperationException("reload_busy");
        _startingReload = true;
        try
        {
            if (!await FlushAsync()) throw new InvalidOperationException("settings_not_saved");
            object request = modules == null ? new { action = "reload" } : new { action = "reload", modules };
            var result = await PreferencesBridge.RunReloadAsync(request, _lifetime.Token);
            _reloadId = result.GetProperty("id").GetString()!;
            if (_reloadId.Length == 0) return false;
            _reloadCompletion = new TaskCompletionSource<JsonElement>();
            _reloading = true; _reloadStarted = DateTime.UtcNow; _reload.IsEnabled = false; _reload.Visibility = Visibility.Visible;
            _reload.Content = "重载中…"; _reloadPoll.Start();
            return true;
        }
        finally { _startingReload = false; }
    }
    async Task CloseAfterSaveAsync()
    {
        _closing = true; _debounce.Stop();
        try
        {
            if (!await FlushAsync())
            {
                var dialog = new ContentDialog { XamlRoot = ((FrameworkElement)Content).XamlRoot, Title = "仍有设置未保存",
                    Content = "保存失败。保留窗口可继续修正，或放弃未保存的输入并关闭。", PrimaryButtonText = "继续编辑", SecondaryButtonText = "放弃并关闭" };
                if (await dialog.ShowAsync() != ContentDialogResult.Secondary) return;
            }
            _allowClose = true; Close();
        }
        finally { _closing = false; }
    }
    internal void CloseForShutdown() { _allowClose = true; Close(); }
    public new void Close()
    {
        if (_allowClose || _readOnlyProbe) base.Close();
        else if (!_closing) _ = CloseAfterSaveAsync();
    }
    internal void InvokeCloseButtonForProbe() { if (!_readOnlyProbe) throw new InvalidOperationException("probe_required"); Close(); }
    internal async Task VerifyAutosaveAsync()
    {
        if (PreferencesBridge.ProbeTools == null) throw new InvalidOperationException("isolated_probe_required");
        await _moduleLoad;
        _preferenceForms["translate"].SetProbeValue("target_language", "en");
        _moduleForms["translate"].SetProbeValue("timeout_s", 5);
        _credentials!.SetProbeValues();
        // Exercise the actual timer, not only the explicit flush path.
        for (int i = 0; i < 100 && (_pending.Count > 0 || _writer.CurrentCount == 0); i++) await Task.Delay(100);
        if (_pending.Count > 0 || _error.IsOpen) throw new InvalidOperationException("native_autosave_timer_failed");
        var prefs = await PreferencesBridge.RunAsync(null, _lifetime.Token);
        if (prefs.GetProperty("values").GetProperty("translate").GetProperty("target_language").GetString() != "en") throw new InvalidOperationException("native_autosave_readback");
        SelectModule("tts"); await _moduleLoad; _preferenceForms["tts"].SetProbeValue("rate", 5);
        var searchTarget = (await _search.CatalogAsync()).Single(item => item.Page == "translate" && item.Kind == "preference" && item.Target == "target_language");
        await RevealSearchAsync(searchTarget);
        if (_module != "translate") throw new InvalidOperationException("native_search_navigation_failed");
        _moduleValues["translate"] = false; Edited("translate");
        if (!await FlushAsync()) throw new InvalidOperationException("native_switch_save");
        if ((await PreferencesBridge.RunControlsAsync(null, _lifetime.Token)).GetProperty("values").GetProperty("module_translate_enabled").GetBoolean()) throw new InvalidOperationException("native_switch_reverted");
        await RestoreDefaultsAsync();
        prefs = await PreferencesBridge.RunAsync(null, _lifetime.Token);
        if (prefs.GetProperty("values").GetProperty("tts").GetProperty("rate").GetString() != "+5%") throw new InvalidOperationException("native_defaults_reset_other_page");
        if (!(await PreferencesBridge.RunCredentialsAsync(null, _lifetime.Token)).GetProperty("providers")[0].GetProperty("fields")[1].GetProperty("configured").GetBoolean()) throw new InvalidOperationException("native_defaults_erased_credentials");
        SelectModule("capture"); await _moduleLoad;
        _moduleForms["capture"].SetProbeValue("screenshot.copy_to_clipboard", false);
        _moduleForms["capture"].SetProbeValue("record.wait_timeout_s", 3600);
        if (!await FlushAsync()) throw new InvalidOperationException("native_capture_save");
        var capture = await PreferencesBridge.RunConfigurationAsync("capture", null, _lifetime.Token);
        if (capture.GetProperty("fields").EnumerateArray().Single(item => item.GetProperty("key").GetString() == "screenshot.copy_to_clipboard").GetProperty("value").GetBoolean()) throw new InvalidOperationException("native_capture_readback");
        await RestoreDefaultsAsync();
        if (_moduleForms["capture"].IsNonDefault) throw new InvalidOperationException("native_capture_defaults");
        SelectModule("theme"); await _moduleLoad;
        _moduleForms["theme"].SetProbeValue("schedule.latitude", "31.25");
        if (!await FlushAsync() || _reload.Visibility != Visibility.Visible) throw new InvalidOperationException("native_reload_button_missing");
        SelectModule("translate"); await _moduleLoad;
        await VerifySaveRecoveryAsync();
        _preferenceForms["translate"].SetProbeValue("target_language", "zh");
        var closed = new TaskCompletionSource(); Closed += (_, _) => closed.TrySetResult();
        Native.SendMessage(WinRT.Interop.WindowNative.GetWindowHandle(this), Native.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        await closed.Task.WaitAsync(TimeSpan.FromSeconds(15));
        prefs = await PreferencesBridge.RunAsync(null, CancellationToken.None);
        if (prefs.GetProperty("values").GetProperty("translate").GetProperty("target_language").GetString() != "zh") throw new InvalidOperationException("native_close_dropped_changes");
        HudLog.Line("settings-autosave-probe=passed timer+mixed-writes+pages+defaults+credential-retention+switch+reload-indicator+cross-page-recovery+close-flush scope=isolated");
    }
    async Task VerifySaveRecoveryAsync()
    {
        // Two genuine CAS failures on an isolated controls file, viewed from an unrelated
        // page. Recovery must navigate first and discard only its explicitly named page.
        SelectModule("power"); await _moduleLoad;
        SelectModule("audio"); await _moduleLoad;
        _moduleValues["power"] = false; Edited("power");
        _moduleValues["audio"] = false; Edited("audio"); _debounce.Stop();
        var data = await PreferencesBridge.RunControlsAsync(null, _lifetime.Token);
        await PreferencesBridge.RunControlsAsync(new { revision = data.GetProperty("revision").GetString(), changes = new { tray_visible = false } }, _lifetime.Token);
        SelectModule("general"); await _moduleLoad;
        if (_saveErrors.Count != 2 || _errorPage == null || _errorPage == "general" || !_error.IsOpen)
            throw new InvalidOperationException("native_recovery_wrong_page");
        string first = _errorPage, other = first == "power" ? "audio" : "power";
        await RecoverAsync();
        if (_module != first || _moduleValues[first] || _moduleValues[other] || _saveErrors.Count != 2)
            throw new InvalidOperationException("native_recovery_navigation_discarded");
        string configPath = Path.Combine(PreferencesBridge.ProbeTools!, first == "power" ? "power-policy" : "audio-switcher", "config.toml");
        byte[] original = File.ReadAllBytes(configPath);
        try
        {
            File.WriteAllText(configPath, "[invalid fixture");
            await RecoverAsync();
            if (_moduleValues[first] || _moduleValues[other] || _saveErrors.Count != 2 || !_pending.Contains(first))
                throw new InvalidOperationException("native_failed_reread_discarded_draft");
        }
        finally { File.WriteAllBytes(configPath, original); }
        await RecoverAsync();
        if (!_moduleValues[first] || _moduleValues[other] || !_pending.Contains(other) || _saveErrors.Count != 1 || _errorPage != other)
            throw new InvalidOperationException("native_recovery_lost_other_draft");
        await RecoverAsync(); await RecoverAsync();
        if (_saveErrors.Count > 0 || _error.IsOpen || _pending.Count > 0 || !_moduleValues[other])
            throw new InvalidOperationException("native_recovery_did_not_clear");
        _moduleValues[other] = false; Edited(other);
        if (!await FlushAsync()) throw new InvalidOperationException("native_recovery_revision_stale");
        _moduleValues[other] = true; Edited(other);
        if (!await FlushAsync()) throw new InvalidOperationException("native_recovery_revision_retarget");
        SelectModule("translate"); await _moduleLoad;
    }
    internal async Task VerifyModulePagesAsync()
    {
        foreach (string page in new[] { "translate", "tts", "ocr", "capture", "audio", "theme", "power", "rgb", "general", "hotkeys" })
        {
            SelectModule(page); await _moduleLoad;
            if (!_pages.ContainsKey(page)) throw new InvalidOperationException("module_load_failed");
            if (_moduleForms.TryGetValue(page, out var form)) form.VerifyEditorRoundTrips();
            _preferenceForms.GetValueOrDefault(page)?.VerifyEditorRoundTrips();
        }
        SelectModule("translate"); await _moduleLoad;
        await VerifySearchAsync();
        HudLog.Line("settings-module-pages=passed count=10 merged=translate+tts credentials=metadata-only");
    }
    async Task VerifySearchAsync()
    {
        if (!_readOnlyProbe) throw new InvalidOperationException("probe_required");
        var catalog = await _search.CatalogAsync();
        foreach (var (page, kind, target) in new[] {
            ("tts","field","cache.max_files"), ("tts","preference","rate"), ("hotkeys","control","binding_SpeakSelectedText"),
            ("translate","credential","tencent"), ("theme","module","module_theme_enabled"),
            ("general","section","maintenance"), ("capture","section","capture_activity"), ("general","control","tray_visible") })
        {
            var item = catalog.Single(entry => entry.Page == page && entry.Kind == kind && entry.Target == target);
            await RevealSearchAsync(item);
            if (_module != page || _status.Text != "已定位：" + item.Label) throw new InvalidOperationException("settings_search_target_failed");
        }
        if (SettingsSearch.Match(catalog,"朗读快捷键").FirstOrDefault()?.Target != "binding_SpeakSelectedText") throw new InvalidOperationException("settings_search_ranking_failed");
        SelectModule("translate"); await _moduleLoad;
        HudLog.Line("settings-search=passed metadata+8-targets+ranking scope=read-only");
    }
    internal async Task VerifyNavigationLayoutAsync()
    {
        if (!_readOnlyProbe) throw new InvalidOperationException("probe_required");
        var original = AppWindow.Size; double scale = Math.Max(96, Native.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this))) / 96.0;
        try
        {
            foreach (var (width, mode) in new[] { (1040, NavigationViewDisplayMode.Expanded), (720, NavigationViewDisplayMode.Compact), (360, NavigationViewDisplayMode.Minimal) })
            {
                AppWindow.Resize(new SizeInt32((int)(width * scale), original.Height)); await Task.Delay(120);
                if (_navigation.DisplayMode != mode) throw new InvalidOperationException("navigation_layout_failed");
                double x = _pageTitle.TransformToVisual(_navigation).TransformPoint(new Windows.Foundation.Point()).X;
                double contentX = _scroll.TransformToVisual(_navigation).TransformPoint(new Windows.Foundation.Point()).X + 24;
                if (Math.Abs(x - contentX) > 1 || _titleBar.ActualHeight < 32) throw new InvalidOperationException("settings_header_alignment_failed");
                if (_pageActions.Children.FirstOrDefault() is ToggleSwitch toggle && (toggle.ActualWidth > 44 || Math.Abs(SettingsToggleLayout.TrackTrailingSpace(toggle)) > 1)) throw new InvalidOperationException("settings_switch_trailing_space");
            }
            HudLog.Line("settings-navigation=passed expanded+compact+minimal switches=right");
        }
        finally { AppWindow.Resize(original); }
    }
}
