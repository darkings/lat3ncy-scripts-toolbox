#Requires AutoHotkey v2.0

class AlwaysOnTop {
    static Toggle(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        WinSetAlwaysOnTop -1, "A"
        isTopmost := (WinGetExStyle("A") & 0x8) != 0
        this.ShowTip(isTopmost ? "窗口已置顶" : "已取消置顶")
    }

    static ShowTip(message) {
        ToolTip message
        SetTimer AlwaysOnTop.HideTipCallback, 0
        SetTimer AlwaysOnTop.HideTipCallback, -1500
    }

    static HideTip() {
        ToolTip
    }
}

AlwaysOnTop.HotkeyCallback := ObjBindMethod(AlwaysOnTop, "Toggle")
AlwaysOnTop.HideTipCallback := ObjBindMethod(AlwaysOnTop, "HideTip")

if !IsToolboxTestMode()
    RegisterFeatureHotkey("窗口置顶", Shortcuts.AlwaysOnTop, AlwaysOnTop.HotkeyCallback)
