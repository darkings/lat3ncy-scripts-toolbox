#Requires AutoHotkey v2.0

class AlwaysOnTop {
    static Toggle(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        WinSetAlwaysOnTop -1, "A"
        isTopmost := (WinGetExStyle("A") & 0x8) != 0
        if isTopmost
            Notify.State("↑", "窗口置顶")
        else
            Notify.State("↓", "取消置顶")
    }
}

AlwaysOnTop.HotkeyCallback := ObjBindMethod(AlwaysOnTop, "Toggle")
