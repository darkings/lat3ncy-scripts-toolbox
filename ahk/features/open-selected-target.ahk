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

        if RegExMatch(value, "i)^file://")
            value := this.FileUriToPath(value)

        if RegExMatch(value, "i)^(?:[A-Z]:\\|\\\\)")
            value := RegExReplace(value, ":\d+(?::\d+)?$")

        return value
    }

    static FileUriToPath(uri) {
        if RegExMatch(uri, "i)^file:///")
            path := RegExReplace(uri, "i)^file:///+")
        else
            path := "\\" RegExReplace(uri, "i)^file://+")

        capacity := StrLen(path) + 1
        decoded := Buffer(capacity * 2, 0)
        decodedLength := capacity
        try {
            result := DllCall("Shlwapi\UrlUnescapeW"
                , "Str", path
                , "Ptr", decoded.Ptr
                , "UInt*", &decodedLength
                , "UInt", 0x00040000
                , "Int")
            if (result = 0)
                path := StrGet(decoded, decodedLength, "UTF-16")
        }
        return StrReplace(path, "/", "\")
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
            try {
                Run target
            } catch {
                Notify.Error("×", "打开目标失败")
            }
        } else
            Notify.Error("!", "不是有效路径或网址")
    }

    static ShortText(text, maxLength := 36) {
        text := StrReplace(StrReplace(Trim(text), "`r", " "), "`n", " ")
        return StrLen(text) > maxLength ? SubStr(text, 1, maxLength - 1) "…" : text
    }

    static TargetLabel(target) {
        if RegExMatch(target, "i)^https?://")
            return this.ShortText(target)
        SplitPath target, &name
        return this.ShortText(name ? name : target)
    }

}

OpenSelectedTarget.HotkeyCallback := ObjBindMethod(OpenSelectedTarget, "Open")
