#Requires AutoHotkey v2.0

; 隐藏窗口：按 Z-order 取当前未最小化的可见顶层窗口，每次只藏最上面那一个。
class HideActiveWindow {
    static ProtectedClasses := Map(
        "progman", true,
        "workerw", true,
        "shell_traywnd", true,
        "shell_secondarytraywnd", true,
        "notifyiconoverflowwindow", true,
        "dv2controlhost", true
    )

    static IsOwnProcess(pid) {
        return pid = ProcessExist()
    }

    static IsProtectedWindow(className, pid) {
        if this.IsOwnProcess(pid)
            return true
        return this.ProtectedClasses.Has(StrLower(Trim(className)))
    }

    static IsHideable(hwnd) {
        if !hwnd
            return false
        if !DllCall("IsWindow", "Ptr", hwnd)
            return false
        if !DllCall("IsWindowVisible", "Ptr", hwnd)
            return false

        try {
            className := WinGetClass("ahk_id " hwnd)
            pid := WinGetPID("ahk_id " hwnd)
            if this.IsProtectedWindow(className, pid)
                return false
            ; -1 是已最小化，不进入“当前可见”队列。
            if (WinGetMinMax("ahk_id " hwnd) = -1)
                return false
            if (WinGetExStyle("ahk_id " hwnd) & 0x80) ; WS_EX_TOOLWINDOW
                return false
        } catch {
            return false
        }

        cloaked := 0
        result := DllCall(
            "dwmapi\DwmGetWindowAttribute",
            "Ptr", hwnd,
            "UInt", 14, ; DWMWA_CLOAKED
            "UInt*", &cloaked,
            "UInt", 4,
            "Int")
        return result != 0 || !cloaked
    }

    ; WinGetList 默认就是 Z-order，第一个是最顶层。
    static VisibleWindows() {
        windows := []
        try list := WinGetList()
        catch
            return windows

        for hwnd in list {
            if this.IsHideable(hwnd)
                windows.Push(hwnd)
        }
        return windows
    }

    static NextTarget() {
        windows := this.VisibleWindows()
        return windows.Length ? windows[1] : 0
    }

    static Hide(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        hwnd := this.NextTarget()
        ; 没有可藏窗口是正常终点，和 macOS ⌘+H 一样保持静默。
        if !hwnd
            return

        try {
            WinMinimize "ahk_id " hwnd
        } catch as err {
            Notify.Error("×", "隐藏窗口失败: " err.Message)
        }
    }
}

HideActiveWindow.HotkeyCallback := ObjBindMethod(HideActiveWindow, "Hide")
