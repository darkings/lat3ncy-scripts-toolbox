#Requires AutoHotkey v2.0
#Include paths.ahk
#Include run-nowindow.ahk

; ============================================================
; WinUI 翻译面板 AHK 客户端
;
; Caps+F 把原文 / 译文发给 tools/ime-hud-winui/out/ImeHudWinUi.exe。
; 协议只打主窗口标题 / 类名 Lat3ncyImeHudWinUi 的 WM_COPYDATA，
; 不找面板 HWND Lat3ncyImeHudWinUiPanel。
;
; PANEL|OPEN|<x>|<y>|<dpi>|mouse-at-hotkey|explicit|<原文>
; PANEL|RESULT|explicit|<译文>
; PANEL|CLOSE
;
; payload 可含 | 和换行，必须走 WM_COPYDATA，不要塞进命令行。
; 冷启动只拉起常驻进程，等芯片主 HWND 出现后再 COPYDATA。
; CLOSE 只发给已有窗口，绝不为此再拉起进程。
; ============================================================
class TranslationPanel {
    static WindowClass := "Lat3ncyImeHudWinUi"
    static WindowTitle := "Lat3ncyImeHudWinUi"
    static CopyDataId := 1
    static WM_COPYDATA := 0x004A
    static SMTO_ABORTIFHUNG := 0x0002
    ; 首次 OPEN 会在目标进程里同步创建面板 Island，80ms 会把 COPYDATA 掐掉。
    static MessageTimeout := 2500
    ; WinUI Application + 芯片 HWND 冷启动需要给足时间。
    static LaunchWaitMs := 3000

    ; x/y 必须是屏幕物理像素，不能是窗口客户区坐标。dpi=0 时 WinUI 自己推。
    static OpenText(text, x := 0, y := 0, dpi := 0) {
        return this.Send(this.BuildOpenCommand(text, x, y, dpi))
    }

    static SetResult(text) {
        return this.Send(this.BuildResultCommand(text))
    }

    ; 只关闭已有面板。找不到 HWND 就当作已经关上，不冷启动。
    static Close() {
        return this.SendExisting(this.BuildCloseCommand())
    }

    static BuildOpenCommand(text, x := 0, y := 0, dpi := 0) {
        ; mouse-at-hotkey 必须由调用方带上真实坐标，WinUI 不会自己读光标冒充。
        return "PANEL|OPEN|" Integer(x) "|" Integer(y) "|" Integer(dpi) "|mouse-at-hotkey|explicit|" text
    }

    static BuildResultCommand(text) {
        return "PANEL|RESULT|explicit|" text
    }

    static BuildCloseCommand() {
        return "PANEL|CLOSE"
    }

    ; 已有窗口直接 COPYDATA；没有窗口就无控制台拉起 exe，再等主 HWND。
    ; 不要 Trim：原文/译文两端空白和换行都属于 payload。
    static Send(command) {
        if (command = "")
            return false

        hwnd := this.FindWindow()
        if hwnd
            return this.SendCopyData(hwnd, command)

        exe := NotifyPaths.ImeHudWinUiExe()
        if (exe = "")
            return false

        try {
            ProcessNoWindow.Run('"' exe '"')
        } catch {
            return false
        }

        deadline := A_TickCount + this.LaunchWaitMs
        while (A_TickCount < deadline) {
            hwnd := this.FindWindow()
            if hwnd
                return this.SendCopyData(hwnd, command)
            Sleep 20
        }
        return false
    }

    static SendExisting(command) {
        if (command = "")
            return false
        hwnd := this.FindWindow()
        if !hwnd
            return false
        return this.SendCopyData(hwnd, command)
    }

    ; 只认 WinUI 芯片主窗口。隐藏的 TOOLWINDOW 也能被 FindWindow 找到。
    static FindWindow() {
        try {
            hwnd := DllCall(
                "User32\FindWindowW",
                "WStr", this.WindowClass,
                "WStr", this.WindowTitle,
                "Ptr"
            )
            if hwnd
                return hwnd

            hwnd := DllCall(
                "User32\FindWindowW",
                "WStr", this.WindowClass,
                "Ptr", 0,
                "Ptr"
            )
            if hwnd
                return hwnd

            hwnd := DllCall(
                "User32\FindWindowW",
                "Ptr", 0,
                "WStr", this.WindowTitle,
                "Ptr"
            )
            if hwnd
                return hwnd
        } catch {
        }
        return 0
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
