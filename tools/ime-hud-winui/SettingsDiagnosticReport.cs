using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Lat3ncyToolbox.ImeHudWinUi;

internal sealed record SettingsDiagnosticRow(string Id, string Label, string State, string Guidance, int Mismatches, bool Passed);

/// <summary>Fixed presentation vocabulary; arbitrary helper fields never reach the clipboard.</summary>
internal sealed class SettingsDiagnosticReport
{
    public required IReadOnlyList<SettingsDiagnosticRow> Rows { get; init; }
    public required string CheckedAt { get; init; }
    public required string Summary { get; init; }
    public bool NeedsAttention => Rows.Any(row => !row.Passed);
    static readonly (string Id, string Label)[] Modules = { ("translate", "翻译环境"), ("tts", "朗读环境"), ("ocr", "截图识别环境") };
    static string Read(JsonElement value, string key) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString()! : "";
    static string Version(JsonElement value, string key, int length)
    { string text = Read(value, key); return text.Length == length && text.All(Uri.IsHexDigit) ? text : "无法确认"; }
    public static SettingsDiagnosticReport From(JsonElement data)
    {
        string checkedAt = "无法确认";
        if (data.ValueKind == JsonValueKind.Object && data.TryGetProperty("collected_utc", out var time) && time.ValueKind == JsonValueKind.String && time.TryGetDateTimeOffset(out var instant))
            checkedAt = instant.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture);
        JsonElement[] items = data.ValueKind == JsonValueKind.Object && data.TryGetProperty("diagnostics", out var array) && array.ValueKind == JsonValueKind.Array
            ? array.EnumerateArray().Take(16).ToArray() : Array.Empty<JsonElement>();
        var rows = new List<SettingsDiagnosticRow>();
        foreach (var (id, label) in Modules)
        {
            JsonElement item = items.FirstOrDefault(value => Read(value, "id") == id);
            string config = Read(item, "config_state"), runtime = Read(item, "runtime_state"), reason = Read(item, "runtime_reason");
            int count = item.ValueKind == JsonValueKind.Object && item.TryGetProperty("dependency_mismatches", out var number) && number.ValueKind == JsonValueKind.Number && number.TryGetInt32(out int found) ? Math.Clamp(found, 0, 100) : 0;
            bool passed = (config is "ok" or "default") && (runtime is "ok" or "not-applicable") && reason == "none" && count == 0;
            var (state, guidance) = config == "invalid" ? ("配置格式需检查", "检查最近修改的配置。若对应设置页无法载入，请按模块说明修复配置文件，再重新检查。") : config is not ("ok" or "default") ?
                ("无法读取配置状态", "稍后重新检查；现有设置不会因此自动恢复或改写。") : count > 0 || reason == "dependencies" ?
                ("依赖版本需检查", "先在对应设置页确认引擎与模型，再按该模块说明修复环境；此检查不会安装依赖。") : reason switch
                {
                    "temp_unwritable" => ("当前检查进程无法写临时目录", "这只反映检查进程的权限，不能据此判定翻译或朗读故障。可复制检查摘要排查，再从普通运行环境复查。"),
                    "limited_integrity" => ("当前检查进程权限受限", "已验证正常的功能可继续使用。可复制摘要排查；完整环境结果需从普通运行环境复查。"),
                    _ => passed ? ("检查通过", "本机配置与依赖检查通过；云端鉴权、模型加载与实际硬件效果仍需单独验证。") :
                        ("无法完整检查", "稍后重新检查，并确认对应模块的运行环境可用。可复制摘要保留本次结果。"),
                };
            rows.Add(new(id, label, state, guidance, count, passed));
        }
        var summary = new StringBuilder("工具箱离线检查\n检查时间：").AppendLine(checkedAt)
            .Append("仓库版本：").AppendLine(Version(data, "commit", 40)).Append("界面构建：").AppendLine(Version(data, "source_stamp", 64));
        foreach (var row in rows)
        {
            summary.AppendLine().Append(row.Label).Append('：').AppendLine(row.State);
            if (row.Mismatches > 0) summary.Append("依赖不匹配数量：").AppendLine(row.Mismatches.ToString(CultureInfo.InvariantCulture));
            summary.AppendLine(row.Guidance);
        }
        summary.AppendLine().Append("仅含固定检查状态、时间和版本；不含路径、正文、密钥或原始日志。未验证云端服务与硬件效果。");
        return new() { Rows = rows, CheckedAt = checkedAt, Summary = summary.ToString() };
    }
    internal static int SelfTest()
    {
        using var source = JsonDocument.Parse("""
            {"collected_utc":"PRIVATE_SENTINEL","commit":"PRIVATE_SENTINEL","logs":"PRIVATE_SENTINEL","diagnostics":[
            {"id":"translate","label":"PRIVATE_SENTINEL","config_state":"ok","runtime_state":"attention","runtime_reason":"temp_unwritable","path":"PRIVATE_SENTINEL"},
            {"id":"tts","config_state":"ok","runtime_state":"ok","runtime_reason":"none"},
            {"id":"ocr","config_state":"invalid","runtime_state":"PRIVATE_SENTINEL","runtime_reason":"PRIVATE_SENTINEL"}]}
            """);
        var report = From(source.RootElement);
        if (report.Summary.Contains("PRIVATE_SENTINEL") || report.Rows.Count != 3 || !report.NeedsAttention || !report.Rows[1].Passed || report.Rows[0].Passed) return 1;
        if (report.CheckedAt != "无法确认" || !report.Rows[0].State.Contains("检查进程") || !report.Rows[2].State.Contains("配置")) return 2;
        using var malformed = JsonDocument.Parse("""{"diagnostics":[{"id":"tts","dependency_mismatches":"PRIVATE_SENTINEL"},null,42]}""");
        if (From(malformed.RootElement).Summary.Contains("PRIVATE_SENTINEL") || !From(default).NeedsAttention) return 3;
        return 0;
    }
}
