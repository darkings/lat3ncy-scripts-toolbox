#Requires AutoHotkey v2.0
#Include speak-selected-text.ahk
#Include translate-selected-text.ahk
#Include ..\..\shared\notify\toolbox-instance.ahk
#Include ..\..\shared\notify\translation-panel.ahk
#Include ..\..\shared\notify\run-nowindow.ahk

; OCR -> direct translation -> opt-in result speech. No text is sent in messages.
class TextWorkflow {
    static Message := 0x8000 + 76
    static Window := 0
    static Capture := 0
    static Retired := []
    static ContextId := 0
    static ResultText := ""
    static SourceText := ""
    static ResumeFile := ""
    static ResumeOwner := 0
    static TargetLanguage := ""
    static ContextX := 0
    static ContextY := 0
    static Busy := false
    static SpeechGeneration := 0
    static SpeechTarget := ""
    static Timer := 0
    static OnExitCallback := 0

    static Speaker() => SpeakSelectedText
    static Translator() => TranslateSelectedText
    static SubmitText(text, x, y) => this.Translator().TranslateText(text, x, y, true)
    static Error(message) => Notify.Error("×", message)
    static Info(message) => Notify.Info("!", message)

    static Init() {
        if IsObject(this.Window)
            return
        repo := TranslateSelectedText.RepoDir()
        this.Window := Gui("-Caption +ToolWindow", "Lat3ncyToolboxText-" ToolboxInstance.Hash(repo))
        this.Window.Show("Hide w1 h1")
        this.AllowMessages(A_ScriptHwnd)
        this.AllowMessages(this.Window.Hwnd)
        OnMessage(this.Message, ObjBindMethod(this, "OnMessage"))
        TranslateSelectedText.Workflow := this
        TranslateSelectedText.ScavengeRequests()
        this.Scavenge()
        TranslationPanel.Close()
        this.OnExitCallback := ObjBindMethod(this, "Shutdown")
        OnExit(this.OnExitCallback)
    }

    static AllowMessages(hwnd) {
        ; The installed AHK engine may use UIAccess while WinUI / Raycast do not.
        ; Permit only this text-free application message on our own windows.
        if !DllCall("User32\ChangeWindowMessageFilterEx", "Ptr", hwnd,
            "UInt", this.Message, "UInt", 1, "Ptr", 0, "Int")
            throw Error("无法启用文字工作流消息")
    }

    static OnMessage(wParam, lParam, msg, hwnd) {
        if (IsObject(this.Window) && hwnd = this.Window.Hwnd && wParam = 0 && lParam = 0) {
            SetTimer(ObjBindMethod(this, "StartScreenshot"), -1)
            return 1
        }
        if (hwnd != A_ScriptHwnd || wParam != this.ContextId || wParam <= 0 || lParam < 1 || lParam > 7)
            return 0
        SetTimer(ObjBindMethod(this, "HandleAction", wParam, lParam), -1)
        return 1
    }

    static HandleAction(id, action) {
        if (id != this.ContextId || id <= 0 || action < 1 || action > 7)
            return
        if (action = 2) {
            this.Translator().CancelCurrent()
            this.ClearContext()
            return
        }
        if (action = 3 || action >= 5) {
            if (this.SourceText = "" || (action = 3 && this.Busy))
                return
            text := this.SourceText, x := this.ContextX, y := this.ContextY
            target := action = 5 ? "zh" : action = 6 ? "en" : action = 7 ? "auto" : this.TargetLanguage
            owner := action = 3 ? this.ResumeOwner : 0
            this.Translator().TranslateText(text, x, y, true, Map("target", target, "resumeOwner", owner))
            return
        }
        text := action = 4 ? this.SourceText : this.ResultText
        if (text = "")
            return
        if this.OwnsSpeech()
            this.StopSpeech()
        else {
            this.SpeechGeneration := this.Speaker().SpeakText(text)
            this.SpeechTarget := action = 4 ? "source" : "result"
            this.EnsureTimer()
        }
        this.Bind(id)
    }

