using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Windowing;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>One text service per page, sharing the typed settings editors.</summary>
internal sealed class PreferenceSettingsForm
{
    readonly string _section;
    readonly ModuleConfigurationForm _form;
    public Microsoft.UI.Xaml.Controls.StackPanel Root => _form.Root;
    public bool HasChanges => _form.HasChanges;
    public bool IsNonDefault => _form.IsNonDefault;
    public string Revision => _form.Revision;
    public string BaseRevision { get; private set; }
    public event Action? Edited { add => _form.Edited += value; remove => _form.Edited -= value; }

    public PreferenceSettingsForm(JsonElement data, string section, AppWindow owner)
    {
        _section = section; BaseRevision = data.GetProperty("base_revision").GetString()!;
        _form = new ModuleConfigurationForm(Project(data, section), owner, "基础设置");
    }
    static JsonElement Project(JsonElement data, string section)
    {
        var values = data.GetProperty("values").GetProperty(section);
        var defaults = data.GetProperty("defaults").GetProperty(section);
        var fields = new List<object>();
        void Add(string key, string label, string type, object? choices = null, double? min = null, double? max = null)
        {
            object Read(JsonElement source) => key is "rate" or "pitch" or "volume"
                ? int.Parse(source.GetProperty(key).GetString()!.Replace("Hz", "").Replace("%", ""), CultureInfo.InvariantCulture)
                : source.GetProperty(key);
            fields.Add(new { key, label, type, value = Read(values), @default = Read(defaults), choices,
                minimum = min, maximum = max, help = "", @readonly = false, source = "preferences" });
        }
        if (section == "translate")
        {
            Add("engine", "首选翻译引擎", "string", new[] { "tencent", "google_gtx", "aliyun", "mymemory" });
            Add("source_language", "原文语言", "string", new[] { "auto", "zh", "en" });
            Add("target_language", "目标语言", "string", new[] { "auto", "zh", "en" });
            Add("fallback_without_credentials", "未配置密钥时使用 Google 保底", "bool");
            Add("fallback_on_auth_error", "鉴权失败时静默使用 Google 保底", "bool");
            Add("long_text_enabled", "长文分段翻译", "bool");
        }
        else
        {
            Add("engine", "朗读方式", "string", new[] { "auto", "winrt", "edge" });
            Add("zh_voice", "中文音色", "string"); Add("en_voice", "英文音色", "string");
            Add("rate", "语速（%）", "int", min: -90, max: 100);
            Add("pitch", "音调（Hz）", "int", min: -100, max: 100);
            Add("volume", "音量调整（%）", "int", min: -100, max: 100);
        }
        return JsonSerializer.SerializeToElement(new { revision = data.GetProperty("revision").GetString(), module = "preferences_" + section,
            effect = "", config = "", fields });
    }
    public object? ReadRequest(bool reset = false)
    {
        object? draft = _form.ReadRequest(); if (draft == null) return null;
        JsonElement changes = JsonSerializer.SerializeToElement(draft).GetProperty("changes");
        var values = new Dictionary<string, object>();
        foreach (var field in changes.EnumerateObject())
        {
            if (field.Name is "rate" or "pitch" or "volume")
                values[field.Name] = field.Value.GetDouble().ToString("+0;-0;+0", CultureInfo.InvariantCulture) + (field.Name == "pitch" ? "Hz" : "%");
            else values[field.Name] = field.Value.Clone();
        }
        return new { revision = Revision, base_revision = BaseRevision, reset_section = reset ? _section : null,
            changes = new Dictionary<string, object> { [_section] = reset ? new Dictionary<string, object>() : values } };
    }
    public void RestoreDefaults() => _form.RestoreDefaults();
    public void AcceptCommitted(JsonElement data) { BaseRevision = data.GetProperty("base_revision").GetString()!; _form.AcceptCommitted(Project(data, _section)); }
    public void RetargetRevision(string previous, string current) => _form.RetargetRevision(previous, current);
    internal void SetProbeValue(string key, object value) => _form.SetProbeValue(key, value);
    internal void VerifyEditorRoundTrips() => _form.VerifyEditorRoundTrips();
}
