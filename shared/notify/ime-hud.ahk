#Requires AutoHotkey v2.0
#Include paths.ahk
#Include anchor.ahk
#Include run-nowindow.ahk

; ============================================================
; ImeHud AHK 客户端
;
; CapsLockIme 只检测中 / 英 / 大写，状态显示交给 WinUI Renderer。
; 三种状态：CN / EN / CAPS。WinUI 画 32×32 芯片，不走彩色 Badge。
; 协议：STATE|CN|x|y|dpi|durationMs   STATE|EN   STATE|CAPS   HIDE   QUIT
; 已有 WinUI 主窗口走 WM_COPYDATA；没有窗口就无控制台拉起 WinUI exe，
; 命令行带上第一条 STATE。找不到 WinUI 或发送失败时返回 false，
; 由 CapsLockIme 回退 AHK NotifyRenderer 芯片。
; ============================================================
class ImeHud {
    static WindowClass := "Lat3ncyImeHudWinUi"
    static WindowTitle := "Lat3ncyImeHudWinUi"
    static CopyDataId := 1
    static WM_COPYDATA := 0x004A
    static SMTO_ABORTIFHUNG := 0x0002
    ; ShowState 会同步做 caret / DWM / 淡入。80ms 会把 COPYDATA 掐掉，然后回退 AHK 芯片。
    static MessageTimeout := 2500
    ; 冷启动把 STATE 放进命令行；不必像翻译面板那样等 HWND 再 COPYDATA。
    static LaunchWaitMs := 800

    ; state: "CN" / "EN" / "CAPS"。
    ; x/y 为 caret 底部屏幕物理像素。省略时由 AHK 在热键瞬间采 InputAnchor，
    ; WinUI 只负责按 hint 绘制，不要在自己的窗口上下文里猜输入焦点。
    static Show(state, x := unset, y := unset, durationMs := 0) {
        state := StrUpper(Trim(state))
        if (state = "")
            return false

        ; 未显式传入坐标时，由 AHK 在 CapsLock 触发瞬间获取输入 caret。
        ; 这样 WinUI 只负责绘制，不需要在自己的窗口上下文里猜输入焦点。
        if !IsSet(x) || !IsSet(y) {
            try {
                anchor := InputAnchor.Get()
                if IsObject(anchor) {
                    x := anchor.x
                    y := anchor.y
                    dpi := 0
                    if (anchor.HasOwnProp("dpi"))
                        dpi := anchor.dpi
                }
            } catch {
                x := 0
                y := 0
                dpi := 0
            }
        } else {
            dpi := 0
        }

        if !IsSet(x)
            x := 0
        if !IsSet(y)
            y := 0
        if !IsSet(dpi)
            dpi := 0

        command := this.BuildStateCommand(state, x, y, dpi, durationMs)
        return this.Send(command)
    }

    ; STATE|<CN|EN|CAPS>|<x>|<y>|<dpi>|<durationMs>
    ; 坐标必须由调用方或 InputAnchor 填好；0|0 会被 WinUI 当成没有 hint。
    static BuildStateCommand(state, x := 0, y := 0, dpi := 0, durationMs := 0) {
        command := "STATE|" state "|" Integer(x) "|" Integer(y)
        command .= "|" Integer(dpi) "|" Integer(durationMs)
        return command
    }

    static Hide() {
        return this.Send("HIDE")
    }

    static Send(command) {
        ; 常驻 WinUI 已在跑时直接 COPYDATA，不依赖 exe 路径解析。
        hwnd := this.FindWindow()
        if hwnd
            return this.SendCopyData(hwnd, command)

        exe := NotifyPaths.ImeHudWinUiExe()
        if (exe = "")
            return false

        ; 冷启动：把第一条 STATE 放进命令行，避免窗口还没建好就 COPYDATA。
        ; 若已有实例，第二个进程会按 mutex 转发后退出。
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
        ; 进程已拉起或命令已转发，即使暂时 FindWindow 失败也不回退 AHK 芯片，
        ; 避免 AHK 芯片和 WinUI 叠在一起。
        return true
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
