using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// 只要 WinUI Application 把 ThemeResource / PRI 挂上。
/// 不创建 Microsoft.UI.Xaml.Window，HUD 仍是自己的 Win32 HWND。
/// Application.Resources 在 DesktopWindowXamlSource.Initialize 之前会 E_UNEXPECTED，
/// 所以 XamlControlsResources 要等 Island 起来后再挂。
/// </summary>
public partial class HudApp : Application
{
    public HudApp()
    {
        HudLog.Line("application-ctor");
        try
        {
            InitializeComponent();
            HudLog.Line("application-init-ok");
        }
        catch (Exception ex)
        {
            HudLog.Line("application-init-failed=" + ex);
        }
    }

    public static void TryEnsureControlsResources(string reason)
    {
        Application? app = Current;
        if (app == null)
        {
            HudLog.Line("xaml-controls-resources-skip=" + reason + " no-current");
            return;
        }

        try
        {
            foreach (ResourceDictionary dict in app.Resources.MergedDictionaries)
            {
                if (dict is XamlControlsResources)
                {
                    HudLog.Line("xaml-controls-resources-already reason=" + reason
                        + " count=" + app.Resources.Count);
                    return;
                }
            }

            app.Resources.MergedDictionaries.Add(new XamlControlsResources());
            HudLog.Line("xaml-controls-resources-ok reason=" + reason
                + " count=" + app.Resources.Count);
        }
        catch (Exception ex)
        {
            HudLog.Line("xaml-controls-resources-failed reason=" + reason + " " + ex);
        }
    }
}
