class WorkflowTestSpeaker {
    static Generation := 0
    static CurrentTask := 0
    static WarmupJob := 0
    static Said := []
    static Stops := 0
    static Shutdowns := 0
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
    static ResolveScript() => this.Script
    static ResolvePython() => this.PythonOverride != "" ? this.PythonOverride : TranslateSelectedText.ResolvePython()
    static ResolveConfig() => this.Script ".missing-config"
    static LogPath() => this.Script ".log"
    static Open(text, x, y) {
        this.Opened := text
        return true
    }
}

WorkflowThrowDelivery(text) {
    throw Error("private UI delivery body")
}

WorkflowBackendEntryTests(root) {
    entry := WorkflowTranslationEntry
    entry.Script := root "\translator.py"
    script := 'import argparse,pathlib`np=argparse.ArgumentParser();p.add_argument("--input-file");p.add_argument("--output-file");a=p.parse_args()`n'
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
