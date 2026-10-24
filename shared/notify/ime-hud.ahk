#Requires AutoHotkey v2.0
#Include anchor.ahk
#Include paths.ahk
#Include run-nowindow.ahk

; 输入法状态 HUD。只交给常驻 WinUI 进程。
; 发送失败不再由调用方叠一层 GDI 芯片，避免 AA / 中中。
;
; 锚点分两条路：
;   1. 进程内 Win32 caret（InputAnchor.TryCaret）：快，但只对传统 Win32 控件有效。
;   2. shared/notify/anchor-locator.exe：TSF/UIA 文本光标 + IMM + 兜底，并且每条结果都带来源。
; 拿到退化来源（focus-*/window-bottom/monitor-fallback）时不再沉默：
;   - LastAnchorSource / LastAnchorReal 记录真实来源，日志写 anchor-source；
;   - 只有真的拿到光标才启动跟随进程（FollowAnchor）。
class ImeHud {
    static WindowClass := "Lat3ncyImeHudWinUi"
    static WindowTitle := "Lat3ncyImeHudWinUi"
    static ProcessName := "ImeHudWinUi.exe"
    static CopyDataId := 1
    static MessageTimeout := 600
    static LaunchWaitMs := 2500
    ; 单次 SendMessageTimeout 失败不立刻杀进程：HUD 刚冷启动时窗口已建但消息循环
    ; 还没开始泵，这时超时是暂时的。短超时 + 多试几次比 2.5s 一次要快得多。
    static SendAttempts := 3
    static SendRetryDelayMs := 80
    ; 文本光标探测预算。偏小会让 Chromium 直接落到退化来源，偏大会拖慢芯片出现。
    static LocatorTimeoutMs := 500
    ; true 时芯片显示期间跟随光标（额外起一个短命 anchor-locator --watch）。
    ; 退化锚点也起：Chromium 的无障碍树延迟建立，反复探测可能升级成真光标。
    static FollowEnabled := true
    static FollowDurationMs := 1250
    static FollowIntervalMs := 160
    static FollowTickMs := 60
    static LastCommand := ""
    static LastTargetHwnd := 0
    static LastError := ""
    ; 锚点来源与“是否真实光标”，供调用方和日志观测。
    static LastAnchorSource := ""
    static LastAnchorReal := false
    static LastAnchorX := 0
    static LastAnchorY := 0
    static BuildTag := "anchor-source-1"
    static _deployLogged := false

    static Show(state, targetHwnd := 0) {
        this.LogDeployOnce()
        state := this.NormalizeState(state)
        if (state = "")
            return false
        targetHwnd := InputAnchor.NormalizeHwnd(targetHwnd)
        if !targetHwnd
            targetHwnd := WinExist("A")
        this.LastTargetHwnd := targetHwnd

        this.StopFollow()
        ; 常驻助手优先：Chromium 系只有它能拿到真插入点，而且读文件没有冷启动延迟。
        this.EnsureCaretServer()
        served := this.ReadCaretServer()
        if !served.Known {
            ; 助手还没写过（开机/重启后第一次）：短暂等一行，通常 <=180ms 就有。
            served := this.WaitCaretServer()
        }
        if served.Ok {
            anchor := { X: served.X, Y: served.Y, Source: served.Source, DurationMs: 0 }
        } else {
            ; 助手明确回答"当前没有插入点"（Known 且非 Ok）时跳过 locator：
            ; 调外部定位器要 500ms，而这个场景它也给不出光标。
            ; 只有"完全没有答案"时才值得去问。
            anchor := this.LocateAnchor(targetHwnd, served.Known)
        }
        this.LastAnchorSource := anchor.Source
        this.LastAnchorReal := InputAnchor.IsRealCaretSource(anchor.Source)
        this.LastAnchorX := anchor.X
        this.LastAnchorY := anchor.Y
        sent := this.Send(this.BuildStateCommand(
            state,
            anchor.X,
            anchor.Y,
            0,
            anchor.DurationMs,
            this.LastTargetHwnd,
            anchor.Source
        ))
        ; 部署自检：这行只在生产 main.ahk 里写。
        ; 日志里没有它，就说明 AHK 还在跑旧代码（没重载），不是 HUD 的问题。
        this.Log(Format(
            "anchor state={1} source={2} real={3} x={4} y={5} target={6} sent={7}",
            state,
            anchor.Source,
            this.LastAnchorReal ? 1 : 0,
            anchor.X,
            anchor.Y,
            this.LastTargetHwnd,
            sent ? 1 : 0
        ))
        ; 助手已经给出真光标时位置就是对的，不必再起跟随；
        ; 退化锚点才需要跟随/升级兜底。
        if (sent && !this.LastAnchorReal) {
            if !this.StartCaretHelper(state, this.LastTargetHwnd)
                this.FollowAnchor(state, this.LastTargetHwnd)
        }
        return sent
    }

