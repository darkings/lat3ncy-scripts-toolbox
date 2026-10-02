#Requires AutoHotkey v2.0
#Include paths.ahk

; 输入锚点：优先光标/选区，失败时落到指定窗口底部，而不是主屏。
; control HWND 只用于 caret / UIA；窗口矩形和显示器兜底使用 root HWND。
class InputAnchor {
    static LastSource := ""
    static LastTargetHwnd := 0

    ; 真实光标来源白名单。和 anchor-locator.exe、tools/ime-hud-winui/Protocol.cs
    ; 三处必须保持一致：只有这些来源能当作“跟着光标”，其余都是退化锚点。
    ; value-caret = 表单控件 ValuePattern 选区；text-caret = TextPattern 插入点。
    static RealCaretSources := ["text-caret", "value-caret", "imm-caret", "win32-caret"]

    static IsRealCaretSource(source) {
        source := Trim(String(source))
        if (source = "")
            return false
        for candidate in this.RealCaretSources {
            if (source = candidate)
                return true
        }
        return false
    }

    static Get(&x, &y, targetHwnd := 0) {
        x := 0
        y := 0
        this.LastSource := ""
        this.LastTargetHwnd := 0
        controlHwnd := this.NormalizeHwnd(targetHwnd)
        if !controlHwnd
            controlHwnd := WinExist("A")
        if !controlHwnd
            return false

        rootHwnd := this.GetRootHwnd(controlHwnd)
        if !rootHwnd
            rootHwnd := controlHwnd
        this.LastTargetHwnd := rootHwnd

        if this.TryCaret(&x, &y, controlHwnd) {
            this.LastSource := "caret"
            return true
        }
        if this.TryLocator(&x, &y, controlHwnd) {
            this.LastSource := "locator"
            return true
        }
        if this.TryWindowBottom(&x, &y, rootHwnd) {
            this.LastSource := "target-window-bottom"
            return true
        }
        if this.TryMonitorFallback(&x, &y, rootHwnd) {
            this.LastSource := "target-monitor-fallback"
            return true
        }
        return false
    }

    static GetRootHwnd(hwnd) {
        hwnd := this.NormalizeHwnd(hwnd)
        if !hwnd || !WinExist("ahk_id " hwnd)
            return 0
        ; GA_ROOT = 2。子控件先归一到顶层窗口，再做矩形和显示器兜底。
        root := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")
        if root && WinExist("ahk_id " root)
            return root
        return hwnd
    }

    static NormalizeHwnd(hwnd) {
        if !hwnd
            return 0
        if IsInteger(hwnd)
            return Integer(hwnd)
        text := String(hwnd)
        if RegExMatch(text, "^0[xX][0-9A-Fa-f]+$")
            return Integer(text)
        if RegExMatch(text, "^\d+$")
            return Integer(text)
        return 0
    }

    static GetWin32Caret(activeHwnd := 0, &x := 0, &y := 0) {
        return this.TryCaret(&x, &y, activeHwnd)
    }

    static TryCaret(&x, &y, targetHwnd := 0) {
        info := Buffer(8 + 6 * A_PtrSize + 16, 0)
        NumPut("UInt", info.Size, info, 0)
        hwndCaretOffset := 8 + 5 * A_PtrSize
        rcCaretOffset := 8 + 6 * A_PtrSize
        if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", info)
            return false
        caretHwnd := NumGet(info, hwndCaretOffset, "Ptr")
        if !caretHwnd
            return false
        if targetHwnd && !this.BelongsTo(caretHwnd, targetHwnd)
            return false
        left := NumGet(info, rcCaretOffset, "Int")
        top := NumGet(info, rcCaretOffset + 4, "Int")
        right := NumGet(info, rcCaretOffset + 8, "Int")
        bottom := NumGet(info, rcCaretOffset + 12, "Int")
        if (right <= left || bottom <= top)
            return false
        point := Buffer(8, 0)
        NumPut("Int", left, point, 0)
        NumPut("Int", bottom, point, 4)
        if !DllCall("ClientToScreen", "Ptr", caretHwnd, "Ptr", point)
            return false
        x := NumGet(point, 0, "Int")
        y := NumGet(point, 4, "Int")
        return true
    }

    static TryLocator(&x, &y, targetHwnd := 0) {
        exe := NotifyPaths.LocatorExe()
        if (exe = "" || !FileExist(exe))
            return false
        command := Format('"{1}"', exe)
        if targetHwnd
            command .= " --hwnd " targetHwnd
        output := ""
        outputFile := A_Temp "\lat3ncy-anchor-" A_TickCount "-" Random(1000, 9999) ".txt"
        exitCode := 1
        try {
            exitCode := ProcessNoWindow.RunWait(command, outputFile, 800)
            output := FileExist(outputFile) ? FileRead(outputFile, "UTF-8") : ""
        } catch {
            return false
        } finally {
            if FileExist(outputFile)
                try FileDelete(outputFile)
        }
        if (exitCode != 0 || !RegExMatch(output, "m)^(-?\d+)\|(-?\d+)\|([A-Za-z0-9_-]+)$", &match))
            return false
        x := Integer(match[1])
        y := Integer(match[2])
        this.LastSource := match[3]
        return true
    }

    static TryWindowBottom(&x, &y, hwnd) {
        if !hwnd || !WinExist("ahk_id " hwnd)
            return false
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
        if (ww < 32 || wh < 32)
            return false
        x := wx + Floor(ww / 2)
        y := wy + Floor(wh * 0.85)
        return true
    }

    static TryMonitorFallback(&x, &y, hwnd) {
        point := Buffer(8, 0)
        if hwnd && WinExist("ahk_id " hwnd) {
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
            NumPut("Int", wx + Floor(ww / 2), point, 0)
            NumPut("Int", wy + Floor(wh / 2), point, 4)
        } else if !DllCall("GetCursorPos", "Ptr", point) {
            return false
        }
        monitor := DllCall("MonitorFromPoint", "Int64", NumGet(point, 0, "Int64"), "UInt", 2, "Ptr")
        if !monitor
            return false
        info := Buffer(40, 0)
        NumPut("UInt", info.Size, info, 0)
        if !DllCall("GetMonitorInfo", "Ptr", monitor, "Ptr", info)
            return false
        left := NumGet(info, 20, "Int")
        top := NumGet(info, 24, "Int")
        right := NumGet(info, 28, "Int")
        bottom := NumGet(info, 32, "Int")
        if (right <= left || bottom <= top)
            return false
        x := left + Floor((right - left) / 2)
        y := top + Floor((bottom - top) * 0.82)
        return true
    }

    static BelongsTo(child, root) {
        child := this.NormalizeHwnd(child)
        root := this.GetRootHwnd(root)
        if !child || !root
            return false
        if (child = root)
            return true
        childRoot := this.GetRootHwnd(child)
        if (childRoot && childRoot = root)
            return true
        return DllCall("IsChild", "Ptr", root, "Ptr", child)
    }
}
