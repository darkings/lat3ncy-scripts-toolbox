using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Input;

namespace Lat3ncyToolbox.ImeHudWinUi;

[Microsoft.UI.Xaml.Data.Bindable]
internal sealed record SettingsSearchItem(string Id, string Page, string PageLabel, string Kind, string Target, string Label, string Keywords)
{
    public override string ToString() => PageLabel.Length == 0 ? Label : Label + " · " + PageLabel;
}

internal sealed class SettingsSearch
{
    public AutoSuggestBox Box { get; } = new() { PlaceholderText = "搜索设置", QueryIcon = new SymbolIcon(Symbol.Find), MaxSuggestionListHeight = 360, TextMemberPath = nameof(SettingsSearchItem.Label) };
    readonly Func<SettingsSearchItem, Task> _navigate;
    readonly Action<string> _message;
    readonly CancellationToken _lifetime;
    Task<IReadOnlyList<SettingsSearchItem>>? _catalog;
    int _generation;
    public SettingsSearch(Func<SettingsSearchItem, Task> navigate, Action<string> message, CancellationToken lifetime)
    {
        _navigate = navigate; _message = message; _lifetime = lifetime;
        Box.ItemTemplate = (DataTemplate)XamlReader.Load("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
              <StackPanel Spacing="2" Margin="0,4" MaxWidth="180">
                <TextBlock Text="{Binding Label}" TextWrapping="Wrap"/>
                <TextBlock Text="{Binding PageLabel}" TextWrapping="Wrap" FontSize="12" Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>
              </StackPanel>
            </DataTemplate>
            """);
        AutomationProperties.SetName(Box, "搜索工具箱设置");
        AutomationProperties.SetHelpText(Box, "输入设置名称，使用上下方向键选择，按 Enter 打开；Escape 清空。Ctrl+F 聚焦搜索。");
        Box.TextChanged += async (_, args) => { if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) await SuggestAsync(); };
        Box.QuerySubmitted += async (_, args) =>
        {
            try
            {
                var item = args.ChosenSuggestion as SettingsSearchItem ?? Match(await CatalogAsync(), args.QueryText).FirstOrDefault();
                if (_lifetime.IsCancellationRequested) return;
                if (item == null || item.Id.Length == 0) { _message("未找到设置，可尝试“音量”“密钥”或“快捷键”。"); return; }
                Box.IsSuggestionListOpen = false; await _navigate(item);
            }
            catch (OperationCanceledException) { }
            catch { if (!_lifetime.IsCancellationRequested) _message("暂时无法搜索，可继续使用左侧分类。"); }
        };
        Box.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, args) => { if (args.Key == Windows.System.VirtualKey.Escape) { _generation++; Box.Text = ""; Box.IsSuggestionListOpen = false; args.Handled = true; } }), true);
    }
    internal Task<IReadOnlyList<SettingsSearchItem>> CatalogAsync()
    {
        if (_catalog == null || _catalog.IsFaulted || _catalog.IsCanceled) _catalog = LoadAsync();
        return _catalog;
    }
    async Task<IReadOnlyList<SettingsSearchItem>> LoadAsync()
    {
        try { return Parse(await PreferencesBridge.RunSearchCatalogAsync(_lifetime)); }
        catch { _catalog = null; throw; }
    }
    async Task SuggestAsync()
    {
        int generation = ++_generation; string query = Box.Text;
        if (string.IsNullOrWhiteSpace(query)) { Box.ItemsSource = null; Box.IsSuggestionListOpen = false; return; }
        try
        {
            var matches = Match(await CatalogAsync(), query);
            if (_lifetime.IsCancellationRequested || generation != _generation || Box.Text != query) return;
            Box.ItemsSource = matches.Count > 0 ? matches : new[] { new SettingsSearchItem("", "", "可试“音量”或“快捷键”", "", "", "未找到相关设置", "") };
            Box.IsSuggestionListOpen = true;
        }
        catch (OperationCanceledException) { }
        catch { if (!_lifetime.IsCancellationRequested && generation == _generation) _message("搜索暂不可用，可继续使用左侧分类。"); }
    }
    internal static IReadOnlyList<SettingsSearchItem> Parse(JsonElement data)
    {
        var pages = new HashSet<string> { "general","hotkeys","translate","tts","ocr","capture","audio","theme","power","rgb" };
        var kinds = new HashSet<string> { "page","module","field","preference","control","credential","section" };
        var result = new List<SettingsSearchItem>();
        foreach (var item in data.GetProperty("items").EnumerateArray().Take(512))
        {
            string Read(string key) => item.GetProperty(key).GetString() ?? "";
            string page = Read("page"), kind = Read("kind");
            if (!pages.Contains(page) || !kinds.Contains(kind)) continue;
            var entry = new SettingsSearchItem(Read("id"),page,Read("page_label"),kind,Read("target"),Read("label"),Read("keywords"));
            if (entry.Id.Length <= 160 && entry.Target.Length <= 100 && entry.Label.Length <= 200 && entry.Keywords.Length <= 2048) result.Add(entry);
        }
        return result;
    }
    internal static IReadOnlyList<SettingsSearchItem> Match(IReadOnlyList<SettingsSearchItem> catalog, string query)
    {
        if (string.IsNullOrWhiteSpace(query) || query.Length > 128) return Array.Empty<SettingsSearchItem>();
        string[] terms = query.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return catalog.Where(item => terms.All(term => (item.Label + " " + item.PageLabel + " " + item.Page + " " + item.Keywords).Contains(term,StringComparison.OrdinalIgnoreCase)))
            .OrderBy(item => string.Equals(item.Label,query.Trim(),StringComparison.OrdinalIgnoreCase) ? 0 : item.Label.StartsWith(query.Trim(),StringComparison.OrdinalIgnoreCase) ? 1 : 2)
            .ThenBy(item => item.Kind == "page" ? 0 : 1).ThenBy(item => item.Label,StringComparer.Ordinal).Take(12).ToArray();
    }
    internal static int SelfTest()
    {
        var entries = new[] { new SettingsSearchItem("tts:volume","tts","朗读设置","preference","volume","音量调整","volume TTS"), new SettingsSearchItem("theme:wallpaper","theme","主题","field","wallpaper.directory","壁纸目录","wallpaper") };
        if (Match(entries,"TTS 音量").SingleOrDefault()?.Target != "volume" || Match(entries,"theme 壁纸").SingleOrDefault()?.Target != "wallpaper.directory" || Match(entries,"不存在").Count != 0 || Match(entries,"").Count != 0 || Match(entries,new string('a',129)).Count != 0) return 1;
        return 0;
    }
}