    ; 锚点解析。先进程内 Win32 caret，拿不到再交给 locator。
    ; locator 返回 ERR / 超时 / 文件缺失时退回窗口底部，并把来源标成退化来源。
    ; skipLocator=true 时不调外部定位器（省 500ms）：
    ; 调用方已知当前焦点没有插入点，定位器在这个场景也给不出光标。
    static LocateAnchor(targetHwnd, skipLocator := false) {
        x := 0
        y := 0
        source := ""
        if InputAnchor.TryCaret(&x, &y, targetHwnd) {
            source := InputAnchor.LastSource
            if (source = "")
                source := "win32-caret"
            return { X: x, Y: y, Source: source, DurationMs: 0 }
        }

        probe := { Found: false, RealCaret: false, X: 0, Y: 0, Source: "", Reason: "skipped-locator" }
        if !skipLocator {
            probe := this.ProbeLocator(targetHwnd)
            if probe.Found {
                ; locator 给出真光标就用；退化锚点也接受，但来源如实标记。
                return { X: probe.X, Y: probe.Y, Source: probe.Source, DurationMs: 0 }
            }
        }

        rootHwnd := InputAnchor.GetRootHwnd(targetHwnd)
        if !rootHwnd
            rootHwnd := targetHwnd
        InputAnchor.LastTargetHwnd := rootHwnd
        this.LastTargetHwnd := rootHwnd

        if InputAnchor.TryWindowBottom(&x, &y, rootHwnd)
            return { X: x, Y: y, Source: "target-window-bottom", DurationMs: 0, Reason: probe.Reason }
        if InputAnchor.TryMonitorFallback(&x, &y, rootHwnd)
            return { X: x, Y: y, Source: "target-monitor-fallback", DurationMs: 0, Reason: probe.Reason }
        return { X: 0, Y: 0, Source: "anchor-failed", DurationMs: 0, Reason: probe.Reason }
    }

    ; 一次性调用 locator。--ar 让输出带结构化来源。
    ; extraArgs 只给测试注入故障场景用，生产调用不要传。
    static ProbeLocator(targetHwnd, extraArgs := "") {
        result := { Found: false, RealCaret: false, X: 0, Y: 0, Source: "", Reason: "" }
        exe := NotifyPaths.LocatorExe()
        if (exe = "" || !FileExist(exe)) {
            result.Reason := "missing-locator"
            return result
        }

        command := Format('"{1}" --ar', exe)
        if targetHwnd
            command .= " --hwnd " targetHwnd
        if (extraArgs != "")
            command .= " " extraArgs
        outputFile := A_Temp "\lat3ncy-anchor-" A_TickCount "-" Random(1000, 9999) ".txt"
        output := ""
        exitCode := 1
        try {
            exitCode := ProcessNoWindow.RunWait(command, outputFile, this.LocatorTimeoutMs)
            output := FileExist(outputFile) ? FileRead(outputFile, "UTF-8") : ""
        } catch {
            result.Reason := "locator-timeout"
            return result
        } finally {
            if FileExist(outputFile)
                try FileDelete(outputFile)
        }

        if (exitCode != 0) {
            result.Reason := "locator-exit-" exitCode
            return result
        }
        if !RegExMatch(Trim(output), "OK\|(-?\d+)\|(-?\d+)\|(-?\d+)\|(-?\d+)\|([A-Za-z0-9_-]+)\|(-?\d+)", &match) {
            result.Reason := "locator-bad-output"
            return result
        }

        result.Found := true
        result.X := Integer(match[1])
        result.Y := Integer(match[2])
        result.Source := match[5]
        result.RealCaret := InputAnchor.IsRealCaretSource(result.Source)
        return result
    }

    static Hide() {
        this.StopFollow()
        return this.Send("HIDE")
    }

    static Stop() {
        this.StopFollow()
        return this.Send("QUIT")
    }

