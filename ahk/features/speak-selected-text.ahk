#Requires AutoHotkey v2.0
#Include ..\..\shared\notify\run-nowindow.ahk

class SpeakSelectedText {
    static TtsPid := 0
    static LastInputFile := ""
    static WatchBound := ""

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
        return ToolboxPython.ResolveW()
    }

    static ResolveScript() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        return repoDir "\tools\tts\tts_player.py"
    }

    static NewInputFile() {
        return A_Temp "\lat3ncy-tts-in-" A_TickCount "-" Random(1000, 9999) ".txt"
    }

    static ClearPidWatch() {
        if (this.WatchBound != "") {
            try SetTimer(this.WatchBound, 0)
            this.WatchBound := ""
        }
    }

    static WatchPid(*) {
        if (this.TtsPid && ProcessExist(this.TtsPid))
            return
        this.TtsPid := 0
        if (this.LastInputFile != "") {
            try FileDelete this.LastInputFile
            this.LastInputFile := ""
        }
        this.ClearPidWatch()
    }

    static StopCurrent() {
        DllCall("winmm\mciSendStringW", "Str", "close all", "Ptr", 0, "UInt", 0, "Ptr", 0)
        DllCall("winmm\PlaySoundW", "Ptr", 0, "Ptr", 0, "UInt", 0)
        this.ClearPidWatch()
        if (this.TtsPid && ProcessExist(this.TtsPid)) {
            try ProcessClose(this.TtsPid)
            this.Log("打断前次任务 PID: " this.TtsPid)
        }
        this.TtsPid := 0
        if (this.LastInputFile != "") {
            try FileDelete this.LastInputFile
            this.LastInputFile := ""
        }
    }

    static AudioSwitcherExe() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        return repoDir "\tools\audio-switcher\audio-switcher.exe"
    }

    static IsAutoSwitchEnabled() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        cfg := repoDir "\tools\audio-switcher\config.toml"
        if !FileExist(cfg)
            return false
        try {
            text := FileRead(cfg, "UTF-8")
            if RegExMatch(text, "m)^\s*auto_switch_before_play\s*=\s*true\s*$") {
                return true
            }
        } catch {
            ; 配置读取失败视为关闭预热
        }
        return false
    }

    static EnsureHeadset() {
        exe := this.AudioSwitcherExe()
        if !FileExist(exe) {
            this.Log("预热跳过：audio-switcher.exe 未找到")
            return
        }
        temp := A_Temp "\lat3ncy-audio-ensure-" A_TickCount "-" Random(1000, 9999) ".txt"
        try FileDelete A_Temp "\lat3ncy-audio-ensure.txt"
        try {
            try FileDelete temp
            try {
                ; 预热失败不阻塞朗读；超时略大于 C# 12s 等待，避免父进程先杀子进程。
                ProcessNoWindow.RunWait('"' exe '" --ensure-headset', temp, 18000)
            } catch as runErr {
                if InStr(runErr.Message, "无法创建输出文件") {
                    this.Log("预热耳机输出文件失败，fallback 直接执行: " runErr.Message)
                    ProcessNoWindow.RunWait('"' exe '" --ensure-headset', "", 18000)
                    this.Log("预热耳机: 已执行 fallback（无输出）")
                    return
                }
                throw runErr
            }
            out := ""
            try out := Trim(FileRead(temp, "UTF-8"))
            if (out != "")
                this.Log("预热耳机: " out)
            else
                this.Log("预热耳机: 无输出")
        } catch as err {
            this.Log("预热耳机异常: " err.Message)
        } finally {
            try FileDelete temp
        }
    }

    static Speak(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        this.Log("=== 触发快捷键 Caps+S ===")
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
            if (this.IsAutoSwitchEnabled()) {
                this.Log("检测到 tts.auto_switch_before_play=true，尝试预热 AirPods")
                this.EnsureHeadset()
            }

            inputFile := this.NewInputFile()
            try {
                try FileDelete inputFile
                FileAppend raw, inputFile, "UTF-8"

                pythonExe := this.ResolvePython()
                scriptPath := this.ResolveScript()
                cmd := '"' pythonExe '" "' scriptPath '" --input-file "' inputFile '"'
                this.Log("执行命令: " cmd)

                ; 非等待启动：CREATE_NO_WINDOW，不建 Job，返回 PID 给 WatchPid 清临时文件。
                pid := ProcessNoWindow.Run(cmd)
                this.TtsPid := pid
                this.LastInputFile := inputFile
                this.WatchBound := ObjBindMethod(this, "WatchPid")
                SetTimer(this.WatchBound, 400)
                this.Log("启动成功, PID: " pid)
            } catch as err {
                this.Log("启动朗读异常: " err.Message)
                try FileDelete inputFile
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
