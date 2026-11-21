using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Fixed local helper, JSON stdio, no shell, keys, clipboard or network.</summary>
internal static class PreferencesBridge
{
    public static async Task<JsonElement> RunAsync(object? request, CancellationToken cancellation)
    {
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        string? helper = null;
        for (int i = 0; i < 7 && directory != null; i++, directory = directory.Parent)
        {
            string candidate = Path.Combine(directory.FullName, "tools", "toolbox_preferences.py");
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
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        using Process process = Process.Start(start) ?? throw new InvalidOperationException("settings_unavailable");
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
            if (json.Length > 16384)
                throw new InvalidOperationException("settings_unavailable");
            using JsonDocument doc = JsonDocument.Parse(json);
            JsonElement result = doc.RootElement;
            if (process.ExitCode != 0 || result.GetProperty("status").GetString() != "ok")
            {
                string? code = result.TryGetProperty("code", out var value) ? value.GetString() : null;
                throw new InvalidOperationException(code == "settings_changed_reload" ? code : "settings_unavailable");
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