    static BuildStateCommand(state, x := 0, y := 0, dpi := 0, durationMs := 0, targetHwnd := 0, source := "") {
        state := this.NormalizeState(state)
        if (state = "")
            return ""
        command := Format("STATE|{1}|{2}|{3}|{4}|{5}", state, Integer(x), Integer(y), Integer(dpi), Integer(durationMs))
        targetHwnd := InputAnchor.NormalizeHwnd(targetHwnd)
        ; 第 7 段：目标窗口。第 8 段：锚点来源。
        ; 没有 hwnd 但要有 source 时保留空段，否则 source 会被解析成第 7 段。
        if targetHwnd
            command .= "|" targetHwnd
        else if (source != "")
            command .= "|"
        if (source != "")
            command .= "|" this.NormalizeSource(source)
        return command
    }

    static NormalizeSource(source) {
        source := Trim(String(source))
        if (source = "")
            return "unknown"
        ; 段分隔符会破坏协议，只保留安全字符。
        return RegExReplace(source, "[^A-Za-z0-9_-]", "")
    }

    static NormalizeState(state) {
        state := StrUpper(Trim(String(state)))
        if (state = "CN" || state = "ZH" || state = "CH" || state = "中")
            return "CN"
        if (state = "EN" || state = "ENG" || state = "英")
            return "EN"
        if (state = "CAPS" || state = "CAP" || state = "CAPSLOCK")
            return "CAPS"
        return ""
    }

    ; ================= 跟随光标 =================

    ; 跟随光标。
    ; 真光标时立刻跟随；退化锚点（focus-bounds / window-bottom）也起，
    ; 因为 Chromium 的无障碍树是延迟建的：跟随循环里的反复探测可能自己
    ; 升级成 text-caret，一旦升级成功，后续 MOVE 就会把芯片挪到真光标。
    static FollowAnchor(state, targetHwnd) {
        if !this.FollowEnabled
            return false
        if !targetHwnd
            return false

        this.StopFollow()
        exe := NotifyPaths.LocatorExe()
        if (exe = "" || !FileExist(exe))
            return false

        outputFile := A_Temp "\lat3ncy-follow-" DllCall("GetCurrentProcessId") ".txt"
        command := Format(
            '"{1}" --ar --watch --hwnd {2} --interval {3} --duration {4}',
            exe,
            targetHwnd,
            this.FollowIntervalMs,
            this.FollowDurationMs
        )
        pid := 0
        try {
            pid := ProcessNoWindow.Run(command, false, outputFile)
        } catch {
            return false
        }
        if !pid
            return false

        ; 退化锚点也起跟随：Chromium 的无障碍树延迟建立，
        ; 循环里的反复探测可能升级成真光标（HandleFollowLine 会记 follow-upgraded）。
        this.Log(Format(
            "follow-start anchor={1} real={2} target={3} pid={4}",
            this.LastAnchorSource,
            this.LastAnchorReal ? 1 : 0,
            targetHwnd,
            pid
        ))
        this._followPid := pid
        this._followState := state
        this._followTarget := targetHwnd
        this._followFile := outputFile
        this._followOffset := 0
        this._followSeen := 0
        this._followUpgraded := false
        this._followDeadline := A_TickCount + this.FollowDurationMs + 250
        SetTimer this.FollowTickCallback, this.FollowTickMs
        return true
    }

    ; ================= Chromium 系光标：PowerShell 常驻助手 =================

    ; 实测结论：Chromium 只为「被认可的辅助技术客户端」建内容树，
    ; 在本机只有 PowerShell 宿主能拿到真正的插入点（同一个 UIAutomationClient
    ; 在普通 .NET exe / AHK 里只看到两个 Pane）；
    ; 而且每次都新起 PowerShell 太慢（冷启动 ~0.8s，芯片 750ms 就隐藏了，
    ; MOVE 到达时已经不可见）。所以起一个常驻助手，按键时直接读它写的文件。
    ; 助手进程寿命。原来是 15 分钟：过期后第一次按键要等它重启 + 建无障碍树
    ; （实测 859ms）。改成 12 小时后，一个登录会话里几乎不会再冷启动；
    ; 即使它意外退出，HealthTick 每 20 秒会把它拉回来。
    static CaretServerMs := 43200000
    ; 新鲜窗口必须大于助手的发布间隔。助手在"当前无光标"时一轮要几十~几百毫秒，
    ; 窗口定太小会一直被判定为"没有答案"，于是每次按键都白等 + 白调 locator。
    static CaretFreshMs := 700

