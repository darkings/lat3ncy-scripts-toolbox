#Requires AutoHotkey v2.0

class ForegroundProcess {
    static Busy := false
    static LastTick := 0
    ; 动作防抖保持 700ms：Busy 挡住进行中的操作，冷却只约束操作结束后的连按。
    static DebounceMs := 700
    static ExitWaitSeconds := 3

    static ProtectedNames := Map(
        "applicationframehost.exe", true,
        "csrss.exe", true,
        "ctfmon.exe", true,
        "dwm.exe", true,
        "fontdrvhost.exe", true,
        "lsass.exe", true,
        "registry", true,
        "runtimebroker.exe", true,
        "searchapp.exe", true,
        "searchhost.exe", true,
        "secure system", true,
        "services.exe", true,
        "shellexperiencehost.exe", true,
        "sihost.exe", true,
        "smss.exe", true,
        "startmenuexperiencehost.exe", true,
        "svchost.exe", true,
        "system", true,
        "taskhostw.exe", true,
        "textinputhost.exe", true,
        "wininit.exe", true,
        "winlogon.exe", true
    )

    static IsProtected(processName, action) {
        name := StrLower(Trim(processName))
        if (name = "")
            return true
        if this.ProtectedNames.Has(name)
            return true
        ; explorer 由 Caps+Q 转给 Caps+R，不再当作“禁止操作”的保护项。
        return false
    }

    static IsExplorer(processName) {
        return StrLower(Trim(processName)) = "explorer.exe"
    }

    static IsOwnProcess(pid) {
        return pid = ProcessExist()
    }

    static DisplayName(processName) {
        name := Trim(processName)
        if RegExMatch(name, "i)\.exe$")
            return SubStr(name, 1, -4)
        return name = "" ? "未知进程" : name
    }

    static QuotePath(path) {
        path := Trim(path)
        if (path = "")
            return ""
        if (SubStr(path, 1, 1) = '"' && SubStr(path, -1) = '"')
            return path
        return '"' path '"'
    }

    static PreferredLaunchCommand(path, commandLine) {
        commandLine := Trim(commandLine)
        if (commandLine != "")
            return commandLine
        return this.QuotePath(path)
    }

    static QueryWmi(pid) {
        info := {commandLine: "", path: ""}
        try {
            query := "SELECT CommandLine, ExecutablePath FROM Win32_Process WHERE ProcessId=" pid
            for proc in ComObjGet("winmgmts:").ExecQuery(query) {
                try info.commandLine := Trim(proc.CommandLine)
                try info.path := Trim(proc.ExecutablePath)
                break
            }
        } catch {
        }
        return info
    }

    static Inspect() {
        hwnd := WinExist("A")
        if !hwnd
            return {ok: false, reason: "无前台窗口"}

        try {
            pid := WinGetPID("ahk_id " hwnd)
            name := WinGetProcessName("ahk_id " hwnd)
        } catch {
            return {ok: false, reason: "无法读取前台进程"}
        }

        if !pid
            return {ok: false, reason: "无法读取前台进程"}

        if this.IsOwnProcess(pid)
            return {ok: false, reason: "不能操作工具箱自身"}

        path := ""
        try path := WinGetProcessPath("ahk_id " hwnd)

        wmi := this.QueryWmi(pid)
        if (path = "" && wmi.path != "")
            path := wmi.path

        return {
            ok: true,
            hwnd: hwnd,
            pid: pid,
            name: name,
            path: path,
            commandLine: wmi.commandLine
        }
    }

    static BeginAction() {
        if this.Busy
            return false
        ; 冷却从上次动作结束算起，避免重启 explorer 期间连按再杀一遍。
        if (this.LastTick && A_TickCount - this.LastTick < this.DebounceMs)
            return false
        this.Busy := true
        return true
    }

    static EndAction() {
        this.LastTick := A_TickCount
        this.Busy := false
    }

    static WaitClosed(pid, timeoutSeconds := unset) {
        if !IsSet(timeoutSeconds)
            timeoutSeconds := this.ExitWaitSeconds
        if !ProcessExist(pid)
            return true
        return ProcessWaitClose(pid, timeoutSeconds)
    }

    static ClosePid(pid) {
        try ProcessClose pid
        catch {
            return false
        }
        return this.WaitClosed(pid)
    }

    static CloseByName(processName, timeoutSeconds := unset) {
        if !IsSet(timeoutSeconds)
            timeoutSeconds := this.ExitWaitSeconds
        deadline := A_TickCount + Round(timeoutSeconds * 1000)
        while (pid := ProcessExist(processName)) {
            if (A_TickCount >= deadline)
                return false
            try ProcessClose pid
            if !this.WaitClosed(pid, 0.4)
                Sleep 50
        }
        return !ProcessExist(processName)
    }

    static RestartExplorer() {
        if !this.CloseByName("explorer.exe") {
            Notify.Error("×", "结束资源管理器超时")
            return
        }
        try {
            Run A_WinDir "\explorer.exe"
            Notify.Success("↻", "已重启资源管理器")
        } catch {
            Notify.Error("×", "启动资源管理器失败")
        }
    }

    static Kill(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        ; 资源管理器上的 Caps+Q 就是 Caps+R：在占 Busy 之前直接复用同一入口。
        try {
            hwnd := WinExist("A")
            if hwnd && this.IsExplorer(WinGetProcessName("ahk_id " hwnd))
                return this.Restart(_hotkeyName)
        } catch {
        }

        if !this.BeginAction()
            return

        try {
            info := this.Inspect()
            if !info.ok {
                Notify.Error("!", info.reason)
                return
            }

            ; 兜底：识别阶段没拦住 explorer 时，本轮已占 Busy，直接走 Caps+R 的专用重启。
            if this.IsExplorer(info.name) {
                this.RestartExplorer()
                return
            }

            if this.IsProtected(info.name, "kill") {
                Notify.Error("!", "已保护: " this.DisplayName(info.name))
                return
            }

            if !this.ClosePid(info.pid) {
                Notify.Error("×", "无法结束: " this.DisplayName(info.name))
                return
            }

            Notify.Success("⏹", "已结束: " this.DisplayName(info.name))
        } catch as err {
            Notify.Error("×", "结束进程失败: " err.Message)
        } finally {
            this.EndAction()
        }
    }

    static Restart(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        if !this.BeginAction()
            return

        try {
            info := this.Inspect()
            if !info.ok {
                Notify.Error("!", info.reason)
                return
            }

            if this.IsProtected(info.name, "restart") {
                Notify.Error("!", "已保护: " this.DisplayName(info.name))
                return
            }

            if this.IsExplorer(info.name) {
                this.RestartExplorer()
                return
            }

            launch := this.PreferredLaunchCommand(info.path, info.commandLine)
            if (launch = "") {
                Notify.Error("!", "无法获取启动命令")
                return
            }

            if !this.ClosePid(info.pid) {
                Notify.Error("×", "无法结束: " this.DisplayName(info.name))
                return
            }

            try {
                Run launch
                Notify.Success("↻", "已重启: " this.DisplayName(info.name))
            } catch {
                Notify.Error("×", "重新启动失败: " this.DisplayName(info.name))
            }
        } catch as err {
            Notify.Error("×", "重启进程失败: " err.Message)
        } finally {
            this.EndAction()
        }
    }

}

ForegroundProcess.KillCallback := ObjBindMethod(ForegroundProcess, "Kill")
ForegroundProcess.RestartCallback := ObjBindMethod(ForegroundProcess, "Restart")
