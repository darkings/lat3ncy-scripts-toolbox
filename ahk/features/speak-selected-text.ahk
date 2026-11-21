#Requires AutoHotkey v2.0
#Include ..\..\shared\notify\run-nowindow.ahk
#Include ..\..\shared\notify\toolbox-instance.ahk

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
    static CurrentTask := ""
    static RetiredTasks := []
    static LastOutcome := ""
    static TaskTimeoutMs := 1800000
    static SynthesisTimeoutSeconds := 30
    static ExitBound := ""

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
        profile := this.ProfilePython(scriptDir)
        if (profile != "")
            return profile
        candidate := scriptDir "\.venv\Scripts\pythonw.exe"
        if FileExist(candidate)
            return candidate
        return ToolboxPython.ResolveW()
    }

    static ProfilePython(scriptDir, localData := "") {
        if (localData = "")
            localData := EnvGet("LOCALAPPDATA")
        if (localData = "")
            return ""
        directory := localData "\lat3ncy-toolbox\tts-runtimes\" ToolboxInstance.Hash(scriptDir)
        candidate := directory "\Scripts\pythonw.exe"
        try {
            if (FileExist(candidate) && Trim(FileRead(directory "\.ready.txt", "UTF-8"), "`r`n ") = StrLower(RTrim(scriptDir, "\/")))
                return candidate
        }
        return ""
    }

    static ResolveScript() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        return repoDir "\tools\tts\tts_player.py"
    }

    static NewRequest(generation) {
        this.ScavengeRequests()
        owner := DllCall("GetCurrentProcessId", "UInt")
        created := this.ProcessStartTicks(owner)
        if (created <= 0)
            throw Error("无法确认朗读任务归属")
        id := owner "-" created "-" generation "-" A_TickCount "-" Format("{:08X}{:08X}", Random(0, 0x7FFFFFFF), Random(0, 0x7FFFFFFF))
        SplitPath this.ResolveScript(), , &scriptDir
        directory := scriptDir "\.cache\requests\" id
        DirCreate directory
        return {id: id, generation: generation, directory: directory,
            inputFile: directory "\lat3ncy-tts-in-data.txt", resultFile: directory "\result.txt",
            retiredTick: 0}
    }

    static ProcessStartTicks(pid) {
        if !ProcessExist(pid)
            return 0
        handle := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")
        if !handle
            return -1 ; unknown is not absent
        try {
            created := Buffer(8), exited := Buffer(8), kernel := Buffer(8), user := Buffer(8)
            if !DllCall("GetProcessTimes", "Ptr", handle, "Ptr", created, "Ptr", exited, "Ptr", kernel, "Ptr", user)
                return -1
            return NumGet(created, 0, "Int64")
        } finally {
            DllCall("CloseHandle", "Ptr", handle)
        }
    }

    static ScavengeRequests() {
        SplitPath this.ResolveScript(), , &scriptDir
        count := 0
        loop files scriptDir "\.cache\requests\*", "D" {
            count += 1
            if (count > 128)
                break
            if (DllCall("GetFileAttributesW", "Str", A_LoopFileFullPath, "UInt") & 0x400)
                continue
            if !RegExMatch(A_LoopFileName, "^(\d+)-(\d+)-\d+-\d+-[0-9A-F]{16}$", &m)
                continue
            try {
                created := this.ProcessStartTicks(Integer(m[1]))
                expected := Integer(m[2])
            } catch {
                continue
            }
            if (created = -1 || created = expected)
                continue
            task := {id: A_LoopFileName, directory: A_LoopFileFullPath,
                inputFile: A_LoopFileFullPath "\lat3ncy-tts-in-data.txt",
                resultFile: A_LoopFileFullPath "\result.txt"}
            this.CleanupTaskFiles(task)
        }
    }

    static CacheDirectories() {
        SplitPath this.ResolveScript(), , &scriptDir
        dirs := [scriptDir "\.cache"]
        localData := EnvGet("LOCALAPPDATA")
        if (localData != "")
            dirs.Push(localData "\lat3ncy-toolbox\tts-cache")
        return dirs
    }

    static CleanupTaskFiles(task) {
        ok := true
        for path in [task.inputFile, task.resultFile] {
            try {
                if FileExist(path)
                    FileDelete path
            } catch {
                ok := false
            }
        }
        ; Only files tagged with our unique request id, never a PID glob.
        for cache in this.CacheDirectories() {
            for pattern in [cache "\.tts-tmp." task.id ".*", cache "\*.tmp." task.id ".*"] {
                loop files pattern, "F" {
                    try FileDelete A_LoopFileFullPath
                    catch
                        ok := false
                }
            }
        }
        loop files task.resultFile ".*.tmp", "F" {
            try FileDelete A_LoopFileFullPath
            catch
                ok := false
        }
        try {
            if DirExist(task.directory)
                DirDelete task.directory ; non-recursive: preserve unexpected files
        } catch {
            ok := false
        }
        return ok
    }

    static ReadResult(task) {
        try {
            if (FileGetSize(task.resultFile) > 1024)
                return ""
            fields := Map()
            for line in StrSplit(Trim(FileRead(task.resultFile, "UTF-8"), "`r`n"), "`n", "`r") {
                if !RegExMatch(line, "^(version|request_id|status|error_kind|stage)=([A-Za-z0-9_-]{1,120})$", &m)
                    return ""
                if fields.Has(m[1])
                    return ""
                fields[m[1]] := m[2]
            }
            if (fields.Count != 5 || fields["version"] != "1" || fields["request_id"] != task.id)
                return ""
            if !InStr("|success|failed|timeout|cancelled|", "|" fields["status"] "|")
                return ""
            if !InStr("|none|input|synthesis|playback|timeout|internal|cancelled|", "|" fields["error_kind"] "|")
                return ""
            if !InStr("|input|synthesis|waiting|playback|complete|", "|" fields["stage"] "|")
                return ""
            return fields
        }
        return ""
    }

    static Outcome(task) {
        if (task.job.Status = "cancelled")
            return {status: "cancelled", kind: "cancelled", message: ""}
        if (task.job.Status = "timedout")
            return {status: "timeout", kind: "timeout", message: "朗读超时"}
        report := this.ReadResult(task)
        if (task.job.Status != "exited" || !IsObject(report))
            return {status: "failed", kind: "protocol", message: "朗读结果不可用"}
        status := report["status"], kind := report["error_kind"]
        if (status = "success" && task.job.ExitCode = 0 && kind = "none")
            return {status: "success", kind: kind, message: ""}
        if (status = "success" || task.job.ExitCode = 0)
            return {status: "failed", kind: "protocol", message: "朗读结果不一致"}
        if ((status = "timeout" && (kind != "timeout" || task.job.ExitCode != 2))
            || (status = "cancelled" && (kind != "cancelled" || task.job.ExitCode != 130))
            || (status = "failed" && (kind = "none" || kind = "cancelled")))
            return {status: "failed", kind: "protocol", message: "朗读结果不一致"}
        messages := Map("input", "无法读取朗读文本", "synthesis", "语音合成失败",
            "playback", "音频播放失败", "timeout", "朗读超时", "internal", "朗读失败", "cancelled", "")
        return {status: status, kind: kind, message: messages.Has(kind) ? messages[kind] : "朗读失败"}
    }

    static FinishTask(task, showNotification := true) {
        outcome := this.Outcome(task)
        outcome.request_id := task.id
        previousCritical := A_IsCritical
        Critical "On"
        try {
            current := IsObject(this.CurrentTask) && this.CurrentTask = task && task.generation = this.Generation
            if current {
                this.CurrentTask := "", this.TtsPid := 0, this.LastInputFile := ""
                this.LastOutcome := outcome
            }
        } finally {
            Critical previousCritical
        }
        if current
            this.Log("朗读结束 request=" task.id " status=" outcome.status " kind=" outcome.kind " exit=" task.job.ExitCode)
        if !this.CleanupTaskFiles(task) {
            task.retiredTick := A_TickCount
            this.RetiredTasks.Push(task)
        }
        if (showNotification && current && task.generation = this.Generation && outcome.message != "")
            Notify.Error("×", outcome.message)
        return outcome
    }

    static EnsurePidWatch() {
        if (this.WatchBound = "") {
            this.WatchBound := ObjBindMethod(this, "WatchPid")
            SetTimer(this.WatchBound, this.PollIntervalMs)
        }
        if (this.ExitBound = "") {
            this.ExitBound := ObjBindMethod(this, "OnToolboxExit")
            OnExit this.ExitBound
        }
    }

    static ClearPidWatch() {
        if (this.WatchBound != "") {
            try SetTimer(this.WatchBound, 0)
            this.WatchBound := ""
        }
    }

    static WatchPid(*) {
        if IsObject(this.CurrentTask) {
            task := this.CurrentTask
            task.job.Poll()
            if task.job.Done
                this.FinishTask(task)
        }
        index := this.RetiredTasks.Length
        while (index > 0) {
            task := this.RetiredTasks[index]
            task.job.Poll()
            if task.job.Done {
                if this.CleanupTaskFiles(task)
                    this.RetiredTasks.RemoveAt(index)
                else if (A_TickCount - task.retiredTick > 10000) {
                    this.Log("临时文件清理失败 request=" task.id)
                    this.RetiredTasks.RemoveAt(index)
                }
            }
            index -= 1
        }
        if (!IsObject(this.CurrentTask) && this.RetiredTasks.Length = 0)
            this.ClearPidWatch()
    }

    static OnToolboxExit(*) {
        this.StopCurrent()
        for task in this.RetiredTasks
            task.job.Dispose()
        Sleep 50
        for task in this.RetiredTasks
            this.CleanupTaskFiles(task)
        this.RetiredTasks := []
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
        if IsObject(this.CurrentTask) {
            task := this.CurrentTask
            this.CurrentTask := ""
            this.LastOutcome := {status: "cancelled", kind: "cancelled", message: "", request_id: task.id}
            task.job.Cancel()
            task.retiredTick := A_TickCount
            this.RetiredTasks.Push(task)
            this.EnsurePidWatch()
            this.Log("取消朗读 request=" task.id)
        }
        this.TtsPid := 0, this.LastInputFile := ""
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
        task := ""
        job := ""
        try {
            task := this.NewRequest(generation)
            FileAppend raw, task.inputFile, "UTF-8"

            pythonExe := this.ResolvePython()
            scriptPath := this.ResolveScript()
            cmd := '"' pythonExe '" "' scriptPath '" --input-file "' task.inputFile '"'
                . ' --request-id "' task.id '" --result-file "' task.resultFile '"'
                . ' --synthesis-timeout ' this.SynthesisTimeoutSeconds ' --task-timeout ' (this.TaskTimeoutMs // 1000 - 5)
            this.Log("启动朗读 (长度: " StrLen(raw) ")")

            previousCritical := A_IsCritical
            Critical "On"
            try {
                if (generation != this.Generation) {
                    this.CleanupTaskFiles(task)
                    return
                }
                job := ProcessNoWindow.StartAsync(cmd, "", this.TaskTimeoutMs, true)
                task.job := job
                this.CurrentTask := task
                this.TtsPid := job.Pid
                this.LastInputFile := task.inputFile
            } finally {
                Critical previousCritical
            }
            this.EnsurePidWatch()
            this.Log("启动成功 request=" task.id " PID=" job.Pid)
        } catch as err {
            this.Log("启动朗读异常: " err.Message)
            if IsObject(job)
                job.Dispose()
            if (IsObject(this.CurrentTask) && this.CurrentTask = task)
                this.CurrentTask := "", this.TtsPid := 0, this.LastInputFile := ""
            if IsObject(task)
                this.CleanupTaskFiles(task)
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