    static CaretHelperPath() {
        return NotifyPaths.Resolve("caret-uia.ps1")
    }

    static CaretServerFile() {
        return A_Temp "\lat3ncy-uia-serve-" DllCall("GetCurrentProcessId") ".txt"
    }

    static EnsureCaretServer() {
        if this._caretServerPid {
            if ProcessExist(this._caretServerPid)
                return true
            this._caretServerPid := 0
        }
        helper := this.CaretHelperPath()
        if (helper = "" || !FileExist(helper))
            return false

        outputFile := this.CaretServerFile()
        try FileDelete(outputFile)
        ; stdout 必须重定向到另一个文件：Run 的 stdoutFile 会被子进程一直持有，
        ; 用它当数据文件的话，AHK 这边读这个文件会拿到"被占用"。
        stdoutFile := A_Temp "\lat3ncy-uia-serve-stdout-" DllCall("GetCurrentProcessId") ".txt"
        try FileDelete(stdoutFile)
        command := Format(
            'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -Serve -Hwnd 0 -OutPath "{2}" -ServeMs {3} -IntervalMs {4} -Attempts 1 -DelayMs 60',
            helper,
            outputFile,
            this.CaretServerMs,
            this.CaretServerIntervalMs
        )
        pid := 0
        try {
            pid := ProcessNoWindow.Run(command, false, stdoutFile)
        } catch as err {
            this.Log("caret-server-launch-failed " err.Message)
            return false
        }
        if !pid
            return false

        this._caretServerPid := pid
        this._caretServerFile := outputFile
        this.Log(Format("caret-server-start pid={1} out={2}", pid, outputFile))
        return true
    }

    ; 读常驻助手写的文件。返回 {Ok, X, Y, Source, AgeMs}。
    static ReadCaretServer() {
        ; Known = 助手在新鲜窗口内给过明确答案（有光标 或 明确没有光标）。
        result := { Ok: false, Known: false, X: 0, Y: 0, Source: "", AgeMs: 999999 }
        file := this._caretServerFile != "" ? this._caretServerFile : this.CaretServerFile()
        if !FileExist(file)
            return result

        text := ""
        try {
            text := FileRead(file, "UTF-8")
        } catch {
            return result
        }
        ; 行格式：T|<ahk-tick>|CARET|x|y|h|source  或  T|<ahk-tick>|NOCARET|reason
        ; 用 AHK 自己的 A_TickCount 判新鲜度，避免 unix 时间换算。
        if RegExMatch(text, "T\|(\d+)\|CARET\|(-?\d+)\|(-?\d+)\|(-?\d+)\|([A-Za-z0-9_-]+)", &match) {
            age := A_TickCount - Integer(match[1])
            if (age < 0)
                age := 0
            result.AgeMs := age
            if (age > this.CaretFreshMs)
                return result
            result.Known := true
            result.X := Integer(match[2])
            result.Y := Integer(match[3])
            result.Source := match[5]
            result.Ok := InputAnchor.IsRealCaretSource(result.Source)
            return result
        }
        if RegExMatch(text, "T\|(\d+)\|NOCARET\|([A-Za-z0-9_-]+)", &miss) {
            age := A_TickCount - Integer(miss[1])
            if (age < 0)
                age := 0
            result.AgeMs := age
            if (age <= this.CaretFreshMs)
                result.Known := true
        }
        return result
    }

    static StartCaretHelper(state, targetHwnd) {
        if !this.FollowEnabled || !targetHwnd
            return false
        helper := this.CaretHelperPath()
        if (helper = "" || !FileExist(helper))
            return false

        outputFile := A_Temp "\lat3ncy-uia-" DllCall("GetCurrentProcessId") ".txt"
        command := Format(
            'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -Hwnd {2} -Watch -IntervalMs {3} -DurationMs {4}',
            helper,
            targetHwnd,
            this.FollowIntervalMs,
            this.FollowDurationMs
        )
        pid := 0
        try {
            pid := ProcessNoWindow.Run(command, false, outputFile)
        } catch {
            return false
        }
        if !pid
            return false

        this.Log(Format(
            "uia-helper-start anchor={1} target={2} pid={3}",
            this.LastAnchorSource,
            targetHwnd,
            pid
        ))
        this._followPid := pid
        this._followState := state
        this._followTarget := targetHwnd
        this._followFile := outputFile
        this._followOffset := 0
        this._followSeen := 0
        this._followUpgraded := false
        this._followDeadline := A_TickCount + this.FollowDurationMs + 400
        SetTimer this.FollowTickCallback, this.FollowTickMs
        return true
    }

