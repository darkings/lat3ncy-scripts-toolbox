#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\..\ahk\main.ahk
#SingleInstance Off

; Only invoked by text_workflow_smoke.py. No global hotkeys or real speech.
if (A_Args.Length != 3 || A_Args[1] != "--test")
    ExitApp 2
global PipelineRoot := A_Args[2]
global PipelineOnline := A_Args[3] = "online"
global PipelineChecks := PipelineRoot "\checks.txt"
global PipelineOwnsPanel := false
global PipelineLease := 0
global PipelineLeaseOwned := false
OnError PipelineFailure
OnExit PipelineExit
SetTimer(() => ExitApp(1), -120000)

class PipelineSpeaker {
    static Generation := 0
    static CurrentTask := 0
    static WarmupJob := 0
    static Text := ""
    static Stops := 0
    static SpeakText(text) {
        this.Generation += 1
        this.Text := text
        this.CurrentTask := {}
        return this.Generation
    }
    static StopCurrent() {
        this.Generation += 1
        this.CurrentTask := 0
        this.Stops += 1
    }
}

class PipelineTranslator extends TranslateSelectedText {
    static Config := PipelineRoot "\config.toml"
    static Source := ""
    static Output := ""
    static Errors := 0
    static ResolveConfig() => this.Config
    static LogPath() => PipelineRoot "\translation.log"
    static RequestRoot() => PipelineRoot "\translate-requests"
    static OpenPanel(text, x, y) {
        this.Source := text
        opened := TranslationPanel.OpenText(text, x, y)
        TranslationPanel.SendExisting("PANEL|PIN|1")
        return opened
    }
    static SetPanelResult(text) {
        this.RememberJobs()
        this.Output := text
        return TranslationPanel.SetResult(text)
    }
    static ShowError(message) {
        this.RememberJobs()
        this.Errors += 1
    }
    static RememberJobs() {
        for task in this.Tasks {
            found := false
            for known in PipelineWorkflow.TranslationJobs
                if (known = task.job)
                    found := true
            if !found
                PipelineWorkflow.TranslationJobs.Push(task.job)
        }
    }
    static ShowPopup(text) {
        throw Error("Panel unavailable")
    }
}

class PipelineWorkflow extends TextWorkflow {
    static Errors := 0
    static Jobs := []
    static TranslationJobs := []
    static Speaker() => PipelineSpeaker
    static Translator() => PipelineTranslator
    static Error(message) => this.Errors += 1
    static Info(message) {
    }
}

PipelineRecord(name, passed) {
    FileAppend name "=" (passed ? 1 : 0) "`n", PipelineChecks, "UTF-8-RAW"
    if !passed
        throw Error("Pipeline check failed: " name)
}

PipelineWait(predicate, timeout := 30000) {
    deadline := A_TickCount + timeout
    while !predicate.Call() {
        if (A_TickCount >= deadline)
            throw Error("Pipeline wait timeout")
        Sleep 20
    }
}

PipelineCapture(name, image) {
    directory := PipelineRoot "\tasks\" name
    DirCreate directory
    task := {id: "pipeline-" name, directory: directory, output: directory "\result.txt",
        x: 250, y: 220, progressShown: false}
    repo := TranslateSelectedText.RepoDir()
    ps := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    command := '"' ps '" -NoProfile -ExecutionPolicy Bypass -File "' repo '\tools\raycast-scripts\ocr\Run-OcrWorkflow.ps1"'
        . ' -RequestId "' task.id '" -ResultFile "' task.output '" -BaselineSequence 0 -ImageFile "' image '"'
    task.job := ProcessNoWindow.StartAsync(command, "", 90000, true)
    PipelineWorkflow.Jobs.Push(task.job)
    PipelineWorkflow.Capture := task
    PipelineWorkflow.EnsureTimer()
    return task
}

PipelineIdle() => !IsObject(PipelineWorkflow.Capture) && PipelineWorkflow.Retired.Length = 0 && PipelineTranslator.Tasks.Length = 0

PipelineHudOwned() {
    hud := TranslationPanel.FindWindow()
    if !hud
        return false
    previous := A_DetectHiddenWindows
    DetectHiddenWindows true
    try return StrLower(WinGetProcessPath("ahk_id " hud)) = StrLower(NotifyPaths.ImeHudWinUiExe())
    finally DetectHiddenWindows previous
}

PipelineFailure(error, *) {
    try FileAppend "failed=1`nline=" error.Line "`n", PipelineChecks, "UTF-8-RAW"
    ExitApp 1
}

