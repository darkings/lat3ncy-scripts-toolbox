#Requires AutoHotkey v2.0
#Include ..\..\shared\notify\run-nowindow.ahk
#Include ..\..\shared\notify\translation-panel.ahk

; 请求序号只负责"谁是最新请求"。旧请求完成时必须被丢弃，
; 不能覆盖或关闭新请求已经打开的面板。
class TranslationRequestGate {
    __New() {
        this.NextId := 0
        this.CurrentId := 0
    }

    Begin() {
        this.NextId += 1
        this.CurrentId := this.NextId
        return this.CurrentId
    }

    CancelCurrent() {
        this.CurrentId := 0
    }

    IsCurrent(id) {
        return id != 0 && id = this.CurrentId
    }

    Complete(id) {
        if !this.IsCurrent(id)
            return "discard"
        this.CurrentId := 0
        return "apply"
    }
}

; 纯决策层：异步任务完成时该做什么。测试可以直接覆盖乱序/取消/用户关闭。
class TranslationCompletionPolicy {
    static Decide(gate, requestId, jobStatus, dismissed, panelOpened, panelOpen) {
        if !gate.IsCurrent(requestId)
            return "discard-stale"
        if dismissed
            return "discard-dismissed"
        if (jobStatus = "cancelled")
            return "discard-cancelled"
        if (jobStatus = "timedout")
            return "timeout"
        if (jobStatus != "exited")
            return "error"
        if (panelOpened && !panelOpen)
            return "discard-dismissed"
        return panelOpened ? "apply" : "apply-fallback"
    }
}

class TranslateSelectedText {
    static CachedRepoDir := ""
    static ProcessTimeoutMs := 14000
    static PollIntervalMs := 100
    static LogKeepLines := 200
    static RequestGate := TranslationRequestGate()
    static Tasks := []
    static CurrentTask := ""
    static PollTimer := ""
    ; 测试注入用；生产保持 0。只影响面板/通知副作用，不影响轮询和状态机。
    static Hooks := 0
    static Workflow := 0
    static ExitBound := ""
    static ShuttingDown := false
    static ShutdownBudgetMs := 1500

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

    static LogPath() {
        return A_Temp "\lat3ncy-translate.log"
    }

    ; 只写诊断字段（code/engine/detail），不写原文，也不写密钥。
    static Log(message) {
        try {
            path := this.LogPath()
            line := "[" FormatTime(, "yyyy-MM-dd HH:mm:ss") "] " StrReplace(message, "`n", " ") "`n"
            FileAppend line, path, "UTF-8"
            if FileExist(path) {
                lines := StrSplit(RTrim(FileRead(path, "UTF-8"), "`r`n"), "`n")
                if (lines.Length > this.LogKeepLines) {
                    keep := ""
                    start := lines.Length - this.LogKeepLines + 1
                    loop this.LogKeepLines
                        keep .= lines[start + A_Index - 1] "`n"
                    FileDelete path
                    FileAppend keep, path, "UTF-8"
                }
            }
        } catch {
        }
    }

    static ParseField(content, name) {
        ; text consumes the remainder, including lines that look like headers.
        hasText := RegExMatch(content, "m)^text=", &body)
        if (name = "text")
            return hasText ? SubStr(content, body.Pos + body.Len) : ""
        header := hasText ? SubStr(content, 1, body.Pos - 1) : content
        needle := "m)^" name "="
        if !RegExMatch(header, needle, &match)
            return ""
        start := match.Pos + match.Len
        rest := SubStr(header, start)
        lineEnd := InStr(rest, "`n")
        if !lineEnd
            return Trim(rest, "`r")
        return Trim(SubStr(rest, 1, lineEnd - 1), "`r")
    }

