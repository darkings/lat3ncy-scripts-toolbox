#Requires AutoHotkey v2.0

; =====================================================================
; InputAnchor — 4 级全场景输入锚点定位引擎
;
; L1: Win32 GetGUIThreadInfo (传统 Win32 Edit/RichEdit)
; L2: UIA TextPattern2 / TextPattern (Edge, Chrome, Windows Terminal, WinUI3 记事本, VS Code)
; L3: UIA FocusedElement.BoundingRectangle (自绘输入框、搜索栏兜底)
; Fallback: 活动窗口底栏 / 屏幕工作区底部
; =====================================================================

class InputAnchor {
    static Get() {
        activeHwnd := WinExist("A")
        if !activeHwnd
            return this.GetFallback()

        ; L1 先走进程内 Win32 caret。C# locator 每次 RunWait 都要冷启动 CLR/UIA，
        ; 普通编辑框不该为定位阻塞芯片弹出。
        win32 := this.GetWin32Caret(activeHwnd)
        if win32
            return win32

        locExe := NotifyPaths.LocatorExe()

        ; L2/L3：仅 Win32 拿不到 caret 时才启动独立 C# UIA 定位器。
        if (locExe != "" && FileExist(locExe)) {
            try {
                exitCode := RunWait('"' locExe '" ' activeHwnd, , 'Hide')
                if (exitCode > 0) {
                    bx := exitCode & 0x3FFF
                    by := (exitCode >> 14) & 0x3FFF
                    sourceId := (exitCode >> 28) & 0x7
                    cx := bx - 8192
                    cy := by - 8192
                    if (sourceId >= 1 && sourceId <= 3 && (cx != 0 || cy != 0)) {
                        sourceName := (sourceId == 1) ? "win32-caret" : (sourceId == 2 ? "uia-text-caret" : "uia-focused-element")
                        conf := (sourceId == 1) ? 100 : (sourceId == 2 ? 98 : 70)
                        return {
                            x: cx,
                            y: cy,
                            w: 2,
                            h: 20,
                            source: sourceName,
                            confidence: conf
                        }
                    }
                }
            } catch {
            }
        }

        return this.GetFallback(activeHwnd)
    }

    static GetWin32Caret(activeHwnd) {
        try {
            threadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", activeHwnd, "UInt*", 0, "UInt")
            if !threadId
                return 0
            guiInfo := Buffer(8 + (6 * A_PtrSize) + 16, 0)
            NumPut("UInt", guiInfo.Size, guiInfo, 0)
            if !DllCall("User32\GetGUIThreadInfo", "UInt", threadId, "Ptr", guiInfo.Ptr, "Int")
                return 0
            hwndCaret := NumGet(guiInfo, 8 + 4*A_PtrSize, "Ptr")
            rcLeft   := NumGet(guiInfo, 8 + 6*A_PtrSize + 0, "Int")
            rcBottom := NumGet(guiInfo, 8 + 6*A_PtrSize + 12, "Int")
            if !(hwndCaret && (rcLeft != 0 || rcBottom != 0))
                return 0
            pt := Buffer(8, 0)
            NumPut("Int", rcLeft, pt, 0), NumPut("Int", rcBottom, pt, 4)
            DllCall("User32\ClientToScreen", "Ptr", hwndCaret, "Ptr", pt)
            sx := NumGet(pt, 0, "Int"), sy := NumGet(pt, 4, "Int")
            if (sx = 0 && sy = 0)
                return 0
            return {
                x: sx,
                y: sy,
                w: 2,
                h: 20,
                source: "win32-caret",
                confidence: 100
            }
        } catch {
            return 0
        }
    }

    static GetFallback(hwnd := 0) {
        if hwnd {
            try {
                WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
                if (ww > 50 && wh > 50) {
                    return {
                        x: wx + Floor(ww / 2),
                        y: wy + Floor(wh * 0.85),
                        w: 0,
                        h: 0,
                        source: "active-window-bottom",
                        confidence: 40
                    }
                }
            }
        }
        return {
            x: 0,
            y: 0,
            w: 0,
            h: 0,
            source: "screen-fallback",
            confidence: 10
        }
    }
}
