using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Write-only inputs: persisted credentials never enter this process.</summary>
internal sealed class CredentialsSettingsForm
{
    public StackPanel Root { get; } = new() { Spacing = 8, Padding = new Thickness(24, 0, 24, 8) };
    readonly Dictionary<string, Dictionary<string, (PasswordBox input, TextBlock state)>> _providers = new();
    public string Revision { get; private set; }
    public bool HasChanges => _providers.Values.Any(fields => fields.Values.Any(item => item.input.Password.Length > 0));
    public event Action? Edited;

    public CredentialsSettingsForm(JsonElement data)
    {
        Revision = data.GetProperty("revision").GetString()!;
        Root.Children.Add(SettingsUi.Hint("密钥仅保存在本机翻译配置中，不回显已有值。首次请填写 ID 和 Secret，离开文本框自动保存；留空保留原值。恢复默认保留密钥。Google 保底接口不需要密钥。"));
        foreach (JsonElement provider in data.GetProperty("providers").EnumerateArray())
        {
            string id = provider.GetProperty("id").GetString()!;
            string label = provider.GetProperty("label").GetString()!;
            var panel = new StackPanel { Spacing = 8 };
            var fields = new Dictionary<string, (PasswordBox input, TextBlock state)>(); _providers[id] = fields;
            foreach (JsonElement field in provider.GetProperty("fields").EnumerateArray())
            {
                string key = field.GetProperty("id").GetString()!;
                var input = new PasswordBox { Header = field.GetProperty("label").GetString(), MaxLength = 2048,
                    PlaceholderText = "输入新值以替换；留空保持原值", HorizontalAlignment = HorizontalAlignment.Stretch,
                    PasswordRevealMode = PasswordRevealMode.Hidden };
                AutomationProperties.SetName(input, label + " " + field.GetProperty("label").GetString());
                AutomationProperties.SetAutomationId(input, "credential_" + id + "_" + key);
                input.PasswordChanged += (_, _) => Edited?.Invoke();
                var state = SettingsUi.Hint(Describe(field));
                panel.Children.Add(input); panel.Children.Add(state); fields[key] = (input, state);
            }
            Root.Children.Add(new Expander { Header = label + "密钥", Content = panel,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
        }
    }
    static string Describe(JsonElement field) => field.GetProperty("source").GetString() switch
    { "environment" => "已配置 · 环境变量", "config" => "已配置 · 本机配置", _ => "尚未配置" };

    public IEnumerable<string> DirtyProviders => _providers.Where(item => item.Value.Values.Any(entry => entry.input.Password.Length > 0)).Select(item => item.Key).ToArray();
    public object ReadRequest(string provider) => new { provider, revision = Revision,
        changes = _providers[provider].Where(item => item.Value.input.Password.Length > 0).ToDictionary(item => item.Key, item => item.Value.input.Password) };
    public void AcceptCommitted(JsonElement data, JsonElement submitted)
    {
        Revision = data.GetProperty("revision").GetString()!;
        string id = submitted.GetProperty("provider").GetString()!;
        foreach (var change in submitted.GetProperty("changes").EnumerateObject())
            if (_providers[id][change.Name].input.Password == change.Value.GetString()) _providers[id][change.Name].input.Password = "";
        foreach (var provider in data.GetProperty("providers").EnumerateArray())
            foreach (var field in provider.GetProperty("fields").EnumerateArray())
                _providers[provider.GetProperty("id").GetString()!][field.GetProperty("id").GetString()!].state.Text = Describe(field);
    }
    public void RetargetRevision(string previous, string current) { if (Revision == previous) Revision = current; }
    internal void SetProbeValues() { _providers["tencent"]["secret_id"].input.Password = "ISOLATED_NATIVE_ID"; _providers["tencent"]["secret_key"].input.Password = "ISOLATED_NATIVE_SECRET"; }
}
