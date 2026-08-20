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

        locExe := A_ScriptDir "\..\shared\notify\anchor-locator.exe"
        if !FileExist(locExe)
            locExe := "C:\Users\Jie\Projects\lat3ncy-scripts-toolbox\shared\notify\anchor-locator.exe"

        ; 1. 优先调用独立 C# UIA 定位引擎
        if FileExist(locExe) {
            try {
                exitCode := RunWait('"' locExe '" ' activeHwnd, , 'Hide')
                if (exitCode > 0) {
                    cx := exitCode & 0x3FFF
                    cy := (exitCode >> 14) & 0x3FFF
                    sourceId := (exitCode >> 28) & 0xF
                    if (sourceId >= 1 && sourceId <= 3 && cx > 0 && cy > 0) {
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

        ; 2. Win32 Caret 探测兜底
        try {
            threadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", activeHwnd, "UInt*", 0, "UInt")
            if threadId {
                guiInfo := Buffer(8 + (6 * A_PtrSize) + 16, 0)
                NumPut("UInt", guiInfo.Size, guiInfo, 0)
                if DllCall("User32\GetGUIThreadInfo", "UInt", threadId, "Ptr", guiInfo.Ptr, "Int") {
                    hwndCaret := NumGet(guiInfo, 8 + 4*A_PtrSize, "Ptr")
                    rcLeft   := NumGet(guiInfo, 8 + 6*A_PtrSize + 0, "Int")
                    rcBottom := NumGet(guiInfo, 8 + 6*A_PtrSize + 12, "Int")
                    if (hwndCaret && (rcLeft != 0 || rcBottom != 0)) {
                        pt := Buffer(8, 0)
                        NumPut("Int", rcLeft, pt, 0), NumPut("Int", rcBottom, pt, 4)
                        DllCall("User32\ClientToScreen", "Ptr", hwndCaret, "Ptr", pt)
                        sx := NumGet(pt, 0, "Int"), sy := NumGet(pt, 4, "Int")
                        if (sx > 0 || sy > 0) {
                            return {
                                x: sx,
                                y: sy,
                                w: 2,
                                h: 20,
                                source: "win32-caret-fallback",
                                confidence: 90
                            }
                        }
                    }
                }
            }
        } catch {
        }

        return this.GetFallback(activeHwnd)
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
