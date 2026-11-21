using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>Explicit UI probe: two settings windows load/close without ending
/// the dispatcher. No global HUD HWND/mutex, settings writes or injected input.</summary>
internal static class SettingsLifecycleProbe
{
    public static int Run()
    {
        int code = 1;
        ToolboxSettingsWindow? window = null;
        DispatcherQueueTimer? timer = null;
        int phase = 0;
        var elapsed = Stopwatch.StartNew();
        Application.Start(_ =>
        {
            DispatcherQueue queue = DispatcherQueue.GetForCurrentThread();
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(queue));
            new HudApp();
            timer = queue.CreateTimer();
            timer.Interval = TimeSpan.FromMilliseconds(100);
            timer.Tick += (_, _) =>
            {
                try
                {
                    if (elapsed.Elapsed > TimeSpan.FromSeconds(20))
                        throw new TimeoutException();
                    if (phase is 0 or 2)
                    {
                        window = new ToolboxSettingsWindow();
                        window.Activate();
                        phase++;
                    }
                    else if (phase is 1 or 3)
                    {
                        if (window?.SettingsLoaded != true) return;
                        window.Close(); window = null;
                        phase++;
                    }
                    else
                    {
                        code = 0;
                        HudLog.Line("settings-lifecycle=passed phases=" + phase);
                        timer.Stop();
                        Application.Current.Exit();
                    }
                }
                catch
                {
                    HudLog.Line("settings-lifecycle=failed phase=" + phase);
                    timer.Stop();
                    try { window?.Close(); } catch { }
                    Application.Current.Exit();
                }
            };
            timer.Start();
        });
        timer?.Stop();
        return code;
    }
}
