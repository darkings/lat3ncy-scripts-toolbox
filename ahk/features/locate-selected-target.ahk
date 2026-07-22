#Requires AutoHotkey v2.0

class LocateSelectedTarget {
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

    static Locate(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        target := this.GetSelected()
        kind := this.Classify(target)
        if (kind = "file") {
            Run 'explorer.exe /select,"' target '"'
            this.ShowTip("正在定位：" this.TargetLabel(target))
        } else if (kind = "directory") {
            Run target
            this.ShowTip("正在定位：" this.TargetLabel(target))
        } else
            this.ShowTip("选中内容不是有效文件或文件夹")
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
        SetTimer LocateSelectedTarget.HideTipCallback, 0
        SetTimer LocateSelectedTarget.HideTipCallback, -1500
    }

    static HideTip() {
        ToolTip
    }
}

LocateSelectedTarget.HotkeyCallback := ObjBindMethod(LocateSelectedTarget, "Locate")
LocateSelectedTarget.HideTipCallback := ObjBindMethod(LocateSelectedTarget, "HideTip")

if !IsToolboxTestMode()
    RegisterFeatureHotkey("定位选中目标", Shortcuts.LocateSelectedTarget, LocateSelectedTarget.HotkeyCallback)
