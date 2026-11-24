class WorkflowTestSpeaker {
    static Generation := 0
    static CurrentTask := 0
    static WarmupJob := 0
    static Said := []
    static Stops := 0
    static Shutdowns := 0
    static LastTranslation := 0
    static TranslateText(text, x, y, keep, options) {
        this.LastTranslation := {text: text, x: x, y: y, options: options}
    }
    static SpeakText(text) {
        this.Generation += 1
        this.CurrentTask := {}
        this.Said.Push(text)
        return this.Generation
    }
    static StopCurrent() {
        this.Generation += 1
        this.CurrentTask := 0
        this.Stops += 1
    }
    static CancelCurrent() => this.Stops += 1
    static Shutdown() => this.Shutdowns += 1
}

class WorkflowTestClient extends TextWorkflow {
    static Frames := []
    static Submitted := []
    static Errors := []
    static Speaker() => WorkflowTestSpeaker
    static Translator() => WorkflowTestSpeaker
    static EnsureTimer() {
    }
    static Bind(id) {
        if (id = this.ContextId)
            this.Frames.Push({id: id, ready: this.ResultText != "", speaking: this.OwnsSpeech()})
    }
    static SubmitText(text, x, y) => this.Submitted.Push({text: text, x: x, y: y})
    static Error(message) => this.Errors.Push(message)
    static Info(message) {
    }
}

class WorkflowTestJob {
    Done := true
    Status := "exited"
    ExitCode := 0
    Cancelled := false
    Poll() {
    }
    Cancel() {
        this.Cancelled := true
        this.Status := "cancelled"
    }
    Dispose() => this.Cancel()
}

class WorkflowSpeechEntry extends SpeakSelectedText {
    static Launched := ""
    static StopCurrent() => this.Generation += 1
    static IsAutoSwitchEnabled() => false
    static LaunchTts(raw, generation) => this.Launched := raw
}

class WorkflowTranslationEntry extends TranslateSelectedText {
    static Script := ""
    static PythonOverride := ""
    static Opened := ""
    static Output := ""
    static ErrorText := ""
    static Closed := 0
    static ProgressFrames := []
    static ResolveScript() => this.Script
    static ResolvePython() => this.PythonOverride != "" ? this.PythonOverride : TranslateSelectedText.ResolvePython()
    static ResolveConfig() => this.Script ".missing-config"
    static LogPath() => this.Script ".log"
    static RequestRoot() => this.Script ".requests"
    static Open(text, x, y) {
        this.Opened := text
        return true
    }
}

