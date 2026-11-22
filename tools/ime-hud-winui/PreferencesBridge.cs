using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Fixed local helper, JSON stdio, no shell, keys, clipboard or network.</summary>
internal static class PreferencesBridge
{
    public static Task<JsonElement> RunAsync(object? request, CancellationToken cancellation, bool defaults = false)
    {
        if (defaults && request != null) throw new ArgumentException("settings_unavailable");
        return RunHelperAsync("toolbox_preferences.py", request, cancellation,
            defaults ? new[] { "--defaults" } : Array.Empty<string>(), 16384);
    }

    public static Task<JsonElement> RunConfigurationAsync(string module, object? request, CancellationToken cancellation)
    {
        if (module is not ("translate" or "tts" or "ocr" or "audio" or "theme" or "power" or "rgb"))
            throw new ArgumentException("settings_unavailable");
        return RunHelperAsync("toolbox_configuration.py", request, cancellation, new[] { "--module", module }, 262144);
    }

    public static Task<JsonElement> RunControlsAsync(object? request, CancellationToken cancellation) =>
        RunHelperAsync("toolbox_controls.py", request, cancellation, Array.Empty<string>(), 65536);

    static async Task<JsonElement> RunHelperAsync(string filename, object? request, CancellationToken cancellation,
                                                 string[] arguments, int limit)
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
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
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
                throw new InvalidOperationException(code is "settings_changed_reload" or "protected_config_manual" || fixedValidation ? code : "settings_unavailable");
            }
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
}
