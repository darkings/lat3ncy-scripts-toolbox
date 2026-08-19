#Requires AutoHotkey v2.0

class SmartPasteClipboard {
    Capture() => ClipboardAll()

    Clear() {
        A_Clipboard := ""
    }

    Wait(timeoutSeconds) => ClipWait(timeoutSeconds, true)
    ReadText() => A_Clipboard

    Restore(snapshot) {
        A_Clipboard := snapshot
    }
}

class SmartPaste {
    static VsCodeCopyPathShortcut := ""
    static ZedCopyPathShortcut := ""

    static Configure(vsCodeCopyPathShortcut, zedCopyPathShortcut) {
        this.VsCodeCopyPathShortcut := vsCodeCopyPathShortcut
        this.ZedCopyPathShortcut := zedCopyPathShortcut
    }

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

    static ChooseAction(hasFiles, hasImage, isExplorer, isCopyPathCapableEditor) {
        if hasFiles || !hasImage
            return "normal-paste"
        if isExplorer
            return "save-explorer-image"
        if isCopyPathCapableEditor
            return "probe-copy-path-image"
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

    static DirectoryFromCopiedPath(value) {
        value := Trim(value)
        if !value || InStr(value, "`r") || InStr(value, "`n")
            return ""

        if (StrLen(value) >= 2) {
            first := SubStr(value, 1, 1)
            last := SubStr(value, -1)
            if ((first = '"' && last = '"') || (first = "'" && last = "'"))
                value := SubStr(value, 2, -1)
        }

        attributes := FileExist(value)
        return InStr(attributes, "D") ? value : ""
    }

    static GetCopyPathSelectedDirectory(copyPathShortcut, clipboard := unset, sendCopyPath := unset) {
        if !IsSet(clipboard)
            clipboard := SmartPasteClipboard()
        if !IsSet(sendCopyPath)
            sendCopyPath := shortcut => this.SendCopyPathKey(shortcut)

        snapshot := clipboard.Capture()
        try {
            clipboard.Clear()
            sendCopyPath.Call(copyPathShortcut)
            if !clipboard.Wait(0.75)
                return ""
            value := clipboard.ReadText()
            return this.DirectoryFromCopiedPath(value)
        } finally {
            clipboard.Restore(snapshot)
        }
    }

    static GetCurrentFileParentDirectory(keys := unset, clipboard := unset, sendSequence := unset) {
        if !IsSet(keys)
            keys := ["^k", "p"]
        if !IsSet(clipboard)
            clipboard := SmartPasteClipboard()
        if !IsSet(sendSequence)
            sendSequence := () => this.SendCopyPathSequence(keys)

        snapshot := clipboard.Capture()
        try {
            clipboard.Clear()
            sendSequence.Call()
            if !clipboard.Wait(0.75)
                return ""
            value := Trim(clipboard.ReadText())
            if !value || InStr(value, "`r") || InStr(value, "`n")
                return ""

            if (StrLen(value) >= 2) {
                first := SubStr(value, 1, 1)
                last := SubStr(value, -1)
                if ((first = '"' && last = '"') || (first = "'" && last = "'"))
                    value := SubStr(value, 2, -1)
            }

            attributes := FileExist(value)
            if !attributes
                return ""
            if InStr(attributes, "D")
                return value
            SplitPath value, , &parent
            return InStr(FileExist(parent), "D") ? parent : ""
        } finally {
            clipboard.Restore(snapshot)
        }
    }

    static SendCopyPathKey(shortcut) {
        Send "{Ctrl up}"
        Send shortcut
    }

    static SendCopyPathSequence(keys) {
        Send "{Ctrl up}"
        for key in keys {
            Send key
            Sleep 30
        }
    }

    static Paste(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        hasFiles := this.HasFiles()
        hasImage := this.HasImage()
        isExplorer := WinActive("ahk_class CabinetWClass") != 0
        isVsCode := WinActive("ahk_exe Code.exe") != 0
        isZed := WinActive("ahk_exe zed.exe") != 0
        action := this.ChooseAction(hasFiles, hasImage, isExplorer, isVsCode || isZed)

        if (action = "normal-paste") {
            Send "^v"
            return
        }

        if (action = "save-explorer-image") {
            explorerPath := this.GetActiveExplorerPath()
            if explorerPath
                this.SaveClipboardImage(explorerPath)
            else
                this.ShowTip("当前资源管理器位置无法保存图片")
            return
        }

        copyPathShortcut := isZed
            ? this.ZedCopyPathShortcut
            : this.VsCodeCopyPathShortcut
        if !copyPathShortcut
            throw Error("智能粘贴尚未配置编辑器 Copy Path 快捷键")
        try {
            destination := this.GetCopyPathSelectedDirectory(copyPathShortcut)
        } catch as probeError {
            destination := ""
        }
        if !destination {
            try {
                destination := this.GetCurrentFileParentDirectory()
            } catch as probeError {
                destination := ""
            }
        }
        if !destination && isZed {
            try {
                Send "{Up}"
                Sleep 50
                destination := this.GetCopyPathSelectedDirectory(copyPathShortcut)
            } catch as probeError {
                destination := ""
            }
        }

        if destination
            this.SaveClipboardImage(destination)
        else {
            this.ShowTip("图片粘贴失败：请在文件树选中目录，或打开文件后重试")
            Send "^v"
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
