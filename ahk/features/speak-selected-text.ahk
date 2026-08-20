#Requires AutoHotkey v2.0

class SpeakSelectedText {
    static TtsPid := 0
    static InputFilePath := A_Temp "\lat3ncy-tts-input.txt"

    static LogPath() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        return repoDir "\tools\tts\tts.log"
    }

    static Log(msg) {
        try {
            timeStr := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            FileAppend "[" timeStr "] [AHK] " msg "`n", this.LogPath(), "UTF-8"
        }
    }

    static Normalize(value) {
        return Trim(value)
    }

    static HasSpeakableText(value) {
        return RegExMatch(value, "[\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}A-Za-z]") > 0
    }

    static ResolvePython() {
        if FileExist("D:\Applications\Scoop\apps\python312\current\pythonw.exe")
            return "D:\Applications\Scoop\apps\python312\current\pythonw.exe"
        if FileExist(A_AppData "\..\Local\Programs\Python\Python312\pythonw.exe")
            return A_AppData "\..\Local\Programs\Python\Python312\pythonw.exe"
        return "pythonw.exe"
    }

    static ResolveScript() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        return repoDir "\tools\tts\tts_player.py"
    }

    static StopCurrent() {
        DllCall("winmm\mciSendStringW", "Str", "close all", "Ptr", 0, "UInt", 0, "Ptr", 0)
        DllCall("winmm\PlaySoundW", "Ptr", 0, "Ptr", 0, "UInt", 0)
        if (this.TtsPid && ProcessExist(this.TtsPid)) {
            try ProcessClose(this.TtsPid)
            this.Log("打断前次任务 PID: " this.TtsPid)
            this.TtsPid := 0
        }
    }

    static Speak(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        this.Log("=== 触发快捷键 Ctrl+Alt+S ===")
        savedClipboard := ClipboardAll()
        try {
            A_Clipboard := ""
            Send "^c"
            if !ClipWait(1) {
                this.Log("未能获取剪贴板内容 (超时 1s)")
                Notify.Error("!", "未选中文字")
                return
            }

            raw := this.Normalize(A_Clipboard)
            this.Log("获取到剪贴板文本 (长度: " StrLen(raw) "): " this.ShortText(raw, 50))
            if (raw = "") {
                Notify.Error("!", "未选中文字")
                return
            }

            if !this.HasSpeakableText(raw) {
                this.Log("文本未包含可朗读的中英文字符，跳过")
                Notify.Error("!", "未包含可朗读文字")
                return
            }

            this.StopCurrent()

            try {
                if FileExist(this.InputFilePath)
                    FileDelete this.InputFilePath
                FileAppend raw, this.InputFilePath, "UTF-8"

                pythonExe := this.ResolvePython()
                scriptPath := this.ResolveScript()
                cmd := '"' pythonExe '" "' scriptPath '" --input-file "' this.InputFilePath '"'
                this.Log("执行命令: " cmd)

                pid := 0
                Run cmd, , "Hide", &pid
                this.TtsPid := pid
                this.Log("启动成功, PID: " pid)
            } catch as err {
                this.Log("启动朗读异常: " err.Message)
                Notify.Error("×", "朗读失败")
            }
        } finally {
            A_Clipboard := savedClipboard
        }
    }

    static ShortText(text, maxLength := 36) {
        text := StrReplace(StrReplace(Trim(text), "`r", " "), "`n", " ")
        return StrLen(text) > maxLength ? SubStr(text, 1, maxLength - 1) "…" : text
    }

}

SpeakSelectedText.HotkeyCallback := ObjBindMethod(SpeakSelectedText, "Speak")
