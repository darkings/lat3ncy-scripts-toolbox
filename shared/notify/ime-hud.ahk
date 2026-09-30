#Requires AutoHotkey v2.0
#Include anchor.ahk
#Include paths.ahk
#Include run-nowindow.ahk

; 输入法状态 HUD。优先交给常驻 WinUI 进程，失败时由调用方回退到旧 GDI 渲染。
class ImeHud {
    static WindowClass := "Lat3ncyImeHudWinUi"
    static WindowTitle := "Lat3ncyImeHudWinUi"
    static ProcessName := "ImeHudWinUi.exe"
    static CopyDataId := 1
    static MessageTimeout := 2500
    static LastCommand := ""
    static LastTargetHwnd := 0

    static Show(state, targetHwnd := 0) {
        state := this.NormalizeState(state)
        if (state = "")
            return false
        targetHwnd := InputAnchor.NormalizeHwnd(targetHwnd)
        if !targetHwnd
            targetHwnd := WinExist("A")
        this.LastTargetHwnd := targetHwnd
        x := 0
        y := 0
        InputAnchor.Get(&x, &y, targetHwnd)
        if InputAnchor.LastTargetHwnd
            this.LastTargetHwnd := InputAnchor.LastTargetHwnd
        return this.Send(this.BuildStateCommand(state, x, y, 0, 0, this.LastTargetHwnd))
    }

    static Hide() {
        return this.Send("HIDE")
    }

    static Stop() {
        return this.Send("QUIT")
    }

    static BuildStateCommand(state, x := 0, y := 0, dpi := 0, durationMs := 0, targetHwnd := 0) {
        state := this.NormalizeState(state)
        if (state = "")
            return ""
        command := Format("STATE|{1}|{2}|{3}|{4}|{5}", state, Integer(x), Integer(y), Integer(dpi), Integer(durationMs))
        targetHwnd := InputAnchor.NormalizeHwnd(targetHwnd)
        if targetHwnd
            command .= "|" targetHwnd
        return command
    }

    static NormalizeState(state) {
        state := StrUpper(Trim(String(state)))
        if (state = "CN" || state = "ZH" || state = "CH" || state = "中")
            return "CN"
        if (state = "EN" || state = "ENG" || state = "英")
            return "EN"
        if (state = "CAPS" || state = "CAP" || state = "CAPSLOCK")
            return "CAPS"
        return ""
    }

    static Send(command) {
        this.LastCommand := command
        if !this.EnsureRunning()
            return false
        hwnd := this.FindWindow()
        if !hwnd
            return false
        return this.SendCopyData(hwnd, command)
    }

    static SendCopyData(hwnd, command) {
        data := Buffer(StrPut(command, "UTF-16") * 2, 0)
        StrPut(command, data, "UTF-16")
        copy := Buffer(A_PtrSize = 8 ? 24 : 12, 0)
        NumPut("Ptr", this.CopyDataId, copy, 0)
        NumPut("UInt", data.Size, copy, A_PtrSize)
        NumPut("Ptr", data.Ptr, copy, A_PtrSize = 8 ? 16 : 8)
        result := 0
        sent := DllCall(
            "SendMessageTimeoutW",
            "Ptr", hwnd,
            "UInt", 0x004A,
            "Ptr", 0,
            "Ptr", copy,
            "UInt", 0x0002,
            "UInt", this.MessageTimeout,
            "Ptr*", &result,
            "Ptr"
        )
        return sent != 0 && result != 0
    }

    static EnsureRunning() {
        if this.FindWindow()
            return true
        exe := NotifyPaths.ImeHudWinUiExe()
        if !FileExist(exe)
            return false
        try {
            ProcessNoWindow.Run(Format('"{1}"', exe))
        } catch {
            return false
        }
        deadline := A_TickCount + 2500
        while (A_TickCount < deadline) {
            if this.FindWindow()
                return true
            Sleep 40
        }
        return this.FindWindow() != 0
    }

    static FindWindow() {
        hwnd := WinExist("ahk_class " this.WindowClass)
        if hwnd
            return hwnd
        return WinExist(this.WindowTitle " ahk_exe " this.ProcessName)
    }
}
