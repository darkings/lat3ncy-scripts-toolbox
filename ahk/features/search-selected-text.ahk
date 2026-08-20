#Requires AutoHotkey v2.0

class SearchSelectedText {
    static Search(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        savedClipboard := ClipboardAll()
        try {
            A_Clipboard := ""
            Send "^c"
            if !ClipWait(1) {
                Notify.Error("!", "未选中文字")
                return
            }

            selected := Trim(A_Clipboard)
            if !selected {
                Notify.Error("!", "未选中文字")
                return
            }

            try {
                Run "https://www.google.com/search?q=" this.UriEncode(selected)
            } catch {
                Notify.Error("×", "打开搜索失败")
            }
        } finally {
            A_Clipboard := savedClipboard
        }
    }

    static UriEncode(text) {
        bytes := Buffer(StrPut(text, "UTF-8"))
        byteCount := StrPut(text, bytes, "UTF-8") - 1
        encoded := ""

        Loop byteCount {
            byte := NumGet(bytes, A_Index - 1, "UChar")
            if ((byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte = 0x2D || byte = 0x2E || byte = 0x5F || byte = 0x7E)
                encoded .= Chr(byte)
            else
                encoded .= "%" Format("{:02X}", byte)
        }

        return encoded
    }

    static ShortText(text, maxLength := 36) {
        text := StrReplace(StrReplace(Trim(text), "`r", " "), "`n", " ")
        return StrLen(text) > maxLength ? SubStr(text, 1, maxLength - 1) "…" : text
    }

}

SearchSelectedText.HotkeyCallback := ObjBindMethod(SearchSelectedText, "Search")
