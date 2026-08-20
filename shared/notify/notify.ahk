#Requires AutoHotkey v2.0

; 项目统一通知 API。Renderer 失败时自动回退到 ToolTip。
class Notify {
    static Mode := "full"
    static ToolTipHideCallback := 0

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

        try {
            this.HideToolTip()
            NotifyRenderer.Show(type, icon, text, duration)
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
    }
}

Notify.ToolTipHideCallback := ObjBindMethod(Notify, "HideToolTip")
