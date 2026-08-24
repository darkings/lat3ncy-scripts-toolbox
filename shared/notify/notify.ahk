#Requires AutoHotkey v2.0
#Include paths.ahk
#Include run-nowindow.ahk

; 项目统一通知 API。state 走芯片 HUD；其余走系统 Toast，失败回退 ToolTip。
class Notify {
    static Mode := "full"
    static ToolTipHideCallback := 0
    static PriorityMap := Map("state", 1, "info", 2, "success", 3, "error", 4)
    static CurrentLevel := 0
    static ActiveUntil := 0
    static ToastDebounceMs := 250
    static ToastFlushCallback := 0
    static PendingToast := 0

    static State(icon, text := "", duration := 550) {
        return this.Show("state", icon, text, duration)
    }

    static Success(icon, text := "", duration := 900) {
        return this.Show("success", icon, text, duration)
    }

    static Info(icon, text := "", duration := 750) {
        return this.Show("info", icon, text, duration)
    }

    static Error(icon, text := "", duration := 1400) {
        return this.Show("error", icon, text, duration)
    }

    static Show(type, icon, text := "", duration := 650) {
        if !this.ShouldShow(type)
            return false

        level := this.PriorityMap.Has(type) ? this.PriorityMap[type] : 1
        now := A_TickCount
        ; 高优先级保护：若当前正处于活跃的高优先级错误通知中，忽略低优先级瞬态 state 通知
        if (now < this.ActiveUntil && this.CurrentLevel >= 4 && level < 3)
            return false

        this.CurrentLevel := level
        this.ActiveUntil := now + duration

        ; 仅 state（输入法中/A/⇪）走光标上方 28x28 HUD；其他结果走系统右下角 Toast
        if (type == "state") {
            try {
                this.HideToolTip()
                NotifyRenderer.Show(type, icon, text, duration)
                return true
            } catch {
                this.ShowToolTip(icon, text, duration)
                return false
            }
        }

        ; 连按只保留最后一条结果通知，避免 Toast 一条条排队弹出。
        this.PendingToast := {type: type, icon: icon, text: text, duration: duration}
        SetTimer this.ToastFlushCallback, 0
        SetTimer this.ToastFlushCallback, -Max(1, this.ToastDebounceMs)
        return true
    }

    static FlushToast(*) {
        pending := this.PendingToast
        this.PendingToast := 0
        if !IsObject(pending)
            return false

        if (pending.type == "error") {
            try DllCall("User32\MessageBeep", "UInt", 0x00000010)
        } else if (pending.type == "success") {
            try DllCall("User32\MessageBeep", "UInt", 0x00000040)
        }

        return this.ShowToast(pending.type, pending.icon, pending.text, pending.duration)
    }

    static ShowToast(type, icon, text, duration := 650) {
        title := icon " " ((type == "error") ? "错误" : ((type == "success") ? "成功" : "提示"))
        msg := text
        toastScript := NotifyPaths.ToastScript()
        if (toastScript = "") {
            this.ShowToolTip(icon, text, duration)
            return false
        }

        try {
            escapedT := StrReplace(title, '"', '\"')
            escapedM := StrReplace(StrReplace(StrReplace(msg, '"', '\"'), "`r", ""), "`n", " ")
            ProcessNoWindow.Run('powershell.exe -ExecutionPolicy Bypass -NoProfile -File "' toastScript '" "' escapedT '" "' escapedM '"')
            return true
        } catch {
            this.ShowToolTip(icon, text, duration)
            return false
        }
    }

    static ShouldShow(type) {
        switch this.Mode {
            case "off":
                return false
            case "errors":
                return type = "error"
            default:
                return true
        }
    }

    static ShowToolTip(icon, text, duration) {
        message := icon
        if (text != "")
            message .= "  " text

        ToolTip message
        SetTimer this.ToolTipHideCallback, 0
        SetTimer this.ToolTipHideCallback, -Max(1, duration)
    }

    static HideToolTip(*) {
        if this.ToolTipHideCallback
            SetTimer this.ToolTipHideCallback, 0
        ToolTip
        this.CurrentLevel := 0
        this.ActiveUntil := 0
    }
}

Notify.ToolTipHideCallback := ObjBindMethod(Notify, "HideToolTip")
Notify.ToastFlushCallback := ObjBindMethod(Notify, "FlushToast")
