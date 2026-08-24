#Requires AutoHotkey v2.0

class AlwaysOnTop {
    ; WS_EX_TOPMOST：置顶切换后用这个判断当前是钉上还是松开。
    static TopmostExStyle := 0x8

    static Toggle(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        try {
            WinSetAlwaysOnTop -1, "A"
            if (WinGetExStyle("A") & this.TopmostExStyle)
                Notify.Success("📌", "已置顶")
            else
                Notify.Success("📌", "已取消置顶")
        } catch {
            Notify.Error("×", "切换置顶失败")
        }
    }
}

AlwaysOnTop.HotkeyCallback := ObjBindMethod(AlwaysOnTop, "Toggle")
