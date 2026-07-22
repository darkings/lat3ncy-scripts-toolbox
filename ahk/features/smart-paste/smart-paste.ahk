#Requires AutoHotkey v2.0

class SmartPaste {
    static HelperPath() {
        return A_ScriptDir "\features\smart-paste\save-clipboard-image.ps1"
    }

    static EnsureHelperAvailable(path := unset) {
        if !IsSet(path)
            path := this.HelperPath()
        if !FileExist(path)
            throw Error("智能粘贴辅助脚本不存在：" path)
        return path
    }

    static ChooseAction(hasFiles, hasImage, hasText, isExplorer) {
        if hasFiles
            return "normal-paste"
        if hasImage
            return isExplorer ? "save-image" : "normal-paste"
        if hasText
            return "plain-text"
        return "normal-paste"
    }

    static HasFiles() {
        return DllCall("User32\IsClipboardFormatAvailable", "UInt", 15, "Int") != 0
    }

    static HasImage() {
        for format in [2, 8, 17] {
            if DllCall("User32\IsClipboardFormatAvailable", "UInt", format, "Int")
                return true
        }

        static pngFormat := DllCall("User32\RegisterClipboardFormatW", "Str", "PNG", "UInt")
        return pngFormat && DllCall("User32\IsClipboardFormatAvailable", "UInt", pngFormat, "Int") != 0
    }

    static HasText() {
        return (DllCall("User32\IsClipboardFormatAvailable", "UInt", 1, "Int")
            || DllCall("User32\IsClipboardFormatAvailable", "UInt", 13, "Int")) != 0
    }

    static GetActiveExplorerPath() {
        activeHwnd := WinExist("A")
        if !activeHwnd
            return ""

        try {
            if (WinGetClass("ahk_id " activeHwnd) != "CabinetWClass")
                return ""

            for window in ComObject("Shell.Application").Windows {
                try {
                    if (window.HWND != activeHwnd)
                        continue
                    path := window.Document.Folder.Self.Path
                    return InStr(FileExist(path), "D") ? path : ""
                }
            }
        } catch {
            return ""
        }
        return ""
    }

    static Paste(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        try {
            hasFiles := this.HasFiles()
            hasImage := this.HasImage()
            hasText := this.HasText()
            isExplorer := WinActive("ahk_class CabinetWClass") != 0
            action := this.ChooseAction(hasFiles, hasImage, hasText, isExplorer)

            if (action = "normal-paste") {
                Send "^v"
            } else if (action = "plain-text") {
                SendText A_Clipboard
                this.ShowTip("已粘贴纯文本")
            } else {
                explorerPath := this.GetActiveExplorerPath()
                if explorerPath
                    this.SaveClipboardImage(explorerPath)
                else
                    this.ShowTip("当前资源管理器位置无法保存图片")
            }
        } catch {
            this.ShowTip("智能粘贴失败")
        }
    }

    static SaveClipboardImage(destination) {
        helperPath := this.EnsureHelperAvailable()

        processId := DllCall("Kernel32\GetCurrentProcessId", "UInt")
        resultFile := A_Temp "\ahk-clipboard-image-" processId "-" this.NewGuid() ".txt"
        command := "powershell.exe -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "
            . this.QuoteArgument(helperPath)
            . " -Destination " this.QuoteArgument(destination)
            . " -ResultFile " this.QuoteArgument(resultFile)

        try {
            exitCode := RunWait(command, , "Hide")
            if (exitCode != 0 || !FileExist(resultFile)) {
                this.ShowTip("图片保存失败")
                return false
            }

            outputPath := Trim(FileRead(resultFile, "UTF-8"))
            SplitPath outputPath, &fileName, , &extension
            if (!outputPath || StrLower(extension) != "png" || !FileExist(outputPath)) {
                this.ShowTip("图片保存失败")
                return false
            }

            this.ShowTip("已保存图片：" fileName)
            return true
        } catch {
            this.ShowTip("图片保存失败")
            return false
        } finally {
            if FileExist(resultFile)
                FileDelete resultFile
        }
    }

    static NewGuid() {
        guidBuffer := Buffer(16, 0)
        if DllCall("Ole32\CoCreateGuid", "Ptr", guidBuffer.Ptr, "Int") != 0
            throw Error("无法创建结果文件标识")
        textBuffer := Buffer(78, 0)
        DllCall("Ole32\StringFromGUID2", "Ptr", guidBuffer.Ptr, "Ptr", textBuffer.Ptr, "Int", 39, "Int")
        return Trim(StrGet(textBuffer, "UTF-16"), "{}")
    }

    static QuoteArgument(value) {
        value := RegExReplace(value, '(\\*)"', '$1$1\"')
        value := RegExReplace(value, '(\\+)$', '$1$1')
        return '"' value '"'
    }

    static ShowTip(message) {
        ToolTip message
        SetTimer SmartPaste.HideTipCallback, 0
        SetTimer SmartPaste.HideTipCallback, -1500
    }

    static HideTip() {
        ToolTip
    }
}

SmartPaste.HotkeyCallback := ObjBindMethod(SmartPaste, "Paste")
SmartPaste.HideTipCallback := ObjBindMethod(SmartPaste, "HideTip")

if !IsToolboxTestMode() {
    SmartPaste.EnsureHelperAvailable()
    RegisterFeatureHotkey("智能粘贴", Shortcuts.SmartPaste, SmartPaste.HotkeyCallback)
}