    static OwnsSpeech() {
        speaker := this.Speaker()
        return this.SpeechGeneration > 0 && this.SpeechGeneration = speaker.Generation
            && (IsObject(speaker.CurrentTask) || IsObject(speaker.WarmupJob))
    }

    static StopSpeech() {
        if this.OwnsSpeech()
            this.Speaker().StopCurrent()
        this.SpeechGeneration := 0
        this.SpeechTarget := ""
    }

    static ClearContext() {
        this.StopSpeech()
        if IsObject(this.ResumeOwner)
            this.ResumeOwner.Cleanup(false)
        this.ResumeFile := ""
        this.ResumeOwner := 0
        this.ContextId := 0
        this.ResultText := ""
        this.SourceText := ""
        this.Busy := false
    }

    static Begin(id) {
        this.CancelCapture()
        this.ClearContext()
        this.ContextId := id
        this.Busy := true
    }

    static Context(id, text, x, y, resumeFile, target, resumeOwner := 0) {
        if (id != this.ContextId)
            return
        this.SourceText := text, this.ContextX := x, this.ContextY := y
        this.ResumeFile := resumeFile, this.TargetLanguage := target
        this.ResumeOwner := resumeOwner
    }

    static Failed(id) {
        if (id != this.ContextId)
            return
        this.Busy := false
        this.Bind(id)
    }

    static Result(id, text) {
        if (id != this.ContextId)
            return
        if (this.ResultText != text && this.SpeechTarget != "source")
            this.StopSpeech()
        this.ResultText := text
        this.Busy := false
        this.Bind(id)
    }

    static Bind(id) {
        if (id = this.ContextId)
            TranslationPanel.SendExisting(TranslationPanel.BuildActionsCommand(A_ScriptHwnd, id, this.ResultText != "", this.OwnsSpeech(), this.Busy))
    }

    static StartScreenshot(*) {
        if IsObject(this.Capture) {
            this.CancelCapture()
            return
        }
        TranslateSelectedText.CancelCurrent()
        this.ClearContext()
        TranslationPanel.Close()
        task := 0
        try {
            repo := TranslateSelectedText.RepoDir()
            this.Scavenge()
            pid := DllCall("GetCurrentProcessId", "UInt")
            owner := this.Speaker().ProcessStartTicks(pid)
            if (owner <= 0)
                throw Error("无法确认截图任务归属")
            id := pid "-" owner "-" A_TickCount "-" Random(1000, 9999)
            directory := repo "\tools\raycast-scripts\ocr\.cache\requests\" id
            DirCreate directory
            task := {id: id, directory: directory,
                output: directory "\result.txt", x: 0, y: 0, job: 0, progressShown: false}
            baseline := DllCall("User32\GetClipboardSequenceNumber", "UInt")
            if !baseline
                throw Error("无法读取截图状态")
            oldMode := A_CoordModeMouse
            CoordMode "Mouse", "Screen"
            try MouseGetPos &x, &y
            finally CoordMode "Mouse", oldMode
            task.x := x, task.y := y
            ; Capture is native and opens before model cold start. No injected keys.
            Run "ms-screenclip:"
            ps := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
            command := '"' ps '" -NoProfile -ExecutionPolicy Bypass -File "' repo '\tools\raycast-scripts\ocr\Run-OcrWorkflow.ps1"'
                . ' -RequestId "' task.id '" -ResultFile "' task.output '" -BaselineSequence ' baseline
            task.job := ProcessNoWindow.StartAsync(command, "", 90000, true)
            this.Capture := task
            this.EnsureTimer()
        } catch {
            if IsObject(task)
                this.CleanupCapture(task)
            this.Error("截图翻译启动失败，请运行诊断检查 OCR 环境")
        }
    }

    static CancelCapture() {
        if !IsObject(this.Capture)
            return
        task := this.Capture
        this.Capture := 0
        task.job.Cancel()
        task.cleanupDeadline := A_TickCount + 5000
        this.Retired.Push(task)
        this.EnsureTimer()
    }

