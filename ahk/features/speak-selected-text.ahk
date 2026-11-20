#Requires AutoHotkey v2.0
#Include ..\..\shared\notify\run-nowindow.ahk

class SpeakSelectedText {
    static TtsPid := 0
    static LastInputFile := ""
    static WatchBound := ""
    ; 与 C# connect_wait_ms(12s) + 蓝牙枚举余量对齐；异步等待，不堵 AHK。
    static HeadsetTimeoutMs := 18000
    static PollIntervalMs := 100
    static WarmupJob := ""
    static WarmupTimer := ""
    static PendingText := ""
    static Generation := 0

    static LogPath() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        return repoDir "\tools\tts\tts.log"
    }

    ; 默认只记长度/状态/PID；不要把原文或片段写进日志。
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

    static ResolvePython(scriptPath := "") {
        if (scriptPath = "")
            scriptPath := this.ResolveScript()
        SplitPath scriptPath, , &scriptDir
        candidate := scriptDir "\.venv\Scripts\pythonw.exe"
        if FileExist(candidate)
            return candidate
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

    static StopWarmup() {
        if (this.WarmupTimer != "") {
            try SetTimer(this.WarmupTimer, 0)
            this.WarmupTimer := ""
        }
        if IsObject(this.WarmupJob) {
            try this.WarmupJob.job.Dispose()
            if (this.WarmupJob.outputFile != "")
                try FileDelete this.WarmupJob.outputFile
            this.WarmupJob := ""
        }
        this.PendingText := ""
    }

    static StopCurrent() {
        this.Generation += 1
        this.StopWarmup()
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

    ; 异步预热耳机：先让 Caps+S 线程返回，连上（或失败/超时）后再启动 TTS。
    static StartHeadsetWarmup(raw) {
        gen := this.Generation
        this.PendingText := raw
        exe := this.AudioSwitcherExe()
        if !FileExist(exe) {
            this.Log("预热跳过：audio-switcher.exe 未找到")
            this.LaunchTts(raw, gen)
            return
        }
        outputFile := A_Temp "\lat3ncy-audio-ensure-" A_TickCount "-" Random(1000, 9999) ".txt"
        try FileDelete outputFile
        command := '"' exe '" --ensure-headset'
        try {
            try {
                job := ProcessNoWindow.StartAsync(command, outputFile, this.HeadsetTimeoutMs)
            } catch as runErr {
                if !InStr(runErr.Message, "无法创建输出文件")
                    throw runErr
                this.Log("预热耳机输出文件失败，fallback 无输出执行: " runErr.Message)
                outputFile := ""
                job := ProcessNoWindow.StartAsync(command, "", this.HeadsetTimeoutMs)
            }
        } catch as err {
            this.Log("预热耳机启动异常: " err.Message)
            try FileDelete outputFile
            this.LaunchTts(raw, gen)
            return
        }
        this.WarmupJob := { job: job, outputFile: outputFile, generation: gen }
        this.WarmupTimer := ObjBindMethod(this, "PollWarmup")
        SetTimer(this.WarmupTimer, this.PollIntervalMs)
    }

    static PollWarmup(*) {
        try {
            if !IsObject(this.WarmupJob) {
                this.StopWarmup()
                return
            }
            job := this.WarmupJob.job
            job.Poll()
            if !job.Done
                return

            info := this.WarmupJob
            this.WarmupJob := ""
            if (this.WarmupTimer != "") {
                try SetTimer(this.WarmupTimer, 0)
                this.WarmupTimer := ""
            }

            output := ""
            if (info.outputFile != "") {
                try output := Trim(FileRead(info.outputFile, "UTF-8"))
                try FileDelete info.outputFile
            }
            if (job.Status = "timedout") {
                this.Log("预热耳机超时（继续进行朗读）")
            } else if (job.Status != "exited") {
                this.Log("预热耳机失败: " job.Status)
            } else if (output != "") {
                this.Log("预热耳机: " output)
            } else {
                this.Log("预热耳机: 无输出")
            }

            if (info.generation != this.Generation) {
                this.Log("预热结果已过期，丢弃")
                return
            }
            raw := this.PendingText
            this.PendingText := ""
            this.LaunchTts(raw, info.generation)
        } catch as err {
            raw := this.PendingText
            gen := this.Generation
            this.Log("预热耳机轮询异常: " err.Message)
            this.StopWarmup()
            this.LaunchTts(raw, gen)
        }
    }

    static LaunchTts(raw, generation) {
        if (generation != this.Generation)
            return
        inputFile := this.NewInputFile()
        try {
            try FileDelete inputFile
            FileAppend raw, inputFile, "UTF-8"

            pythonExe := this.ResolvePython()
            scriptPath := this.ResolveScript()
            cmd := '"' pythonExe '" "' scriptPath '" --input-file "' inputFile '"'
            this.Log("启动朗读 (长度: " StrLen(raw) ")")

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
            this.Log("获取到剪贴板文本 (长度: " StrLen(raw) ")")
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
            gen := this.Generation
            if (this.IsAutoSwitchEnabled()) {
                this.Log("检测到 tts.auto_switch_before_play=true，异步预热 AirPods")
                this.StartHeadsetWarmup(raw)
                return
            }
            this.LaunchTts(raw, gen)
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
