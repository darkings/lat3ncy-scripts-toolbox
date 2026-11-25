using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Fixed local helper, JSON stdio, no shell, keys, clipboard or network.</summary>
internal static class PreferencesBridge
{
    // Set only by the explicit isolated native test entry point.
    internal static string? ProbeTools;
    // Isolated tests can hold a successful write response to exercise later edits
    // deterministically. No requests, values or secrets are passed to the callback.
    internal static Func<Task>? ProbeAfterWrite;
    public static Task<JsonElement> RunAsync(object? request, CancellationToken cancellation, bool defaults = false)
    {
        if (defaults && request != null) throw new ArgumentException("settings_unavailable");
        return RunHelperAsync("toolbox_preferences.py", request, cancellation,
            defaults ? new[] { "--defaults" } : Array.Empty<string>(), 16384);
    }

    public static Task<JsonElement> RunConfigurationAsync(string module, object? request, CancellationToken cancellation)
    {
        if (module is not ("translate" or "tts" or "ocr" or "audio" or "theme" or "power" or "rgb" or "capture" or "raycast"))
            throw new ArgumentException("settings_unavailable");
        return RunHelperAsync("toolbox_configuration.py", request, cancellation, new[] { "--module", module }, 262144);
    }

    public static Task<JsonElement> RunControlsAsync(object? request, CancellationToken cancellation) =>
        RunHelperAsync("toolbox_controls.py", request, cancellation, Array.Empty<string>(), 65536);

    public static Task<JsonElement> RunCredentialsAsync(object? request, CancellationToken cancellation) =>
        RunHelperAsync("toolbox_credentials.py", request, cancellation, Array.Empty<string>(), 16384);

    public static Task<JsonElement> RunReloadAsync(object? request, CancellationToken cancellation) =>
        RunHelperAsync("toolbox_reload.py", request, cancellation, Array.Empty<string>(), 16384);