WorkflowLongEntryTests(root) {
    entry := WorkflowTranslationEntry
    entry.Script := root "\long-translator.py"
    worker := 'import argparse,pathlib,time`np=argparse.ArgumentParser()`n'
        . 'for n in ("input-file","output-file","request-id","resume-file","trace-file"):p.add_argument("--"+n)`na=p.parse_args()`n'
        . 'resume=pathlib.Path(a.resume_file);retry=resume.exists()`n'
        . 'out=pathlib.Path(a.output_file);base="version=1\nrequest_id="+a.request_id+"\ntotal=3\n"`n'
        . 'out.write_text("status=progress\n"+base+"completed=0\nfailed=0\n",encoding="utf-8");time.sleep(.3)`n'
        . 'resume.write_text("request-owned checkpoint",encoding="utf-8")`n'
        . 'terminal="status=ok\n"+base+"completed=3\nfailed=0\nengine=google_gtx\ncached=0\ntext=完整长译文😀" if retry else "status=partial\n"+base+"completed=2\nfailed=1\ncode=network\ntext=翻译未完成：第2段失败"`n'
        . 'out.write_text(terminal,encoding="utf-8")`n'
    FileAppend worker, entry.Script, "UTF-8-RAW"
    entry.Hooks["result"] := (text) => WorkflowTranslationEntry.Output := text
    entry.Hooks["progress"] := (done, total, failed) => WorkflowTranslationEntry.ProgressFrames.Push(done "|" total "|" failed)
    resume := ""
    try {
        entry.TranslateText("fixed long source 中文", 11, 22, true)
        task := entry.CurrentTask
        deadline := A_TickCount + 5000
        while (entry.Tasks.Length && A_TickCount < deadline) {
            entry.Poll()
            Sleep 20
        }
        resume := task.resumeFile
        AssertEqual(125000, task.job.TimeoutMs, "valid owned long progress extends the bounded Job budget")
        AssertEqual(false, WorkflowTestClient.Busy, "partial terminal enables retry")
        AssertEqual("", WorkflowTestClient.ResultText, "partial text is not offered as complete result speech")
        AssertEqual(true, !!FileExist(resume), "partial checkpoint remains owned by the open panel")
        AssertEqual(false, !!FileExist(task.outputFile), "partial terminal output is removed after delivery")
        AssertEqual("2|3|1", entry.ProgressFrames[entry.ProgressFrames.Length], "partial panel displays failed and completed counts")
        oldTask := task
        ; Simulate a retry interrupting the previous completion's final cleanup.
        oldTask.files.Busy := true
        entry.TranslateText("fixed long source 中文", 11, 22, true, Map("resumeOwner", task.resumeOwner))
        retryTask := entry.CurrentTask
        AssertEqual(false, oldTask.inputFile = retryTask.inputFile, "retry never reuses an earlier attempt's input/result directory")
        entry.CleanupTaskFiles(oldTask)
        AssertEqual(true, !!FileExist(resume), "late cleanup cannot delete a checkpoint owned by the retry")
        AssertEqual(true, !!FileExist(retryTask.inputFile), "late cleanup cannot remove the retry's separate input")
        deadline := A_TickCount + 5000
        while (entry.Tasks.Length && A_TickCount < deadline) {
            entry.Poll()
            Sleep 20
        }
        AssertEqual("完整长译文😀", WorkflowTestClient.ResultText, "retry returns complete result and enables speech")
        WorkflowTestClient.ClearContext()
        AssertEqual(false, !!FileExist(resume), "closing context removes the retained checkpoint")
        AssertEqual(false, !!DirExist(oldTask.files.directory) || !!DirExist(retryTask.files.directory), "closing retry releases both checkpoint and attempt directories")
        task := {id: 42, job: {TimeoutMs: 14000}, outputFile: root "\forged-progress.txt"}
        FileAppend "status=progress`nversion=1`nrequest_id=41`ncompleted=0`ntotal=3`nfailed=0", task.outputFile, "UTF-8-RAW"
        entry.ReadProgress(task)
        AssertEqual(14000, task.job.TimeoutMs, "foreign progress cannot extend another request")
        FileDelete task.outputFile
    } finally {
        entry.CancelCurrent()
        entry.StopPoll()
        WorkflowTestClient.ClearContext()
        if (resume != "")
            try FileDelete resume
        try FileDelete entry.Script
        try FileDelete entry.LogPath()
    }
}

WorkflowThrowDelivery(text) {
    throw Error("private UI delivery body")
}

