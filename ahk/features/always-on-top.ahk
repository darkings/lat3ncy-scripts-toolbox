#Requires AutoHotkey v2.0

class AlwaysOnTop {
    static Toggle(*) {
        WinSetAlwaysOnTop -1, "A"
        isTopmost := (WinGetExStyle("A") & 0x8) != 0
        this.ShowTip(isTopmost ? "窗口已置顶" : "已取消置顶")
    }

    static ShowTip(message) {
        ToolTip message
        SetTimer AlwaysOnTop.HideTip, 0
        SetTimer AlwaysOnTop.HideTip, -1500
    }

    static HideTip() {
        ToolTip
    }
}

if !IsToolboxTestMode()
    RegisterFeatureHotkey("窗口置顶", Shortcuts.AlwaysOnTop, AlwaysOnTop.Toggle)
