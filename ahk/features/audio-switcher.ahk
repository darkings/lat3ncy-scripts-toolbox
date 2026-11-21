#Requires AutoHotkey v2.0
#Include ..\..\shared\notify\run-nowindow.ahk

class AudioSwitcher {
    static Busy := false
    static LastTick := 0
    static DebounceMs := 700
    ; 必须大于 C# 最坏路径（建链/等待 + A2DP 重协商 ~19s + 恢复后再等 14s）+ 蓝牙枚举余量。
    ; 耳机睡眠时 A2DP 重协商本身要十几秒，超时给短了会在成功前被父进程杀掉。
    ; 自动提权重试会共用这一份总预算，不会再叠一个完整预算。
    static ChildTimeoutMs := 48000
    static PollIntervalMs := 100
    static Job := ""
    static Task := ""
    static PollTimer := ""

    static ExePath() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        return repoDir "\tools\audio-switcher\audio-switcher.exe"
    }

    static ConfigPath() {
        SplitPath this.ExePath(), , &dir
        return dir "\config.toml"
    }

    static ParseProtocol(output) {
        text := Trim(output)
        parts := StrSplit(text, "|", , 2)
        status := parts.Length > 0 ? parts[1] : ""
        detail := parts.Length > 1 ? parts[2] : ""
        return { status: status, detail: detail, handled: false }
    }

    static RemainingTimeout(startTick) {
        remain := this.ChildTimeoutMs - (A_TickCount - startTick)
        return remain < 3000 ? 3000 : remain
    }

    static IsAutoElevateEnabled() {
        cfg := this.ConfigPath()
        if !FileExist(cfg)
            return false
        try {
            text := FileRead(cfg, "UTF-8")
            if RegExMatch(text, "m)^\s*auto_elevate\s*=\s*true\s*$")
                return true
        } catch {
            ; 配置读失败视为关闭自动提权
        }
        return false
    }

    static IsPermissionError(detail) {
        return RegExMatch(detail, "i)(access is denied|access denied|拒绝访问|权限不足|need_admin|elevation|提权失败|administrator)") > 0
    }

    ; 立体声未就绪 / 连接超时不是权限错误；默认也不自动 sudo。
    static ShouldAutoElevate(detail) {
        switch detail {
            case "耳机未就绪", "耳机未取出或不在附近", "蓝牙已连但立体声未就绪", "连接超时", "设备节点不存在", "耳机未激活":
                return false
        }
        if !this.IsAutoElevateEnabled()
            return false
        return this.IsPermissionError(detail)
    }

    static ResolveSudo() {
        sudoExe := "C:\Windows\System32\sudo.exe"
        if FileExist(sudoExe)
            return sudoExe
        if FileExist("gsudo.exe")
            return "gsudo.exe"
        return ""
    }

    static BuildToggleCommand(exe, elevated := false) {
        if !elevated
            return '"' exe '" --toggle'
        useSudo := this.ResolveSudo()
        if (useSudo = "")
            return ""
        if InStr(useSudo, "sudo.exe")
            return useSudo " --inline `"" exe "`" --toggle"
        if InStr(useSudo, "gsudo")
            return useSudo " --wait `"" exe "`" --toggle"
        return useSudo " `"" exe "`" --toggle"
    }

    ; 非等待启动。输出文件被占用时退回无输出模式（仍执行 SetDefault）。
    static StartToggleJob(command, timeoutMs) {
        tempFile := A_Temp "\lat3ncy-audio-switcher-" A_TickCount "-" Random(1000, 9999) ".txt"
        try FileDelete tempFile
        try {
            job := ProcessNoWindow.StartAsync(command, tempFile, timeoutMs)
            return { job: job, outputFile: tempFile, noOutput: false }
        } catch as err {
            if InStr(err.Message, "无法创建输出文件") {
                job := ProcessNoWindow.StartAsync(command, "", timeoutMs)
                return { job: job, outputFile: "", noOutput: true }
            }
            throw err
        }
    }

    static EnsurePoll() {
        if (this.PollTimer != "")
            return
        this.PollTimer := ObjBindMethod(this, "Poll")
        SetTimer(this.PollTimer, this.PollIntervalMs)
    }

    static StopPoll() {
        if (this.PollTimer = "")
            return
        try SetTimer(this.PollTimer, 0)
        this.PollTimer := ""
    }

    static Finish(message := "") {
        ; 直接丢弃仍在跑的任务会永久泄漏 hProcess/hJob，KILL_ON_JOB_CLOSE 也不会触发，
        ; 子进程会在后台继续跑到 A2DP 重协商结束。先 Dispose 再清引用。
        if (IsObject(this.Job) && !this.Job.Done) {
            try this.Job.Dispose()
        }
        this.Busy := false
        this.Job := ""
        this.Task := ""
        this.StopPoll()
        if (message != "")
            Notify.Error("×", message)
    }

    ; 定时器里只做非阻塞检查；原始 exe 最长 18s，不再堵住 AHK 热键线程。
    static Poll(*) {
        try {
            if !IsObject(this.Job) {
                this.StopPoll()
                return
            }
            this.Job.Poll()
            if !this.Job.Done {
                ; 慢路径（A2DP 重协商）要十几秒：8s 后补一个 HUD，别让用户以为没反应。
                if (IsObject(this.Task) && !this.Task.hudBumped && (A_TickCount - this.Task.startTick) > 8000) {
                    this.Task.hudBumped := true
                    try Notify.Info("⏳", "正在唤醒耳机，请稍候…", 6000)
                }
                return
            }

            job := this.Job
            task := this.Task
            this.Job := ""

            output := ""
            if (!task.phase.noOutput && task.phase.outputFile != "") {
                try output := Trim(FileRead(task.phase.outputFile, "UTF-8"))
                try FileDelete task.phase.outputFile
            }

            if (job.Status = "timedout") {
                this.Finish("音频切换超时")
                return
            }
            if (job.Status != "exited") {
                this.Finish("音频切换失败")
                return
            }

            if task.phase.noOutput {
                ; 没有输出文件时只能看退出码：非 0 也报成功会掩盖真实失败。
                if (job.ExitCode != 0) {
                    this.Finish("音频切换失败（退出码 " job.ExitCode "）")
                    return
                }
                Notify.Success("🔊", "已执行切换（无输出文件）")
                this.Finish()
                return
            }

            result := this.ParseProtocol(output)
            if (!task.elevated && result.status = "ERROR" && this.ShouldAutoElevate(result.detail)) {
                command := this.BuildToggleCommand(task.exe, true)
                if (command != "") {
                    try {
                        Notify.Info("⏳", "权限错误，尝试提权重试…")
                        phase := this.StartToggleJob(command, this.RemainingTimeout(task.startTick))
                        this.Task := { startTick: task.startTick, phase: phase, exe: task.exe, elevated: true, hudBumped: true }
                        this.Job := phase.job
                        return
                    } catch as sudoErr {
                        ; 提权失败忽略，走原错误
                    }
                }
            }

            if this.ApplyProtocol(result.status, result.detail, task.elevated ? "已切换(提权)" : "已切换") {
                if (result.status = "SWITCHED" || result.status = "ONLY_ONE")
                    this.MarkSuccess()
                this.Finish()
                return
            }
            this.Finish(result.detail != "" ? result.detail : (task.elevated ? "音频切换失败(提权)" : "音频切换失败"))
        } catch as err {
            this.Finish("音频切换失败: " err.Message)
        }
    }

    static ApplyProtocol(status, detail, switchedPrefix := "已切换") {
        switch status {
            case "SWITCHED":
                Notify.Success(this.GetDeviceIcon(detail), switchedPrefix ": " detail)
                return true
            case "ONLY_ONE":
                Notify.Info(this.GetDeviceIcon(detail), "当前唯一设备: " detail)
                return true
            case "NO_DEVICE":
                Notify.Error("!", "无可用音频播放设备")
                return true
            case "ERROR":
                return false
            default:
                if (status = "" && detail = "")
                    Notify.Error("×", "无响应（exe 未输出）")
                else
                    Notify.Error("×", "响应异常: " SubStr(status (detail != "" ? "|" detail : ""), 1, 40))
                return true
        }
    }

    static MarkSuccess() {
        ; 只在真正切成功后才防抖；失败允许立刻再按，避免 12s 空等后还要再等 700ms。
        this.LastTick := A_TickCount
    }

    static Toggle(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        exe := this.ExePath()
        if !FileExist(exe) {
            Notify.Error("×", "音频切换组件未找到")
            return
        }

        ; 互斥 / 防抖不再静默丢键：正在切换或刚成功时给出提示。
        if (this.Busy) {
            Notify.Info("⏳", "音频切换正在进行")
            return
        }
        if (this.LastTick && (A_TickCount - this.LastTick < this.DebounceMs)) {
            Notify.Info("⏳", "音频切换正在进行")
            return
        }

        this.Busy := true
        startTick := A_TickCount
        ; 先出 HUD，再异步等 exe，避免 12s 空等看起来像“没反应”。
        Notify.Info("⏳", "正在检查音频设备…", 3000)
        try {
            phase := this.StartToggleJob(this.BuildToggleCommand(exe, false), this.ChildTimeoutMs)
        } catch as err {
            this.Finish("音频切换失败: " err.Message)
            return
        }
        this.Task := { startTick: startTick, phase: phase, exe: exe, elevated: false, hudBumped: false }
        this.Job := phase.job
        this.EnsurePoll()
    }

    static GetDeviceIcon(name) {
        if RegExMatch(name, "i)(耳机|headphone|earphone|airpod|buds|headset)")
            return "🎧"
        return "🔊"
    }
}

AudioSwitcher.HotkeyCallback := ObjBindMethod(AudioSwitcher, "Toggle")