    public static Task<JsonElement> RunStatusAsync(CancellationToken cancellation) =>
        RunHelperAsync("toolbox_status.py", null, cancellation, new[] { "--owner-pid", Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture) }, 16384, seconds: 20);

    public static Task<JsonElement> RunFullStatusAsync(CancellationToken cancellation) =>
        RunHelperAsync("toolbox_status.py", null, cancellation, new[] { "--owner-pid", Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture), "--full" }, 16384, seconds: 75);

    public static Task<JsonElement> RunCaptureActivityAsync(CancellationToken cancellation) =>
        RunHelperAsync("toolbox_capture_activity.py", null, cancellation, Array.Empty<string>(), 16384);

    public static Task<JsonElement> RunCaptureRecentActionAsync(string mode, string action, CancellationToken cancellation)
    {
        if (mode is not ("Screenshot" or "Record") || action is not ("open" or "reveal" or "copy"))
            throw new ArgumentException("settings_unavailable");
        return RunHelperAsync("toolbox_capture_activity.py", new { mode, action }, cancellation, Array.Empty<string>(), 16384);
    }

    public static Task<JsonElement> RunMaintenanceCenterAsync(CancellationToken cancellation) =>
        RunHelperAsync("maintenance_center.py", null, cancellation, Array.Empty<string>(), 16384);

    public static Task<JsonElement> RequestMaintenanceCancelAsync(CancellationToken cancellation) =>
        RunHelperAsync("maintenance_center.py", new { cancel = true }, cancellation, Array.Empty<string>(), 16384);

    public static Task<JsonElement> RunSearchCatalogAsync(CancellationToken cancellation) =>
        RunHelperAsync("toolbox_settings_search.py", null, cancellation, Array.Empty<string>(), 131072);

    static async Task<JsonElement> RunHelperAsync(string filename, object? request, CancellationToken cancellation,
                                                 string[] arguments, int limit, string? probeTools = null, int seconds = 10)
    {
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        string? helper = null;
        for (int i = 0; i < 7 && directory != null; i++, directory = directory.Parent)
        {
            string candidate = Path.Combine(directory.FullName, "tools", filename);
            if (File.Exists(candidate) && Directory.Exists(Path.Combine(directory.FullName, "ahk")))
            {
                helper = candidate;
                break;
            }
        }
        if (probeTools != null || ProbeTools != null) helper = Path.Combine(probeTools ?? ProbeTools!, filename);
        if (helper == null)
            throw new InvalidOperationException("settings_unavailable");

        var start = new ProcessStartInfo("python.exe")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(helper)!,
        };
        start.ArgumentList.Add("-I");
        start.ArgumentList.Add("-S");
        start.ArgumentList.Add(helper);
        if (request != null)
            start.ArgumentList.Add("--apply");
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(seconds));
        using Process process = Process.Start(start) ?? throw new InvalidOperationException("settings_unavailable");
        using var killOnCancel = timeout.Token.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
        });
        try
        {
            Task<string> output = process.StandardOutput.ReadToEndAsync(timeout.Token);
            Task<string> error = process.StandardError.ReadToEndAsync(timeout.Token);
            if (request != null)
                await process.StandardInput.WriteAsync(JsonSerializer.Serialize(request).AsMemory(), timeout.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token);
            string json = await output;
            await error; // drain, never display private exception/provider details
            if (json.Length > limit)
                throw new InvalidOperationException("settings_unavailable");
            using JsonDocument doc = JsonDocument.Parse(json);
            JsonElement result = doc.RootElement;
            if (process.ExitCode != 0 || result.GetProperty("status").GetString() != "ok")
            {
                string? code = result.TryGetProperty("code", out var value) ? value.GetString() : null;
                bool fixedValidation = code != null && (code.StartsWith("invalid_", StringComparison.Ordinal)
                    || code.StartsWith("hotkey_conflict_", StringComparison.Ordinal))
                    && code.Length <= 100 && code.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '.');
                throw new InvalidOperationException(code is "settings_changed_reload" or "protected_config_manual" or "reload_busy" or "reload_capture_busy" or "reload_capture_unavailable" or "reload_disabled" || fixedValidation ? code : "settings_unavailable");
            }
            if (request != null && ProbeTools != null && ProbeAfterWrite is { } afterWrite)
                await afterWrite().WaitAsync(timeout.Token);
            return result.Clone();
        }
        finally
        {
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
            }
        }
    }

    internal static async Task VerifyIsolatedWritesAsync()
    {
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        while (directory != null && !File.Exists(Path.Combine(directory.FullName, "tools", "toolbox_controls.py"))) directory = directory.Parent;
        if (directory == null) throw new InvalidOperationException("probe_repo_missing");
        string repo = Path.Combine(directory.FullName, ".tmp", "settings-native-write-" + Guid.NewGuid().ToString("N"));
        string tools = Path.Combine(repo, "tools"); Directory.CreateDirectory(tools); Directory.CreateDirectory(Path.Combine(repo, "ahk"));
        foreach (string file in new[] { "toolbox_preferences.py", "toolbox_controls.py", "toolbox_configuration.py", "configuration_schema.py", "toolbox_credentials.py", "toolbox_reload.py", "toolbox_capture_activity.py", "toolbox_settings_search.py" })
            await File.WriteAllBytesAsync(Path.Combine(tools, file), await File.ReadAllBytesAsync(Path.Combine(directory.FullName, "tools", file)));
        await File.WriteAllBytesAsync(Path.Combine(repo, "ahk", "shortcuts.ahk"), await File.ReadAllBytesAsync(Path.Combine(directory.FullName, "ahk", "shortcuts.ahk")));
        foreach (string module in new[] { "translate", "tts", "theme-scheduler" })
        { Directory.CreateDirectory(Path.Combine(tools, module)); await File.WriteAllTextAsync(Path.Combine(tools, module, "config.toml"), "# isolated probe; no credentials\n"); }
        async Task<JsonElement> Run(string file, object? request, params string[] args) =>
            await RunHelperAsync(file, request, CancellationToken.None, args, 262144, tools);
        JsonElement initial = await Run("toolbox_controls.py", null);
        JsonElement off = await Run("toolbox_controls.py", new { revision = initial.GetProperty("revision").GetString(), changes = new { module_theme_enabled = false } });
        JsonElement read = await Run("toolbox_controls.py", null);
        if (read.GetProperty("values").GetProperty("module_theme_enabled").GetBoolean()) throw new InvalidOperationException("probe_switch_reverted");
        await Run("toolbox_controls.py", new { revision = off.GetProperty("revision").GetString(), changes = new { module_theme_enabled = true } });
        JsonElement prefs = await Run("toolbox_preferences.py", null);
        await Run("toolbox_preferences.py", new { revision = prefs.GetProperty("revision").GetString(), changes = new { translate = new { target_language = "en" } } });
        if ((await Run("toolbox_preferences.py", null)).GetProperty("values").GetProperty("translate").GetProperty("target_language").GetString() != "en")
            throw new InvalidOperationException("probe_preference_not_saved");
        JsonElement config = await Run("toolbox_configuration.py", null, "--module", "theme");
        await Run("toolbox_configuration.py", new { revision = config.GetProperty("revision").GetString(), changes = new Dictionary<string, object> { ["general.show_notification"] = true } }, "--module", "theme");
        if (!(await Run("toolbox_configuration.py", null, "--module", "theme")).GetProperty("fields").EnumerateArray()
            .First(field => field.GetProperty("key").GetString() == "general.show_notification").GetProperty("value").GetBoolean())
            throw new InvalidOperationException("probe_config_not_saved");
        HudLog.Line("settings-write-probe=passed controls=off+on preferences=readback module=readback scope=isolated");
    }
}