    static CleanupCapture(task) {
        ; Only this task's known files; never a recursive delete or PID glob.
        if !DirExist(task.directory)
            return true
        if (DllCall("GetFileAttributesW", "Str", task.directory, "UInt") & 0x400)
            return false
        try FileDelete task.output
        loop files task.output ".*.tmp", "F"
            try FileDelete A_LoopFileFullPath
        try DirDelete task.directory
        return !DirExist(task.directory)
    }

    static Scavenge() {
        root := TranslateSelectedText.RepoDir() "\tools\raycast-scripts\ocr\.cache\requests"
        count := 0
        loop files root "\*", "D" {
            if (++count > 64)
                break
            if !RegExMatch(A_LoopFileName, "^(\d+)-(\d+)-\d+-\d+$", &identity)
                continue
            live := this.Speaker().ProcessStartTicks(Integer(identity[1]))
            if (live < 0 || live = Integer(identity[2]))
                continue
            this.CleanupCapture({directory: A_LoopFileFullPath, output: A_LoopFileFullPath "\result.txt"})
        }
    }

    static EnsureTimer() {
        if this.Timer
            return
        this.Timer := ObjBindMethod(this, "Poll")
        SetTimer(this.Timer, 100)
    }

    static Poll(*) {
        if IsObject(this.Capture) {
            task := this.Capture
            task.job.Poll()
            if (!task.job.Done && !task.progressShown && FileExist(task.output)) {
                try {
                    if (FileGetSize(task.output) < 1024) {
                        progress := FileRead(task.output, "UTF-8")
                        if (TranslateSelectedText.ParseField(progress, "request_id") = task.id
                            && TranslateSelectedText.ParseField(progress, "status") = "recognizing") {
                            task.progressShown := true
                            this.Info("正在识别截图，完成后将自动翻译")
                        }
                    }
                }
            }
            if task.job.Done {
                this.Capture := 0
                try {
                    content := FileRead(task.output, "UTF-8")
                    valid := TranslateSelectedText.ParseField(content, "version") = "1"
                        && TranslateSelectedText.ParseField(content, "request_id") = task.id
                    status := TranslateSelectedText.ParseField(content, "status")
                    if (!valid || task.job.Status != "exited" || task.job.ExitCode != 0)
                        throw Error("OCR stage failed")
                    if (status = "ok") {
                        text := TranslateSelectedText.ParseField(content, "text")
                        this.SubmitText(text, task.x, task.y)
                    } else if (status = "empty")
                        this.Info("所选区域未识别到文字")
                    else if (status != "cancelled")
                        throw Error("Invalid OCR state")
                } catch {
                    this.Error("截图识别失败，请运行诊断检查 OCR 环境")
                } finally {
                    if !this.CleanupCapture(task) {
                        task.cleanupDeadline := A_TickCount + 5000
                        this.Retired.Push(task)
                    }
                }
            }
        }
        remaining := []
        for retired in this.Retired {
            retired.job.Poll()
            if retired.job.Done {
                this.CleanupCapture(retired)
                if (DirExist(retired.directory) && A_TickCount < retired.cleanupDeadline)
                    remaining.Push(retired)
            } else
                remaining.Push(retired)
        }
        this.Retired := remaining
        if (this.SpeechGeneration && !this.OwnsSpeech()) {
            this.SpeechGeneration := 0
            this.SpeechTarget := ""
            this.Bind(this.ContextId)
        }
        if (!IsObject(this.Capture) && !this.SpeechGeneration && this.Retired.Length = 0 && this.Timer) {
            SetTimer(this.Timer, 0)
            this.Timer := 0
        }
    }

    static Shutdown(*) {
        this.CancelCapture()
        translator := this.Translator()
        if HasMethod(translator, "Shutdown")
            translator.Shutdown()
        for task in this.Retired {
            task.job.Dispose()
            this.CleanupCapture(task)
        }
        this.Retired := []
        this.ClearContext()
        if IsObject(this.Window) {
            TranslationPanel.Close()
            this.Window.Destroy()
            this.Window := 0
        }
    }
}

TextWorkflow.HotkeyCallback := ObjBindMethod(TextWorkflow, "StartScreenshot")
