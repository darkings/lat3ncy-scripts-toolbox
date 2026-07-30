#Requires AutoHotkey v2.0

class SwitchAppWindow {
    static Snapshot := []
    static ProcessName := ""

    static Forward(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        this.Switch(1)
    }

    static Backward(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        this.Switch(-1)
    }

    static Switch(direction) {
        activeHwnd := WinExist("A")
        if !activeHwnd
            return

        try processName := WinGetProcessName("ahk_id " activeHwnd)
        catch {
            this.Reset()
            return
        }

        if (this.ProcessName != processName || !this.Contains(this.Snapshot, activeHwnd))
            this.StartSession(processName, activeHwnd)
        else
            this.Snapshot := this.LiveWindows(this.Snapshot)

        if (this.Snapshot.Length < 2 || !this.Contains(this.Snapshot, activeHwnd)) {
            this.Reset()
            return
        }

        currentIndex := this.IndexOf(this.Snapshot, activeHwnd)
        nextIndex := this.StepIndex(currentIndex, this.Snapshot.Length, direction)
        targetHwnd := this.Snapshot[nextIndex]

        try WinActivate "ahk_id " targetHwnd
        catch
            this.Reset()
    }

    static StartSession(processName, activeHwnd) {
        this.Reset()
        candidates := []

        try windows := WinGetList("ahk_exe " processName)
        catch
            return

        for hwnd in windows {
            if this.IsCandidate(hwnd)
                candidates.Push(hwnd)
        }

        if !this.Contains(candidates, activeHwnd)
            return

        this.ProcessName := processName
        this.Snapshot := candidates
    }

    static LiveWindows(windows) {
        live := []
        for hwnd in windows {
            if this.IsCandidate(hwnd)
                live.Push(hwnd)
        }
        return live
    }

    static IsCandidate(hwnd) {
        if !DllCall("IsWindow", "Ptr", hwnd)
            return false
        if !DllCall("IsWindowVisible", "Ptr", hwnd)
            return false

        try {
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

    static IndexOf(windows, targetHwnd) {
        for index, hwnd in windows {
            if (hwnd = targetHwnd)
                return index
        }
        return 0
    }

    static Contains(windows, targetHwnd) {
        return this.IndexOf(windows, targetHwnd) != 0
    }

    static StepIndex(currentIndex, count, direction) {
        if (count < 1)
            return 0
        return Mod(currentIndex - 1 + direction + count, count) + 1
    }

    static Reset(*) {
        this.Snapshot := []
        this.ProcessName := ""
    }
}

SwitchAppWindow.ForwardCallback := ObjBindMethod(SwitchAppWindow, "Forward")
SwitchAppWindow.BackwardCallback := ObjBindMethod(SwitchAppWindow, "Backward")
SwitchAppWindow.ResetCallback := ObjBindMethod(SwitchAppWindow, "Reset")

if !IsToolboxTestMode() {
    RegisterFeatureHotkey(
        "同应用下一窗口",
        Shortcuts.SwitchAppWindowNext,
        SwitchAppWindow.ForwardCallback)
    RegisterFeatureHotkey(
        "同应用上一窗口",
        Shortcuts.SwitchAppWindowPrevious,
        SwitchAppWindow.BackwardCallback)
    Hotkey "~Alt Up", SwitchAppWindow.ResetCallback
}