WorkflowBackendEntryTests(root) {
    entry := WorkflowTranslationEntry
    entry.Script := root "\translator.py"
    script := 'import argparse,pathlib`np=argparse.ArgumentParser();p.add_argument("--input-file");p.add_argument("--output-file");a,_=p.parse_known_args()`n'
        . 'text=pathlib.Path(a.input_file).read_text(encoding="utf-8-sig")`n'
        . 'result="status=error\ncode=config\nmessage=fixed failure\nengine=fixture\ntext=" if "error" in text else "status=ok\nengine=fixture\ncached=0\ntext=完整译文|😀\n第二行"`n'
        . 'pathlib.Path(a.output_file).write_text(result,encoding="utf-8",newline="\n")`n'
    FileAppend script, entry.Script, "UTF-8-RAW"
    entry.RequestGate := TranslationRequestGate(), entry.Tasks := [], entry.CurrentTask := "", entry.Workflow := WorkflowTestClient
    entry.Hooks := Map("open", ObjBindMethod(entry, "Open"), "panelOpen", () => true,
        "result", (text) => WorkflowTranslationEntry.Output := text,
        "error", (message) => WorkflowTranslationEntry.ErrorText := message,
        "close", () => WorkflowTranslationEntry.Closed += 1)
    try {
        entry.LogFallback("tencent", "google_gtx", "auth")
        entry.LogFallback("tencent", "google_gtx", "credentials")
        entry.LogFallback("private", "google_gtx", "auth")
        entry.LogFallback("tencent", "google_gtx", "private")
        fallbackLog := FileRead(entry.LogPath(), "UTF-8")
        AssertContains(fallbackLog, "engine=google_gtx reason=auth", "silent auth fallback keeps a fixed diagnostic")
        AssertContains(fallbackLog, "reason=credentials", "silent missing-key fallback keeps its cause")
        AssertEqual(false, !!InStr(fallbackLog, "private"), "fallback log rejects arbitrary protocol metadata")
        for source in ["  OCR source 中文  ", "OCR error 中文"] {
            entry.TranslateText(source, 11, 22, true)
            deadline := A_TickCount + 5000
            while (entry.Tasks.Length && A_TickCount < deadline) {
                entry.Poll()
                Sleep 20
            }
            AssertEqual(0, entry.Tasks.Length, "direct translation entry finishes and closes its job")
            AssertEqual(Trim(source), entry.Opened, "direct translation receives supplied OCR source without selection capture")
            if InStr(source, "error") {
                AssertEqual("fixed failure", entry.ErrorText, "backend failure reaches fixed UI boundary")
                AssertEqual(0, entry.Closed, "OCR source panel is preserved after translation failure")
                AssertEqual("", WorkflowTestClient.ResultText, "failure cannot enable result speech")
            } else {
                AssertEqual("完整译文|😀`n第二行", entry.Output, "managed direct translation returns full Unicode result")
                AssertEqual(entry.Output, WorkflowTestClient.ResultText, "translation result becomes panel speech input")
            }
        }
        entry.PythonOverride := root "\missing-python.exe"
        entry.TranslateText("OCR launch failure 中文", 11, 22, true)
        AssertEqual(0, entry.Tasks.Length, "failed backend launch cannot leave a task")
        AssertEqual(0, entry.Closed, "failed backend launch retains OCR source panel")
        AssertEqual("翻译失败", entry.ErrorText, "failed launch uses fixed error boundary")
        AssertEqual("", WorkflowTestClient.ResultText, "failed launch cannot reuse previous speech result")
        entry.PythonOverride := ""
        id := entry.RequestGate.Begin()
        task := {id: id, job: WorkflowTestJob(), inputFile: root "\ui-in.txt", outputFile: root "\ui-out.txt",
            panelOpened: true, dismissed: false, keepSourceOnError: true}
        FileAppend "fixed input", task.inputFile, "UTF-8-RAW"
        FileAppend "status=ok`nengine=google_gtx`ncached=0`ntext=fixed result", task.outputFile, "UTF-8-RAW"
        entry.Tasks := [task], entry.CurrentTask := task
        entry.Hooks["result"] := WorkflowThrowDelivery
        entry.Poll()
        AssertEqual(0, entry.Tasks.Length, "failed UI delivery is drained without escaping the timer")
        AssertEqual(false, !!FileExist(task.inputFile), "failed UI delivery removes the input file")
        AssertEqual(false, !!FileExist(task.outputFile), "failed UI delivery removes the result file")
        deliveryLog := FileRead(entry.LogPath(), "UTF-8")
        AssertContains(deliveryLog, "delivery-failed id=" id " diagnostic=internal", "failed UI delivery records a fixed category")
        AssertEqual(false, !!InStr(deliveryLog, "private UI delivery body"), "UI callback exception text is never logged")
        trace := task.outputFile ".trace"
        FileAppend "version=1`nrequest_id=" task.id "`nroute_google_gtx=1,1,0,0,5029,tls`nroute_mymemory=1,0,0,0,1100,none`n", trace, "UTF-8-RAW"
        entry.LogEngineRoutes(task)
        routeLog := FileRead(entry.LogPath(), "UTF-8")
        AssertContains(routeLog, "engine=google_gtx calls=1 failed=1 cached=0 skipped=0 elapsed_ms=5029 kind=tls", "per-engine Google TLS failure survives a later usable fallback")
        AssertContains(routeLog, "engine=mymemory calls=1 failed=0", "actual successful fallback is a separate engine summary")
        FileDelete trace
        FileAppend "version=1`nrequest_id=" (task.id + 1) "`nroute_google_gtx=1,1,0,0,1,http`n", trace, "UTF-8-RAW"
        entry.LogEngineRoutes(task)
        AssertEqual(routeLog, FileRead(entry.LogPath(), "UTF-8"), "foreign engine trace cannot enter this request log")
        FileDelete trace
        FileAppend "version=1`nrequest_id=" task.id "`nroute_google_gtx=1,1,0,0,1,private-body`n", trace, "UTF-8-RAW"
        entry.LogEngineRoutes(task)
        AssertEqual(routeLog, FileRead(entry.LogPath(), "UTF-8"), "free-form engine trace values are rejected")
        AssertEqual(true, entry.CleanupTaskFiles(task), "owned trace is included in task cleanup")
        AssertEqual(false, !!FileExist(trace), "trace companion is removed with its task")
        WorkflowLongEntryTests(root)
    } finally {
        entry.PythonOverride := ""
        entry.CancelCurrent()
        entry.StopPoll()
        WorkflowTestClient.Shutdown()
        try FileDelete entry.Script
        try FileDelete entry.LogPath()
    }
}

