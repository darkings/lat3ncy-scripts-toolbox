#Requires AutoHotkey v2.0

class OpenSelectedTarget {
    static Normalize(value) {
        value := Trim(value)

        if (StrLen(value) >= 2) {
            first := SubStr(value, 1, 1)
            last := SubStr(value, -1)
            if ((first = '"' && last = '"') || (first = "'" && last = "'"))
                value := Trim(SubStr(value, 2, -1))
        }

        if RegExMatch(value, "i)^file:///") {
            value := RegExReplace(value, "i)^file:///+")
            value := StrReplace(value, "/", "\")
        }

        if RegExMatch(value, "i)^(?:[A-Z]:\\|\\\\)")
            value := RegExReplace(value, ":\d+(?::\d+)?$")

        return value
    }

    static Classify(value) {
        if RegExMatch(value, "i)^https?://")
            return "url"

        attributes := FileExist(value)
        if !attributes
            return "invalid"
        return InStr(attributes, "D") ? "directory" : "file"
    }

    static GetSelected() {
        savedClipboard := ClipboardAll()
        try {
            A_Clipboard := ""
            Send "^c"
            if ClipWait(1) {
                target := this.Normalize(A_Clipboard)
                if (this.Classify(target) != "invalid")
                    return target
            }

            if WinActive("ahk_exe Code.exe") {
                A_Clipboard := ""
                Send "+!c"
                if ClipWait(1) {
                    target := this.Normalize(A_Clipboard)
                    if (this.Classify(target) != "invalid")
                        return target
                }
            }

            return ""
        } finally {
            A_Clipboard := savedClipboard
        }
    }

    static Open(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        target := this.GetSelected()
        kind := this.Classify(target)
        if (kind = "url" || kind = "file" || kind = "directory") {
            Run target
            this.ShowTip("正在打开：" this.TargetLabel(target))
        } else
            this.ShowTip("选中内容不是有效路径或网址")
    }

    static ShortText(text, maxLength := 36) {
        text := StrReplace(StrReplace(Trim(text), "`r", " "), "`n", " ")
        return StrLen(text) > maxLength ? SubStr(text, 1, maxLength - 1) "…" : text
    }

    static TargetLabel(target) {
        if RegExMatch(target, "i)^https?://")
            return this.ShortText(target)
        SplitPath target, &name
        return this.ShortText(name || target)
    }

    static ShowTip(message) {
        ToolTip message
        SetTimer OpenSelectedTarget.HideTipCallback, 0
        SetTimer OpenSelectedTarget.HideTipCallback, -1500
    }

    static HideTip() {
        ToolTip
    }
}

OpenSelectedTarget.HotkeyCallback := ObjBindMethod(OpenSelectedTarget, "Open")
OpenSelectedTarget.HideTipCallback := ObjBindMethod(OpenSelectedTarget, "HideTip")

if !IsToolboxTestMode()
    RegisterFeatureHotkey("打开选中目标", Shortcuts.OpenSelectedTarget, OpenSelectedTarget.HotkeyCallback)