    static FollowTick() {
        pid := this._followPid
        if !pid {
            this.StopFollow()
            return
        }

        file := this._followFile
        if FileExist(file) {
            text := ""
            try {
                text := FileRead(file, "UTF-8")
            } catch {
                text := ""
            }
            if (StrLen(text) > this._followOffset) {
                chunk := SubStr(text, this._followOffset + 1)
                this._followOffset := StrLen(text)
                for line in StrSplit(chunk, "`n", "`r") {
                    if !this.HandleFollowLine(Trim(line))
                        return
                }
            }
        }

        if !ProcessExist(pid) {
            this.StopFollow()
            return
        }
        if (A_TickCount > this._followDeadline)
            this.StopFollow()
    }

    ; 返回 false 表示要停止跟随。
    ; 同时接受两种行：locator 的 A|x|y|h|source 和助手脚本的 CARET|x|y|h|source。
    static HandleFollowLine(line) {
        if (line = "")
            return true
        if RegExMatch(line, "^(?:A|CARET)\|(-?\d+)\|(-?\d+)\|(-?\d+)\|([A-Za-z0-9_-]+)$", &match) {
            if !InputAnchor.IsRealCaretSource(match[4])
                return true
            this._followSeen += 1
            ; 从退化锚点升级到真光标：记一笔，日志里能看出这次升级。
            if !this._followUpgraded {
                this._followUpgraded := true
                this.Log(Format(
                    "follow-upgraded source={1} from={2} x={3} y={4}",
                    match[4],
                    this.LastAnchorSource,
                    Integer(match[1]),
                    Integer(match[2])
                ))
            }
            this.Send(Format(
                "MOVE|{1}|{2}|{3}|0|0|{4}|{5}",
                this._followState,
                Integer(match[1]),
                Integer(match[2]),
                this._followTarget,
                match[4]
            ))
            return true
        }
        if RegExMatch(line, "^L\|") {
            this.StopFollow()
            return false
        }
        if RegExMatch(line, "^E\|") {
            this.StopFollow()
            return false
        }
        return true
    }

    static StopFollow() {
        pid := this._followPid
        this._followPid := 0
        try SetTimer this.FollowTickCallback, 0
        if pid {
            ; 进程可能已经自己退出了，ProcessClose 会抛，忽略即可。
            try ProcessClose(pid)
        }
        file := this._followFile
        this._followFile := ""
        this._followOffset := 0
        if (file != "" && FileExist(file))
            try FileDelete(file)
        return pid
    }

    ; ================= 与 WinUI 通信 =================

    ; 生产恒为 false。测试可临时设 true，隔离 WinUI（不启动 exe、不发 WM_COPYDATA），
    ; 直接校验锚点解析、来源标记、命令拼装和跟随循环。
    static DisableSend := false

    static Send(command) {
        this.LastCommand := command
        this.LastError := ""
        if (command = "") {
            this.LastError := "empty-command"
            return false
        }
        if (this.DisableSend)
            return true
        if !this.EnsureRunning()
            return false
        hwnd := this.FindWindow()
        if !hwnd {
            this.LastError := "no-hwnd"
            return false
        }
        ; 已知卡死就别再等 2.5 秒超时：直接换一个干净进程。
        if this.IsHung(hwnd) {
            this.Log("hud-hung pre-send hwnd=" hwnd)
            this.KillHudProcess(hwnd)
            hwnd := 0
            if !this.EnsureRunning()
                return false
            hwnd := this.FindWindow()
            if !hwnd {
                this.LastError := "no-hwnd-after-hung-restart"
                return false
            }
        }
        if this.SendCopyData(hwnd, command) {
            this.LastError := ""
            return true
        }
        ; HUD 可能正在冷启动（窗口已建、消息循环还没泵）：短超时多试几次，
        ; 比直接杀进程省掉一整次 WinUI 冷启动。
        loop (this.SendAttempts - 1) {
            Sleep this.SendRetryDelayMs
            if this.SendCopyData(hwnd, command) {
                this.LastError := ""
                return true
            }
        }
        ; 仍然失败：可能句柄失效，也可能进程已经卡死
        ; （WinUI 在锁屏/切显示器后偶发死锁）。
        ; 不能只 EnsureRunning(true)：它只会再次 FindWindow 找到同一个卡死窗口，
        ; 于是每一轮都超时，直到手动重启 AHK 才恢复。
        this.LastError := "copydata-failed"
        killed := this.KillHudProcess(hwnd)
        this.Log(Format("hud-restart reason=copydata-failed killed={1}", killed ? 1 : 0))
        if !this.EnsureRunning()
            return false
        hwnd := this.FindWindow()
        if !hwnd {
            this.LastError := "no-hwnd-after-restart"
            return false
        }
        if this.SendCopyData(hwnd, command) {
            this.LastError := ""
            return true
        }
        this.LastError := "copydata-failed-after-restart"
        this.Log("send-failed command=" command)
        return false
    }

