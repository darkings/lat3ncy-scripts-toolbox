using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>
/// Island 自己的 SystemBackdrop。
/// 默认 DesktopAcrylicBackdrop 会跟窗口激活态；WS_EX_NOACTIVATE 永远是「未激活」。
/// 这里用 Composition Controller，强制 IsInputActive=true。
/// 配方不要改 Thin：32×32 上 Thin 看起来像换了一套底色。
/// </summary>
internal sealed class IslandSystemBackdrop : SystemBackdrop
{
    ISystemBackdropControllerWithTargets? _controller;
    SystemBackdropConfiguration? _config;
    int _reforceLogs;

    public static bool IsSupported() => DesktopAcrylicController.IsSupported();

    public void ForceInputActive()
    {
        if (_config == null)
            return;
        if (_config.IsInputActive)
            return;
        _config.IsInputActive = true;
        if (_reforceLogs < 4)
        {
            _reforceLogs++;
            HudLog.Line("island-backdrop-reforce-input-active");
        }
    }

    public void SyncTheme(bool dark)
    {
        ApplyForcedConfig(dark);
    }

    protected override void OnTargetConnected(
        ICompositionSupportsSystemBackdrop connectedTarget,
        XamlRoot xamlRoot)
    {
        base.OnTargetConnected(connectedTarget, xamlRoot);

        _config = new SystemBackdropConfiguration();
        ApplyForcedConfig();
        HudLog.Line("island-backdrop-config=manual"
            + " input-active=" + _config.IsInputActive
            + " theme=" + _config.Theme);

        if (Native.HighContrastEnabled())
        {
            HudLog.Line("island-backdrop-connect-skip high-contrast=True");
            return;
        }

        if (!IsSupported())
        {
            HudLog.Line("island-backdrop-connect-skip unsupported");
            return;
        }

        try
        {
            // 默认 Desktop Acrylic，不要 Thin。
            var controller = new DesktopAcrylicController();
            controller.SetSystemBackdropConfiguration(_config);
            bool added = controller.AddSystemBackdropTarget(connectedTarget);
            _controller = controller;
            HudLog.Line("island-backdrop-controller-ok=DesktopAcrylicController"
                + " recipe=Acrylic.Default"
                + " added=" + added
                + " input-active=" + _config.IsInputActive
                + " theme=" + _config.Theme);
        }
        catch (Exception ex)
        {
            HudLog.Line("island-backdrop-controller-failed=" + ex);
            DisposeController();
        }
    }

    protected override void OnDefaultSystemBackdropConfigurationChanged(
        ICompositionSupportsSystemBackdrop target,
        XamlRoot xamlRoot)
    {
        base.OnDefaultSystemBackdropConfigurationChanged(target, xamlRoot);
        ApplyForcedConfig();
    }

    void ApplyForcedConfig()
    {
        ApplyForcedConfig(Native.AppsUseDarkMode());
    }

    void ApplyForcedConfig(bool dark)
    {
        if (_config == null)
            return;
        SystemBackdropTheme theme = dark
            ? SystemBackdropTheme.Dark
            : SystemBackdropTheme.Light;
        if (_config.Theme != theme)
            _config.Theme = theme;
        ForceInputActive();
        if (!_config.IsInputActive)
            _config.IsInputActive = true;
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop disconnectedTarget)
    {
        try
        {
            _controller?.RemoveSystemBackdropTarget(disconnectedTarget);
            HudLog.Line("island-backdrop-target-removed");
        }
        catch (Exception ex)
        {
            HudLog.Line("island-backdrop-target-remove-failed=" + ex.GetType().Name);
        }

        DisposeController();
        _config = null;
        base.OnTargetDisconnected(disconnectedTarget);
    }

    void DisposeController()
    {
        if (_controller is IDisposable disposable)
        {
            try { disposable.Dispose(); }
            catch (Exception ex)
            {
                HudLog.Line("island-backdrop-controller-dispose-failed=" + ex.GetType().Name);
            }
        }
        _controller = null;
    }
}
