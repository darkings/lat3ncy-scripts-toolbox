using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Lat3ncyToolbox.ImeHudWinUi;

internal static class SettingsAutosaveProbe
{
    public static int Run()
    {
        DirectoryInfo? source = new(AppContext.BaseDirectory);
        while (source != null && !File.Exists(Path.Combine(source.FullName, "tools", "toolbox_controls.py"))) source = source.Parent;
        if (source == null) return 1;
        string root = Path.Combine(source.FullName, ".tmp", "settings-autosave-native-" + Guid.NewGuid().ToString("N"));
        string tools = Path.Combine(root, "tools"); Directory.CreateDirectory(tools); Directory.CreateDirectory(Path.Combine(root, "ahk"));
        foreach (string file in new[] { "toolbox_preferences.py", "toolbox_configuration.py", "configuration_schema.py", "toolbox_controls.py", "toolbox_credentials.py", "toolbox_reload.py" })
            File.Copy(Path.Combine(source.FullName, "tools", file), Path.Combine(tools, file));
        File.Copy(Path.Combine(source.FullName, "ahk", "shortcuts.ahk"), Path.Combine(root, "ahk", "shortcuts.ahk"));
        foreach (string module in new[] { "translate", "tts", "theme-scheduler", "power-policy", "rgb", "audio-switcher", "raycast-scripts/ocr", "raycast-scripts/capture" })
        { string directory = Path.Combine(tools, module); Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "config.toml"), "# isolated native autosave fixture\n"); }
        PreferencesBridge.ProbeTools = tools;
        int code = 1;
        Application.Start(_ =>
        {
            var queue = DispatcherQueue.GetForCurrentThread();
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(queue));
            new HudApp();
            queue.TryEnqueue(async () =>
            {
                ToolboxSettingsWindow? window = null;
                try { window = new ToolboxSettingsWindow(); window.Activate(); await window.VerifyAutosaveAsync().WaitAsync(TimeSpan.FromSeconds(50)); code = 0; }
                catch (Exception error) { HudLog.Line("settings-autosave-probe=failed kind=" + error.GetType().Name + " code=" + (error is InvalidOperationException ? error.Message : "probe_exception")); }
                finally { try { window?.CloseForShutdown(); } catch { } Application.Current.Exit(); }
            });
        });
        PreferencesBridge.ProbeTools = null;
        return code;
    }
}
