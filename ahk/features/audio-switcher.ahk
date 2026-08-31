#Requires AutoHotkey v2.0
#Include ..\..\shared\notify\run-nowindow.ahk

class AudioSwitcher {
    static Busy := false
    static LastTick := 0
    static DebounceMs := 700
    ; 必须大于 C# connect_wait_ms(12s) + 蓝牙枚举余量，避免父进程先杀子进程。
    ; 自动提权重试会共用这一份总预算，不会再叠一个完整 18s。
    static ChildTimeoutMs := 18000

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

    static RunToggle(exe, timeoutMs, stdoutFile) {
        try {
            try FileDelete stdoutFile
            try {
                ProcessNoWindow.RunWait('"' exe '" --toggle', stdoutFile, timeoutMs)
            } catch as runErr {
                if InStr(runErr.Message, "无法创建输出文件") {
                    ; 保底：不带输出文件直接执行切换，至少完成 SetDefault。
                    ProcessNoWindow.RunWait('"' exe '" --toggle', "", timeoutMs)
                    Notify.Success("🔊", "已执行切换（无输出文件）")
                    return { status: "SWITCHED", detail: "无输出文件", handled: true }
                }
                throw runErr
            }
            output := ""
            try output := Trim(FileRead(stdoutFile, "UTF-8"))
            return this.ParseProtocol(output)
        } finally {
            try FileDelete stdoutFile
        }
    }

    static ResolveSudo() {
        sudoExe := "C:\Windows\System32\sudo.exe"
        if FileExist(sudoExe)
            return sudoExe
        if FileExist("gsudo.exe")
            return "gsudo.exe"
        return ""
    }

    static RunToggleElevated(exe, timeoutMs) {
        useSudo := this.ResolveSudo()
        if (useSudo = "")
            return { status: "", detail: "", handled: false, ran: false }
        tempSudo := A_Temp "\lat3ncy-audio-switcher-sudo-" A_TickCount "-" Random(1000, 9999) ".txt"
        try {
            if InStr(useSudo, "sudo.exe")
                cmdSudo := useSudo " --inline `"" exe "`" --toggle"
            else if InStr(useSudo, "gsudo")
                cmdSudo := useSudo " --wait `"" exe "`" --toggle"
            else
                cmdSudo := useSudo " `"" exe "`" --toggle"
            result := this.RunToggleCommand(cmdSudo, timeoutMs, tempSudo)
            result.ran := true
            return result
        } finally {
            try FileDelete tempSudo
        }
    }

    static RunToggleCommand(command, timeoutMs, stdoutFile) {
        try {
            try FileDelete stdoutFile
            ProcessNoWindow.RunWait(command, stdoutFile, timeoutMs)
            output := ""
            try output := Trim(FileRead(stdoutFile, "UTF-8"))
            parsed := this.ParseProtocol(output)
            parsed.ran := true
            return parsed
        } finally {
            try FileDelete stdoutFile
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

        try {
            ; 先出 HUD，再同步等 exe，避免 12s 空等看起来像“没反应”。
            ; 先出 HUD 再等 exe。默认 info 只有 750ms，拉长以免真等待时提示先消失。
            Notify.Info("⏳", "正在检查音频设备…", 3000)
            try FileDelete A_Temp "\lat3ncy-audio-switcher.txt"
            tempFile := A_Temp "\lat3ncy-audio-switcher-" A_TickCount "-" Random(1000, 9999) ".txt"
            result := this.RunToggle(exe, this.ChildTimeoutMs, tempFile)
            if result.handled {
                this.MarkSuccess()
                return
            }

            if (result.status = "ERROR" && this.ShouldAutoElevate(result.detail)) {
                try {
                    Notify.Info("⏳", "权限错误，尝试提权重试…")
                    elevated := this.RunToggleElevated(exe, this.RemainingTimeout(startTick))
                    if elevated.ran {
                        if this.ApplyProtocol(elevated.status, elevated.detail, "已切换(提权)") {
                            if (elevated.status = "SWITCHED" || elevated.status = "ONLY_ONE")
                                this.MarkSuccess()
                            return
                        }
                        Notify.Error("×", elevated.detail != "" ? elevated.detail : "音频切换失败(提权)")
                        return
                    }
                } catch as sudoErr {
                    ; 提权失败忽略，走原错误
                }
            }

            if this.ApplyProtocol(result.status, result.detail) {
                if (result.status = "SWITCHED" || result.status = "ONLY_ONE")
                    this.MarkSuccess()
                return
            }
            Notify.Error("×", result.detail != "" ? result.detail : "音频切换失败")
        } catch as err {
            Notify.Error("×", "音频切换失败: " err.Message)
        } finally {
            this.Busy := false
        }
    }

    static GetDeviceIcon(name) {
        if RegExMatch(name, "i)(耳机|headphone|earphone|airpod|buds|headset)")
            return "🎧"
        return "🔊"
    }
}

AudioSwitcher.HotkeyCallback := ObjBindMethod(AudioSwitcher, "Toggle")