PipelineExit(*) {
    PipelineTranslator.CancelCurrent()
    deadline := A_TickCount + 5000
    while (PipelineTranslator.Tasks.Length && A_TickCount < deadline) {
        PipelineTranslator.Poll()
        Sleep 20
    }
    for task in PipelineTranslator.Tasks {
        task.job.Dispose()
        PipelineTranslator.CleanupTaskFiles(task)
    }
    PipelineTranslator.Tasks := []
    PipelineTranslator.StopPoll()
    PipelineWorkflow.Shutdown()
    if PipelineOwnsPanel {
        TranslationPanel.SendExisting("PANEL|PIN|0")
        TranslationPanel.Close()
    }
    if PipelineLeaseOwned
        DllCall("ReleaseMutex", "Ptr", PipelineLease)
    if PipelineLease
        DllCall("CloseHandle", "Ptr", PipelineLease)
    return 0
}

PipelineLease := DllCall("CreateMutexW", "Ptr", 0, "Int", 1,
    "Str", "Local\Lat3ncyTextProbe-" ToolboxInstance.Hash(TranslateSelectedText.RepoDir()), "Ptr")
if (!PipelineLease || A_LastError = 183)
    throw Error("Another workflow probe is running")
PipelineLeaseOwned := true
if !PipelineHudOwned()
    throw Error("Existing repository HUD required")
PipelineOwnsPanel := true
PipelineWorkflow.AllowMessages(A_ScriptHwnd)
OnMessage(TextWorkflow.Message, ObjBindMethod(PipelineWorkflow, "OnMessage"))
PipelineTranslator.Workflow := PipelineWorkflow
if PipelineOnline
    PipelineTranslator.Config := TranslateSelectedText.ResolveConfig()

; Actual model -> production polling -> actual backend -> real WinUI result.
success := PipelineCapture("success", PipelineRoot "\fixture.png")
PipelineWait(PipelineIdle)
compact := RegExReplace(StrLower(PipelineTranslator.Source), "\s", "")
PipelineRecord("recognized", compact = "helloworkflow42")
translated := PipelineTranslator.Output
PipelineRecord("translated", PipelineWorkflow.ResultText = translated && translated != ""
    && (PipelineOnline ? RegExMatch(translated, "[\x{4E00}-\x{9FFF}]") : translated = PipelineTranslator.Source))
TranslationPanel.SendExisting("PANEL|SPEAK|result")
PipelineWait(() => PipelineWorkflow.OwnsSpeech(), 3000)
PipelineRecord("speechStart", PipelineSpeaker.Text = translated)
TranslationPanel.SendExisting("PANEL|SPEAK|result")
PipelineWait(() => !PipelineWorkflow.OwnsSpeech(), 3000)
PipelineRecord("speechStop", PipelineSpeaker.Stops = 1)
TranslationPanel.Close()
PipelineWait(() => PipelineWorkflow.ContextId = 0, 3000)
PipelineRecord("panelClose", !TranslationPanel.IsOpen())

; Cancel the actual required Job before OCR can hand off a result.
source := PipelineTranslator.Source
cancelled := PipelineCapture("cancelled", PipelineRoot "\fixture.png")
PipelineWorkflow.CancelCapture()
PipelineWait(PipelineIdle, 10000)
PipelineRecord("cancelled", cancelled.job.Done && cancelled.job.Status = "cancelled"
    && !DirExist(cancelled.directory) && PipelineTranslator.Source = source)

; Missing fixed input yields production OCR error, no translation or panel.
errors := PipelineWorkflow.Errors
failed := PipelineCapture("ocr-failure", PipelineRoot "\missing.png")
PipelineWait(PipelineIdle)
PipelineRecord("ocrFailure", PipelineWorkflow.Errors = errors + 1
    && !TranslationPanel.IsOpen() && PipelineTranslator.Source = source)

; Real backend config rejection must leave newly recognized source visible.
PipelineTranslator.Output := ""
PipelineTranslator.Config := PipelineRoot "\invalid.toml"
errors := PipelineTranslator.Errors
failedTranslation := PipelineCapture("translation-failure", PipelineRoot "\fixture.png")
PipelineWait(PipelineIdle)
PipelineRecord("translationFailure", PipelineTranslator.Errors = errors + 1
    && TranslationPanel.IsOpen() && PipelineTranslator.Output = "" && PipelineWorkflow.ResultText = ""
    && RegExReplace(StrLower(PipelineTranslator.Source), "\s", "") = "helloworkflow42")
TranslationPanel.Close()
PipelineWait(() => PipelineWorkflow.ContextId = 0, 3000)

closed := true
for job in PipelineWorkflow.Jobs
    closed := closed && job.Done && job.HandlesClosed
for job in PipelineWorkflow.TranslationJobs
    closed := closed && job.Done && job.HandlesClosed
PipelineRecord("jobsClosed", closed && PipelineWorkflow.TranslationJobs.Length >= 2)
clean := true
loop files PipelineRoot "\tasks\*", "D"
    clean := false
loop files A_Temp "\lat3ncy-translate-*", "F"
    clean := false
if DirExist(PipelineTranslator.RequestRoot())
    clean := false
PipelineRecord("tasksClean", clean)
ExitApp 0