    ; 窗口是否超过 5 秒没处理消息。卡死的 HUD 会一直保留窗口句柄，
    ; 但 SendMessageTimeout 全部超时，表现就是"切换没有通知"。
    static IsHung(hwnd) {
        if !hwnd
            return false
        try {
            return DllCall("User32\IsHungAppWindow", "Ptr", hwnd, "Int") ? true : false
        } catch {
            return false
        }
    }

    ; 结束拥有该窗口的进程。返回 true 表示进程确实退出了。
    static KillHudProcess(hwnd) {
        pid := 0
        try {
            DllCall("User32\GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid, "UInt")
        } catch {
            return false
        }
        if !pid
            return false
        try {
            ProcessClose(pid)
        } catch {
            return false
        }
        deadline := A_TickCount + 2000
        while (A_TickCount < deadline) {
            if !ProcessExist(pid)
                return true
            Sleep 30
        }
        return !ProcessExist(pid)
    }

    ; 健康巡检：HUD 卡死就杀掉，下一次切换会冷启动一个干净的。
    static HealthIntervalMs := 20000

    static StartHealthWatch() {
        if this._healthTimer
            return
        this._healthTimer := true
        SetTimer this.HealthTickCallback, this.HealthIntervalMs
    }

    static HealthTick(*) {
        ; 助手必须常驻：它一冷启动，下一次按键就要多等它建树（实测 859ms）。
        this.EnsureCaretServer()

        hwnd := this.FindWindow()
        if !hwnd {
            ; HUD 不在就提前拉起，别让第一次 CapsLock 现启动（冷启动 2.5s+）。
            this.EnsureRunning()
            return
        }
        if !this.IsHung(hwnd)
            return
        this.Log("hud-hung health-kill hwnd=" hwnd)
        this.KillHudProcess(hwnd)
    }

    static SendCopyData(hwnd, command) {
        data := Buffer(StrPut(command, "UTF-16") * 2, 0)
        StrPut(command, data, "UTF-16")
        copy := Buffer(A_PtrSize = 8 ? 24 : 12, 0)
        NumPut("Ptr", this.CopyDataId, copy, 0)
        NumPut("UInt", data.Size, copy, A_PtrSize)
        NumPut("Ptr", data.Ptr, copy, A_PtrSize = 8 ? 16 : 8)
        result := 0
        sent := DllCall(
            "SendMessageTimeoutW",
            "Ptr", hwnd,
            "UInt", 0x004A,
            "Ptr", 0,
            "Ptr", copy,
            "UInt", 0x0002,
            "UInt", this.MessageTimeout,
            "Ptr*", &result,
            "Ptr"
        )
        return sent != 0 && result != 0
    }

    ; force=true 时先杀掉卡死的旧实例再冷启动。
    ; 只丢弃 HWND 是不够的：旧进程还占着 mutex，新实例会直接转发给它然后退出。
    static EnsureRunning(force := false) {
        hwnd := this.FindWindow()
        if force && hwnd {
            this.KillHudProcess(hwnd)
            hwnd := this.FindWindow()
        }
        if !force && hwnd
            return true
        exe := NotifyPaths.ImeHudWinUiExe()
        if !FileExist(exe) {
            this.LastError := "missing-exe"
            return false
        }
        try {
            ProcessNoWindow.Run(Format('"{1}"', exe))
        } catch as err {
            this.LastError := "launch-failed"
            this.Log("launch-failed " err.Message)
            return false
        }
        deadline := A_TickCount + this.LaunchWaitMs
        hwnd := 0
        while (A_TickCount < deadline) {
            hwnd := this.FindWindow()
            if hwnd {
                ; 窗口存在不代表消息循环已开始泵消息（WinUI 冷启动要 1-3 秒）。
                ; 用 PING 探活，比只等窗口句柄更准，也能让调用方立刻拿到"可发送"状态。
                if this.SendCopyData(hwnd, "PING")
                    return true
            }
            Sleep 20
        }
        if hwnd {
            ; 起来了但一直不应答：清掉，别留一个僵尸窗口让后续每次都超时。
            this.Log("hud-unresponsive-after-launch hwnd=" hwnd)
            this.KillHudProcess(hwnd)
        }
        this.LastError := "launch-timeout"
        return false
    }

    ; 生产入口启动后预热。测试入口 A_ScriptName 不是 main.ahk，不会拉起 exe。
    static Warm() {
        if (A_ScriptName != "main.ahk")
            return false
        for arg in A_Args {
            if (arg = "--test")
                return false
        }
        ; 常驻光标助手也在这里预热：它冷启动要 0.7-1.4s，
        ; 不预热的话第一次 CapsLock 会拿不到真插入点、落到窗口底部。
        this.EnsureCaretServer()
        ok := this.EnsureRunning()
        ; 常驻巡检：HUD 卡死（锁屏/切显示器后偶发）时自动清掉，下一次切换重建。
        this.StartHealthWatch()
        return ok
    }

    ; 首次按键时助手可能还没写完第一行：短暂等它一次，
    ; 避免"第一次显示在窗口底部、第二次才跟光标"。
    ; 只在真的没有任何新鲜数据时等，且最多等 FirstWaitMs。
    ; 首次按键时助手可能还没写完第一行：短暂等它一次。
    ; 助手正常常驻（180ms 刷新、12h 寿命），所以只在开机/重启后第一次按下才会等到；
    ; 900ms 实测偏长，350ms 已够覆盖一次发布间隔，等不到就直接用退化锚点 + 跟随升级。
    static FirstWaitMs := 350

    static WaitCaretServer() {
        deadline := A_TickCount + this.FirstWaitMs
        loop {
            served := this.ReadCaretServer()
            ; Known 也直接返回：助手明确说"没有插入点"时再等也没用。
            if (served.Ok || served.Known)
                return served
            if (A_TickCount >= deadline)
                return served
            Sleep 80
        }
    }

    static Log(message) {
        this.AppendLog(A_Temp "\ImeHudClient.log", message)
    }

    static LogDeployOnce() {
        if this._deployLogged
            return
        this._deployLogged := true
        this.Log("client-build=" this.BuildTag)
    }

    static AppendLog(path, message) {
        try {
            FileAppend(
                "[" FormatTime(, "yyyy-MM-dd HH:mm:ss") "] " message "`n",
                path,
                "UTF-8"
            )
        } catch {
        }
    }

    ; 常驻 HUD 是隐藏 TOOLWINDOW。WinExist 默认跳过隐藏窗口，
    ; 会让每次切换都冷启动，并把失败当成需要回退的 AHK 芯片。
    static FindWindow() {
        try {
            hwnd := DllCall(
                "User32\FindWindowW",
                "WStr", this.WindowClass,
                "WStr", this.WindowTitle,
                "Ptr"
            )
            if hwnd
                return hwnd

            hwnd := DllCall(
                "User32\FindWindowW",
                "WStr", this.WindowClass,
                "Ptr", 0,
                "Ptr"
            )
            if hwnd
                return hwnd

            hwnd := DllCall(
                "User32\FindWindowW",
                "Ptr", 0,
                "WStr", this.WindowTitle,
                "Ptr"
            )
            if hwnd
                return hwnd
        } catch {
        }
        return 0
    }

    static _followPid := 0
    static _followState := ""
    static _followTarget := 0
    static _followFile := ""
    static _followOffset := 0
    static _followSeen := 0
    static _followUpgraded := false
    static _followDeadline := 0
    ; 常驻光标助手（Chromium 系唯一可用的真插入点来源）
    static CaretServerIntervalMs := 180
    static _caretServerPid := 0
    static _caretServerFile := ""
    ; HUD 健康巡检
    static _healthTimer := false
}

ImeHud.FollowTickCallback := ObjBindMethod(ImeHud, "FollowTick")
ImeHud.HealthTickCallback := ObjBindMethod(ImeHud, "HealthTick")
