#Requires AutoHotkey v2.0
#Include ..\..\shared\notify\run-nowindow.ahk

class AudioSwitcher {
    static Busy := false
    static LastTick := 0
    static DebounceMs := 700

    static ExePath() {
        SplitPath A_LineFile, , &featuresDir
        SplitPath featuresDir, , &ahkDir
        SplitPath ahkDir, , &repoDir
        return repoDir "\tools\audio-switcher\audio-switcher.exe"
    }

    static Toggle(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        exe := this.ExePath()
        if !FileExist(exe) {
            Notify.Error("×", "音频切换组件未找到")
            return
        }

        ; 防抖 + 互斥：RunWait 期间忽略重入，700ms 内连按忽略
        if (this.Busy)
            return
        if (A_TickCount - this.LastTick < this.DebounceMs)
            return
        this.Busy := true
        this.LastTick := A_TickCount

        try {
            ; 使用唯一文件名避免并发或旧句柄占用导致 CreateFileW 被拒绝
            tempFile := A_Temp "\lat3ncy-audio-switcher-" A_TickCount "-" Random(1000,9999) ".txt"
            ; 清理可能的旧固定名残留
            try FileDelete A_Temp "\lat3ncy-audio-switcher.txt"
            try FileDelete tempFile
            try {
                ProcessNoWindow.RunWait('"' exe '" --toggle', tempFile)
            } catch as runErr {
                if InStr(runErr.Message, "无法创建输出文件") {
                    ; 保底：不带输出文件直接执行切换，至少完成 SetDefault
                    try {
                        ProcessNoWindow.RunWait('"' exe '" --toggle', "")
                        Notify.Success("🔊", "已执行切换（无输出文件）")
                    } catch as fallbackErr {
                        throw Error("输出文件创建失败且 fallback 失败: " runErr.Message " / " fallbackErr.Message)
                    }
                    return
                }
                throw runErr
            }
            output := ""
            try output := Trim(FileRead(tempFile, "UTF-8"))
            try FileDelete tempFile

            parts := StrSplit(output, "|", , 2)
            status := parts.Length > 0 ? parts[1] : ""
            detail := parts.Length > 1 ? parts[2] : ""

            switch status {
                case "SWITCHED":
                    icon := this.GetDeviceIcon(detail)
                    Notify.Success(icon, "已切换: " detail)
                case "ONLY_ONE":
                    icon := this.GetDeviceIcon(detail)
                    Notify.Info(icon, "当前唯一设备: " detail)
                case "NO_DEVICE":
                    Notify.Error("!", "无可用音频播放设备")
                case "ERROR":
                    ; 耳机未连上 / 不在范围时，exe 返回「耳机未就绪」→ 尝试 sudo 提权重连
                    if (detail == "耳机未就绪") {
                        try {
                            sudoExe := "C:\Windows\System32\sudo.exe"
                            gsudoExe := "gsudo.exe"
                            useSudo := FileExist(sudoExe) ? sudoExe : ""
                            if (useSudo == "" && FileExist(gsudoExe))
                                useSudo := gsudoExe
                            if (useSudo != "") {
                                Notify.Info("⏳", "尝试提权连接耳机…")
                                tempSudo := A_Temp "\lat3ncy-audio-switcher-sudo-" A_TickCount "-" Random(1000,9999) ".txt"
                                try FileDelete tempSudo
                                ; sudo --inline / gsudo --wait 均在当前窗口等待并弹 UAC，适合热键
                                if InStr(useSudo, "sudo.exe")
                                    cmdSudo := useSudo " --inline `"" exe "`" --toggle"
                                else if InStr(useSudo, "gsudo")
                                    cmdSudo := useSudo " --wait `"" exe "`" --toggle"
                                else
                                    cmdSudo := useSudo " `"" exe "`" --toggle"
                                ProcessNoWindow.RunWait(cmdSudo, tempSudo)
                                output2 := ""
                                try output2 := Trim(FileRead(tempSudo, "UTF-8"))
                                try FileDelete tempSudo
                                parts2 := StrSplit(output2, "|", , 2)
                                status2 := parts2.Length > 0 ? parts2[1] : ""
                                detail2 := parts2.Length > 1 ? parts2[2] : ""
                                if (status2 == "SWITCHED") {
                                    icon2 := this.GetDeviceIcon(detail2)
                                    Notify.Success(icon2, "已切换(提权): " detail2)
                                    return
                                } else if (status2 == "ONLY_ONE" || status2 == "SWITCHED") {
                                    icon2 := this.GetDeviceIcon(detail2)
                                    Notify.Info(icon2, detail2)
                                    return
                                } else if (output2 != "") {
                                    ; 提权后仍失败，透出提权后的错误
                                    Notify.Error("×", detail2 != "" ? detail2 : "音频切换失败(提权)")
                                    return
                                }
                            }
                        } catch as sudoErr {
                            ; 提权失败忽略，走原错误
                        }
                    }
                    Notify.Error("×", detail != "" ? detail : "音频切换失败")
                default:
                    if (output = "")
                        Notify.Error("×", "无响应（exe 未输出）")
                    else
                        Notify.Error("×", "响应异常: " SubStr(output, 1, 40))
            }
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