    static MessageForError(code, message, length := "", maxChars := "") {
        switch code {
            case "too_long":
                ; 界面必须能看出"原文多长、上限多少"，不能只显示上限。
                if (length != "" && maxChars != "")
                    return "文本过长（" length " 字符，上限 " maxChars "）"
                return message != "" ? message : "文本过长，未翻译"
            case "auth":
                return message != "" ? message : "翻译密钥无效"
            case "config":
                return message != "" ? message : "翻译配置错误"
            case "timeout":
                return message != "" ? message : "翻译超时"
            case "network":
                return message != "" ? message : "翻译失败（网络）"
            case "io":
                return message != "" ? message : "翻译失败（文件读写）"
            case "internal":
                return message != "" ? message : "翻译失败（内部错误）"
            default:
                return message != "" ? message : "翻译失败"
        }
    }

    static Translate(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        ; 热键瞬间的屏幕物理像素。必须先记，不能等 Ctrl+C / 翻译完成后再读光标。
        ; AHK v2 默认 CoordMode Mouse=Client：右边窗口里的客户区 (336,378)
        ; 会被 WinUI 当成屏幕坐标，面板就会落到左半边。
        ; CoordMode 是全局设置：取完必须还原，否则 find-mouse 之类的功能会拿到错的坐标。
        savedMouseCoordMode := A_CoordModeMouse
        CoordMode "Mouse", "Screen"
        hotkeyX := 0
        hotkeyY := 0
        try
            MouseGetPos &hotkeyX, &hotkeyY
        finally
            CoordMode "Mouse", savedMouseCoordMode

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

        return this.TranslateText(selected, hotkeyX, hotkeyY)
    }

