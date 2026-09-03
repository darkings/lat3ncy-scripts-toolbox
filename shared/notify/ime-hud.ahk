#Requires AutoHotkey v2.0
#Include paths.ahk
#Include run-nowindow.ahk

; ============================================================
; ImeHud AHK 客户端
;
; CapsLockIme 只检测中 / 英 / 大写，显示交给 tools/ime-hud/ImeHud.exe。
; 三种状态：CN → 「中」；EN → 「A」；CAPS → 「A」加底线（大写，不是彩色 Badge）。
; 协议：STATE|CN|x|y   STATE|EN   STATE|CAPS   HIDE   QUIT
; 已有窗口走 WM_COPYDATA；没有窗口就无控制台拉起 exe，命令行带上第一条消息。
; exe 不在或发送失败时返回 false，由 CapsLockIme 回退 AHK 芯片。
; ============================================================
class ImeHud {
    static WindowTitle := "Lat3ncyImeHud"
    static CopyDataId := 1
    static WM_COPYDATA := 0x004A
    static SMTO_ABORTIFHUNG := 0x0002
    static MessageTimeout := 80
    static LaunchWaitMs := 400

    ; state: "CN" / "EN" / "CAPS"；x/y 为 caret 底部屏幕坐标，可省略。
    static Show(state, x := 0, y := 0, durationMs := 0) {
        state := StrUpper(Trim(state))
        if (state = "")
            return false

        command := "STATE|" state
        if (x != 0 || y != 0)
            command .= "|" Integer(x) "|" Integer(y)
        else
            command .= "|0|0"
        command .= "|0|" Integer(durationMs)
        return this.Send(command)
    }

    static Hide() {
        return this.Send("HIDE")
    }

    static Send(command) {
        exe := NotifyPaths.ImeHudExe()
        if (exe = "")
            return false

        hwnd := this.FindWindow()
        if hwnd
            return this.SendCopyData(hwnd, command)

        ; 冷启动：把第一条消息放进命令行，避免窗口还没建好就 COPYDATA。
        try {
            ProcessNoWindow.Run('"' exe '" "' command '"')
        } catch {
            return false
        }

        deadline := A_TickCount + this.LaunchWaitMs
        while (A_TickCount < deadline) {
            hwnd := this.FindWindow()
            if hwnd
                return true
            Sleep 20
        }
        ; 进程已拉起，即使暂时 FindWindow 失败也不回退，避免两套 HUD 叠在一起。
        return true
    }

    static FindWindow() {
        try {
            return DllCall(
                "User32\FindWindowW",
                "Ptr", 0,
                "WStr", this.WindowTitle,
                "Ptr"
            )
        } catch {
            return 0
        }
    }

    static SendCopyData(hwnd, text) {
        ; COPYDATASTRUCT：dwData Ptr + cbData UInt + 对齐 + lpData Ptr。
        size := StrPut(text, "UTF-16")
        payload := Buffer(size * 2, 0)
        StrPut text, payload, "UTF-16"
        cds := Buffer(A_PtrSize = 8 ? 24 : 12, 0)
        NumPut("Ptr", this.CopyDataId, cds, 0)
        NumPut("UInt", payload.Size, cds, A_PtrSize)
        NumPut("Ptr", payload.Ptr, cds, A_PtrSize = 8 ? 16 : 8)

        result := 0
        try {
            succeeded := DllCall(
                "User32\SendMessageTimeoutW",
                "Ptr", hwnd,
                "UInt", this.WM_COPYDATA,
                "Ptr", 0,
                "Ptr", cds,
                "UInt", this.SMTO_ABORTIFHUNG,
                "UInt", this.MessageTimeout,
                "UPtr*", &result,
                "Ptr"
            )
            return !!succeeded
        } catch {
            return false
        }
    }
}