TextWorkflowTests() {
    body := "原文|😀`r`npreferred_engine=private-body`r`nfallback_reason=auth`r`nrequest_id=forged`r`ntext=literal"
    protocol := "status=ok`r`nengine=google_gtx`r`ntext=" body
    AssertEqual("ok", TranslateSelectedText.ParseField(protocol, "status"), "header metadata is read before the text boundary")
    AssertEqual("", TranslateSelectedText.ParseField(protocol, "preferred_engine"), "text cannot forge absent fallback metadata")
    AssertEqual("", TranslateSelectedText.ParseField(protocol, "request_id"), "text cannot forge OCR ownership metadata")
    AssertEqual(body, TranslateSelectedText.ParseField(protocol, "text"), "full text is retained even when its lines resemble protocol fields")
    TextWorkflow.AllowMessages(A_ScriptHwnd)
    AssertEqual("PANEL|ACTIONS|291|7|1|0", TranslationPanel.BuildActionsCommand("0x123", 7, true, false), "action owner is serialized as decimal across AHK and WinUI")
    AssertEqual("PANEL|ACTIONS|291|7|0|0", TranslationPanel.BuildActionsCommand("0x123", 7, false, true), "empty result cannot advertise active playback")
    client := WorkflowTestClient
    client.ContextId := 0, client.Capture := 0, client.Retired := [], client.SpeechGeneration := 0
    client.Begin(1)
    client.Result(1, "fixed 中文|😀`r`nsecond line")
    client.HandleAction(1, 1)
    AssertEqual("fixed 中文|😀`r`nsecond line", WorkflowTestSpeaker.Said[1], "panel speaks the complete direct result")
    AssertEqual(true, client.OwnsSpeech(), "panel owns its speech generation")
    client.HandleAction(1, 1)
    AssertEqual(false, client.OwnsSpeech(), "second panel action stops owned speech")
    client.HandleAction(1, 1)
    WorkflowTestSpeaker.SpeakText("independent selection")
    stops := WorkflowTestSpeaker.Stops
    client.HandleAction(1, 2)
    AssertEqual(stops + 1, WorkflowTestSpeaker.Stops, "close only cancels translation when speech was independently replaced")
    AssertEqual(true, IsObject(WorkflowTestSpeaker.CurrentTask), "closing panel does not kill later independent speech")
    client.Begin(2)
    client.Result(1, "stale")
    client.HandleAction(1, 1)
    AssertEqual("", client.ResultText, "old results and button actions cannot enter new context")
    client.Result(2, "new result")
    client.HandleAction(2, 1)
    stops := WorkflowTestSpeaker.Stops
    client.Begin(3)
    AssertEqual(stops + 1, WorkflowTestSpeaker.Stops, "new translation stops the old panel's owned speech")

    client.Begin(100)
    client.Context(100, "original source 中文", 11, 22, "", "en")
    client.HandleAction(100, 4)
    AssertEqual("original source 中文", WorkflowTestSpeaker.Said[WorkflowTestSpeaker.Said.Length], "source speech works before a result exists")
    stops := WorkflowTestSpeaker.Stops
    client.Result(100, "new result arrived")
    AssertEqual(stops, WorkflowTestSpeaker.Stops, "arriving result does not interrupt owned source speech")
    client.HandleAction(100, 4)
    AssertEqual(false, client.OwnsSpeech(), "source speech action toggles off only owned speech")
    client.HandleAction(100, 5)
    request := WorkflowTestSpeaker.LastTranslation
    AssertEqual("original source 中文", request.text, "target switch reuses the original input")
    AssertEqual("zh", request.options["target"], "target switch only overrides this request")
    AssertEqual(11, request.x, "target switch preserves the initial anchor")
    client.HandleAction(99, 7)
    client.Busy := true
    client.HandleAction(100, 3)
    AssertEqual(request, WorkflowTestSpeaker.LastTranslation, "stale actions and busy retry do not start another request")
    client.Failed(100)
    client.HandleAction(100, 3)
    AssertEqual("en", WorkflowTestSpeaker.LastTranslation.options["target"], "retry preserves the prior per-request target")
    client.ClearContext()

    WorkflowSpeechEntry.SpeakText("  direct text 中文  ")
    AssertEqual("direct text 中文", WorkflowSpeechEntry.Launched, "shared speech text entry trims without selection capture")
    AssertEqual(0, WorkflowSpeechEntry.SpeakText("12345"), "direct speech rejects non-speakable input")

    root := A_Temp "\toolbox-text-test-" SmartPaste.NewGuid()
    DirCreate root
    try {
        for scenario in ["ok", "stale", "cancelled", "retired", "spoofed"] {
            directory := root "\" scenario
            DirCreate directory
            task := {id: "fixed-1", directory: directory, output: directory "\result.txt", x: 11, y: 22, job: WorkflowTestJob()}
            payloadId := scenario = "stale" ? "old-1" : task.id
            status := scenario = "cancelled" ? "cancelled" : "ok"
            text := "OCR 中文|😀`r`ntext=literal"
            identity := scenario = "spoofed" ? "" : "request_id=" payloadId "`n"
            if (scenario = "spoofed")
                text .= "`r`nrequest_id=" task.id
            FileAppend "version=1`n" identity "status=" status "`nerror_kind=none`ntext=" text, task.output, "UTF-8-RAW"
            client.Submitted := [], client.Errors := []
            client.Capture := task
            if (scenario = "retired")
                client.CancelCapture()
            client.Poll()
            AssertEqual(scenario = "ok" ? 1 : 0, client.Submitted.Length, "only current successful OCR advances: " scenario)
            AssertEqual(scenario = "stale" || scenario = "spoofed" ? 1 : 0, client.Errors.Length, "OCR errors are separate from cancellation: " scenario)
            if (scenario = "ok") {
                AssertEqual(text, client.Submitted[1].text, "OCR protocol preserves Unicode, delimiters and line breaks")
                AssertEqual(11, client.Submitted[1].x, "OCR uses the initial screen anchor")
            }
            AssertEqual(false, !!DirExist(directory), "OCR request is removed after completion or cancellation: " scenario)
        }
        WorkflowBackendEntryTests(root)
    } finally {
        shutdowns := WorkflowTestSpeaker.Shutdowns
        client.Shutdown()
        AssertEqual(shutdowns + 1, WorkflowTestSpeaker.Shutdowns, "workflow shutdown closes its translator before returning")
        ; All children are individually owned and removed above; no recursive deletion.
        try DirDelete root
    }
}

TextWorkflowTests()