    ; Shared backend entry; callers supply text directly, never through clipboard.
    static TranslateText(selected, hotkeyX := 0, hotkeyY := 0, keepSourceOnError := false) {
        if this.ShuttingDown
            return 0
        selected := this.Normalize(selected)
        if (selected = "") {
            Notify.Error("!", "未选中文字")
            return
        }
        if (!this.HasTranslatableText(selected) && !keepSourceOnError) {
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

        ; 连续触发：旧请求立即取消，它完成后的结果会因序号过期被丢弃。
        this.CancelCurrent()

        requestId := this.RequestGate.Begin()
        if IsObject(this.Workflow)
            this.Workflow.Begin(requestId)
        stamp := A_TickCount "-" requestId "-" Random(1000, 9999)
        inputFile := A_Temp "\lat3ncy-translate-in-" stamp ".txt"
        outputFile := A_Temp "\lat3ncy-translate-out-" stamp ".txt"
        try FileDelete inputFile
        try FileDelete outputFile

        cmd := '"' pythonExe '" "' scriptPath '" --input-file "' inputFile '" --output-file "' outputFile '"'
        if FileExist(configPath)
            cmd .= ' --config "' configPath '"'

        job := ""
        panelOpened := false
        try {
            FileAppend selected, inputFile, "UTF-8"
            ; 翻译一开始就打开 WinUI 面板显示原文。
            panelOpened := this.OpenPanel(selected, hotkeyX, hotkeyY)
            if (panelOpened && IsObject(this.Workflow))
                this.Workflow.Bind(requestId)
            ; 非等待启动：热键线程立刻返回，翻译在子进程里跑，AHK 定时器不受阻。
            job := ProcessNoWindow.StartAsync(cmd, "", this.ProcessTimeoutMs, true)
        } catch as err {
            try FileDelete inputFile
            try FileDelete outputFile
            if !(keepSourceOnError && panelOpened && this.IsPanelOpen())
                try this.ClosePanel()
            this.Log("start-failed id=" requestId " error=" err.Message)
            this.ShowError("翻译失败")
            return
        }

        task := {
            id: requestId,
            job: job,
            inputFile: inputFile,
            outputFile: outputFile,
            panelOpened: panelOpened,
            dismissed: false,
            keepSourceOnError: keepSourceOnError
        }
        this.Tasks.Push(task)
        this.CurrentTask := task
        this.EnsurePoll()
        this.Log("begin id=" requestId " chars=" StrLen(selected) " pid=" job.Pid " panel=" panelOpened)
        return requestId
    }

    static CancelCurrent() {
        task := this.CurrentTask
        this.CurrentTask := ""
        this.RequestGate.CancelCurrent()
        if IsObject(task) {
            this.Log("cancel id=" task.id)
            if !task.job.Done
                task.job.Cancel()
        }
    }

    static EnsurePoll() {
        if (this.ExitBound = "") {
            this.ExitBound := ObjBindMethod(this, "Shutdown")
            OnExit this.ExitBound
        }
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

    static ReadOutput(path) {
        if !FileExist(path)
            return ""
        try
            return FileRead(path, "UTF-8")
        catch
            return ""
    }

    static CleanupTaskFiles(task) {
        try FileDelete task.inputFile
        try FileDelete task.outputFile
        return !FileExist(task.inputFile) && !FileExist(task.outputFile)
    }

    static Shutdown(*) {
        if this.ShuttingDown
            return 0
        this.ShuttingDown := true
        this.StopPoll()
        this.CancelCurrent()
        tasks := this.Tasks
        deadline := A_TickCount + this.ShutdownBudgetMs
        for task in tasks {
            if !task.job.Done
                try task.job.Cancel()
        }
        loop {
            pending := false
            for task in tasks {
                if !task.job.Done {
                    try task.job.Poll()
                    pending := pending || !task.job.Done
                }
            }
            if (!pending || A_TickCount >= deadline)
                break
            Sleep 10
        }
        for task in tasks
            try task.job.Dispose()
        loop {
            clean := true
            for task in tasks
                clean := this.CleanupTaskFiles(task) && clean
            if (clean || A_TickCount >= deadline)
                break
            Sleep 10
        }
        this.Tasks := []
        this.Log("shutdown tasks=" tasks.Length " cleanup=" (clean ? "complete" : "incomplete"))
        return 0
    }

    static IsPanelOpen() {
        if (IsObject(this.Hooks) && this.Hooks.Has("panelOpen"))
            return this.Hooks["panelOpen"].Call()
        return TranslationPanel.IsOpen()
    }

    static OpenPanel(text, x, y) {
        if (IsObject(this.Hooks) && this.Hooks.Has("open"))
            return this.Hooks["open"].Call(text, x, y)
        return TranslationPanel.OpenText(text, x, y)
    }

    static ShowError(message) {
        if (IsObject(this.Hooks) && this.Hooks.Has("error")) {
            this.Hooks["error"].Call(message)
            return
        }
        Notify.Error("×", message)
    }

    static LogFallback(preferred, actual, reason) {
        engines := Map("tencent", true, "aliyun", true, "google_gtx", true, "mymemory", true)
        if (!engines.Has(preferred) || !engines.Has(actual) || preferred = actual
            || !RegExMatch(reason, "^(credentials|auth|network|timeout|too_long)$"))
            return
        this.Log("fallback preferred=" preferred " engine=" actual " reason=" reason)
    }

    static ShowPopup(text) {
        if (IsObject(this.Hooks) && this.Hooks.Has("popup")) {
            this.Hooks["popup"].Call(text)
            return
        }
        Notify.Popup(text, 8000)
    }

    static SetPanelResult(text) {
        if (IsObject(this.Hooks) && this.Hooks.Has("result")) {
            this.Hooks["result"].Call(text)
            return
        }
        TranslationPanel.SetResult(text)
    }

    static ClosePanel() {
        if (IsObject(this.Hooks) && this.Hooks.Has("close")) {
            this.Hooks["close"].Call()
            return
        }
        TranslationPanel.Close()
    }

    ; 定时器里只做非阻塞轮询和一次性完成处理。绝不 WaitForSingleObject 等待子进程。
    static Poll(*) {
        if (this.Tasks.Length = 0) {
            this.StopPoll()
            return
        }

        remaining := []
        for task in this.Tasks {
            ; Done 只由 Job.Poll() 推进；定时器必须实际轮询子进程。
            task.job.Poll()
            if !task.job.Done {
                ; 用户关掉面板就取消请求；不要再把结果塞回已关的面板。
                if (this.CurrentTask = task && task.panelOpened && !this.IsPanelOpen()) {
                    task.dismissed := true
                    task.job.Cancel()
                    this.Log("dismiss id=" task.id)
                }
                remaining.Push(task)
                continue
            }

            status := task.job.Status
            isCurrent := (this.CurrentTask = task)
            panelOpen := task.panelOpened ? this.IsPanelOpen() : false
            decision := TranslationCompletionPolicy.Decide(
                this.RequestGate, task.id, status, task.dismissed, task.panelOpened, panelOpen)

            if isCurrent {
                this.CurrentTask := ""
                this.RequestGate.CancelCurrent()
            }

            try {
                switch decision {
                    case "apply", "apply-fallback":
                        this.ApplyResult(task, decision = "apply-fallback")
                    case "timeout":
                        this.Fail(task, "翻译超时", "timeout")
                    case "error":
                        this.Fail(task, "翻译失败", status)
                    case "discard-stale":
                        this.Log("discard-stale id=" task.id " status=" status)
                    case "discard-dismissed":
                        this.Log("discard-dismissed id=" task.id)
                    case "discard-cancelled":
                        this.Log("discard-cancelled id=" task.id)
                    default:
                        this.Log("discard-unknown id=" task.id " decision=" decision)
                }
            } catch {
                ; A failed UI callback must not escape a timer or expose its
                ; potentially private exception text. Do not retry notifications.
                this.Log("delivery-failed id=" task.id " diagnostic=internal")
            } finally {
                ; The protocol must be read first, then removed on every path.
                this.CleanupTaskFiles(task)
            }
        }

        this.Tasks := remaining
        if (this.Tasks.Length = 0)
            this.StopPoll()
    }

    static ApplyResult(task, fallback) {
        content := this.ReadOutput(task.outputFile)
        status := this.ParseField(content, "status")
        if (status != "ok") {
            code := this.ParseField(content, "code")
            message := this.ParseField(content, "message")
            length := this.ParseField(content, "length")
            maxChars := this.ParseField(content, "max_chars")
            detail := this.ParseField(content, "detail")
            engine := this.ParseField(content, "engine")
            userMessage := this.MessageForError(code, message, length, maxChars)
            this.Fail(task, userMessage, code " detail=" detail " engine=" engine)
            return
        }

        text := Trim(this.ParseField(content, "text"), "`r`n")
        if (text = "") {
            this.Fail(task, "未包含可翻译文字", "empty-result")
            return
        }

        engine := this.ParseField(content, "engine")
        cached := this.ParseField(content, "cached")
        this.LogFallback(this.ParseField(content, "preferred_engine"), engine, this.ParseField(content, "fallback_reason"))
        if fallback {
            ; 面板不可用（HUD 未启动成功）时保留翻译能力，用 AHK popup 兜底。
            try this.ShowPopup(text)
            this.Log("ok-popup id=" task.id " engine=" engine " cached=" cached)
            return
        }

        ; 用户可能在完成回调前刚关掉面板；此时丢弃结果，不重新打开。
        if !this.IsPanelOpen() {
            this.Log("discard-race id=" task.id)
            return
        }
        this.SetPanelResult(text)
        if IsObject(this.Workflow)
            this.Workflow.Result(task.id, text)
        this.Log("ok id=" task.id " engine=" engine " cached=" cached " chars=" StrLen(text))
    }

    static Fail(task, message, diagnostic) {
        if !(task.HasOwnProp("keepSourceOnError") && task.keepSourceOnError && task.panelOpened && this.IsPanelOpen())
            try this.ClosePanel()
        this.Log("fail id=" task.id " message=" message " diagnostic=" SubStr(diagnostic, 1, 240))
        this.ShowError(message)
    }
}

TranslateSelectedText.HotkeyCallback := ObjBindMethod(TranslateSelectedText, "Translate")
