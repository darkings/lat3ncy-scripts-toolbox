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
        Task? preview = null;
        Task? modules = null;
        Task? tray = null;
        Task? navigation = null;
        IntPtr closingHwnd = IntPtr.Zero;
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
                    if (elapsed.Elapsed > TimeSpan.FromSeconds(45))
                        throw new TimeoutException();
                    if (phase is 0 or 2)
                    {
                        if (closingHwnd != IntPtr.Zero && Native.IsWindow(closingHwnd))
                            throw new InvalidOperationException("settings_native_window_retained");
                        window = new ToolboxSettingsWindow(readOnlyProbe: true);
                        window.Activate();
                        phase++;
                    }
                    else if (phase is 1 or 3)
                    {
                        if (window?.SettingsLoaded != true) return;
                        modules ??= window.VerifyModulePagesAsync();
                        if (!modules.IsCompleted) return;
                        modules.GetAwaiter().GetResult();
                        preview ??= window.PreviewDefaultsAsync();
                        if (!preview.IsCompleted) return;
                        preview.GetAwaiter().GetResult();
                        if (!window.DefaultsPreviewed) throw new InvalidOperationException();
                        if (!window.BrandLogoLoaded) throw new InvalidOperationException();
                        if (!window.WindowIconReady || !window.AppWindow.IsShownInSwitchers) throw new InvalidOperationException("settings_window_icon_missing");
                        navigation ??= window.VerifyNavigationLayoutAsync();
                        if (!navigation.IsCompleted) return;
                        navigation.GetAwaiter().GetResult();
                        tray ??= ToolboxTray.VerifyHostedAsync(WinRT.Interop.WindowNative.GetWindowHandle(window), queue);
                        if (!tray.IsCompleted) return;
                        tray.GetAwaiter().GetResult();
                        closingHwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
                        if (phase == 1) window.InvokeCloseButtonForProbe();
                        else window.Close();
                        window = null;
                        preview = null;
                        modules = null;
                        tray = null;
                        navigation = null;
                        phase++;
                    }
                    else
                    {
                        if (Native.IsWindow(closingHwnd)) throw new InvalidOperationException("settings_native_window_retained");
                        code = 0;
                        HudLog.Line("settings-lifecycle=passed phases=" + phase);
                        timer.Stop();
                        Application.Current.Exit();
                    }
                }
                catch (Exception error)
                {
                    HudLog.Line("settings-lifecycle=failed phase=" + phase);
                    HudLog.Line("settings-lifecycle-error=" + error.GetType().Name + ":" +
                        (error is InvalidOperationException ? error.Message : "probe_exception"));
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
