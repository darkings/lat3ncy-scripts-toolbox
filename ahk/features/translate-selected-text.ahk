#Requires AutoHotkey v2.0
#Include ..\..\shared\notify\run-nowindow.ahk
#Include ..\..\shared\notify\translation-panel.ahk

class TranslateSelectedText {
    static CachedRepoDir := ""

    static RepoDir() {
        if (this.CachedRepoDir != "")
            return this.CachedRepoDir
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        this.CachedRepoDir := repoDir
        return repoDir
    }

    static Normalize(value) {
        return Trim(value)
    }

    static HasTranslatableText(value) {
        return RegExMatch(value, "[\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}A-Za-z]") > 0
    }

    static ResolvePython() {
        return ToolboxPython.ResolveW()
    }

    static ResolveScript() {
        return this.RepoDir() "\tools\translate\translate.py"
    }

    static ResolveConfig() {
        return this.RepoDir() "\tools\translate\config.toml"
    }

    static ParseField(content, name) {
        needle := "m)^" name "="
        if !RegExMatch(content, needle, &match)
            return ""
        start := match.Pos + match.Len
        rest := SubStr(content, start)
        if (name = "text")
            return rest
        lineEnd := InStr(rest, "`n")
        if !lineEnd
            return Trim(rest, "`r")
        return Trim(SubStr(rest, 1, lineEnd - 1), "`r")
    }

    static Translate(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        ; 热键瞬间的屏幕物理像素。必须先记，不能等 Ctrl+C / 翻译完成后再读光标。
        ; AHK v2 默认 CoordMode Mouse=Client：右边窗口里的客户区 (336,378)
        ; 会被 WinUI 当成屏幕坐标，面板就会落到左半边。本热键线程只改 Mouse。
        CoordMode "Mouse", "Screen"
        hotkeyX := 0
        hotkeyY := 0
        MouseGetPos &hotkeyX, &hotkeyY

        savedClipboard := ClipboardAll()
        selected := ""
        try {
            A_Clipboard := ""
            Send "^c"
            if ClipWait(0.4)
                selected := this.Normalize(A_Clipboard)
        } finally {
            A_Clipboard := savedClipboard
        }

        if (selected = "")
            selected := this.Normalize(A_Clipboard)

        if (selected = "") {
            Notify.Error("!", "未选中文字")
            return
        }
        if !this.HasTranslatableText(selected) {
            Notify.Error("!", "未包含可翻译文字")
            return
        }

        pythonExe := this.ResolvePython()
        scriptPath := this.ResolveScript()
        configPath := this.ResolveConfig()
        if !FileExist(scriptPath) {
            Notify.Error("×", "翻译组件未找到")
            return
        }

        stamp := A_TickCount "-" Random(1000, 9999)
        inputFile := A_Temp "\lat3ncy-translate-in-" stamp ".txt"
        outputFile := A_Temp "\lat3ncy-translate-out-" stamp ".txt"
        try FileDelete inputFile
        try FileDelete outputFile
        try {
            FileAppend selected, inputFile, "UTF-8"
            cmd := '"' pythonExe '" "' scriptPath '" --input-file "' inputFile '" --output-file "' outputFile '"'
            if FileExist(configPath)
                cmd .= ' --config "' configPath '"'
            ; 翻译一开始就打开 WinUI 面板显示原文。
            TranslationPanel.OpenText(selected, hotkeyX, hotkeyY)
            ; 腾讯云 4s + Google/MyMemory 回退；略大于 3*timeout_s，避免父进程先杀。
            ProcessNoWindow.RunWait(cmd, "", 14000)

            if !FileExist(outputFile) {
                TranslationPanel.Close()
                Notify.Error("×", "翻译失败")
                return
            }
            content := FileRead(outputFile, "UTF-8")
            status := this.ParseField(content, "status")
            if (status = "ok") {
                text := this.ParseField(content, "text")
                text := Trim(text, "`r`n")
                if (text = "") {
                    TranslationPanel.Close()
                    Notify.Error("!", "未包含可翻译文字")
                    return
                }
                ; 面板填显式译文；密钥/网络错误关闭面板后走系统 Toast。
                TranslationPanel.SetResult(text)
                return
            }
            ; 失败时关掉翻译面板，避免还挂着旧原文 / 占位译文。
            TranslationPanel.Close()
            code := this.ParseField(content, "code")
            message := this.ParseField(content, "message")
            ; Python 已写好「腾讯云密钥无效 / 阿里云密钥无效」；缺省时用通用文案。
            if (code = "auth" && message = "")
                message := "翻译密钥无效"
            if (message = "")
                message := "翻译失败"
            Notify.Error("×", message)
        } catch as err {
            TranslationPanel.Close()
            if InStr(err.Message, "超时")
                Notify.Error("×", "翻译超时")
            else
                Notify.Error("×", "翻译失败")
        } finally {
            try FileDelete inputFile
            try FileDelete outputFile
        }
    }
}

TranslateSelectedText.HotkeyCallback := ObjBindMethod(TranslateSelectedText, "Translate")
