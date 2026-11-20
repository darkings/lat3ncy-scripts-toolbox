; Synthetic process fixtures only: no synthesis, clipboard, audio or device changes.
class TtsFixtureClient extends SpeakSelectedText {
    static DiagnosticLog := ""
    static LogPath() {
        return this.DiagnosticLog
    }
}
TtsFixture(root, name, generation) {
    dir := root "\" name
    DirCreate dir
    return {id: name, generation: generation, directory: dir, inputFile: dir "\input.txt",
        resultFile: dir "\result.txt", retiredTick: A_TickCount}
}

TtsReport(task, status := "success", kind := "none", id := "") {
    if FileExist(task.resultFile)
        FileDelete task.resultFile
    FileAppend "version=1`nrequest_id=" (id = "" ? task.id : id) "`nstatus=" status "`nerror_kind=" kind "`nstage=complete`n", task.resultFile, "UTF-8-RAW"
}

TtsLifecycleTests() {
    root := A_Temp "\toolbox-tts-jobs-" SmartPaste.NewGuid()
    DirCreate root
    TtsFixtureClient.DiagnosticLog := root "\tts.log"
    savedTask := TtsFixtureClient.CurrentTask, savedRetired := TtsFixtureClient.RetiredTasks
    savedGeneration := TtsFixtureClient.Generation, savedOutcome := TtsFixtureClient.LastOutcome
    savedExit := TtsFixtureClient.ExitBound
    TtsFixtureClient.CurrentTask := "", TtsFixtureClient.RetiredTasks := []
    childPid := 0, job := "", ownedTemp := "", unrelatedTemp := ""
    try {
        moduleDir := root "\module with spaces"
        profileRoot := root "\profile"
        runtimeDir := profileRoot "\lat3ncy-toolbox\tts-runtimes\" ToolboxInstance.Hash(moduleDir)
        DirCreate runtimeDir "\Scripts"
        FileAppend "fixture", runtimeDir "\Scripts\pythonw.exe"
        AssertEqual("", TtsFixtureClient.ProfilePython(moduleDir, profileRoot), "unready profile cannot replace legacy interpreter")
        FileAppend "another module", runtimeDir "\.ready.txt", "UTF-8-RAW"
        AssertEqual("", TtsFixtureClient.ProfilePython(moduleDir, profileRoot), "profile ownership rejects a hash collision")
        FileDelete runtimeDir "\.ready.txt"
        FileAppend StrLower(moduleDir), runtimeDir "\.ready.txt", "UTF-8-RAW"
        AssertEqual(runtimeDir "\Scripts\pythonw.exe", TtsFixtureClient.ProfilePython(moduleDir, profileRoot), "owned ready profile is selected")

        task := TtsFixture(root, "report-" A_TickCount, TtsFixtureClient.Generation)
        task.job := {Status: "exited", ExitCode: 0}
        TtsReport(task)
        AssertEqual("success", TtsFixtureClient.Outcome(task).status, "TTS accepts matching success and zero exit")
        TtsReport(task, "success", "none", "other-request")
        AssertEqual("protocol", TtsFixtureClient.Outcome(task).kind, "TTS rejects another request result")
        TtsReport(task)
        FileAppend "status=success`n", task.resultFile, "UTF-8-RAW"
        AssertEqual("protocol", TtsFixtureClient.Outcome(task).kind, "TTS rejects duplicate fields")
        TtsReport(task)
        task.job.ExitCode := 1
        AssertEqual("protocol", TtsFixtureClient.Outcome(task).kind, "TTS rejects success with nonzero exit")
        TtsReport(task, "failed", "playback")
        AssertEqual("音频播放失败", TtsFixtureClient.Outcome(task).message, "TTS maps safe failure kind to feedback")
        task.job.Status := "timedout"
        AssertEqual("timeout", TtsFixtureClient.Outcome(task).status, "outer job timeout does not need a child result")
        task.job.Status := "cancelled"
        AssertEqual("", TtsFixtureClient.Outcome(task).message, "explicit cancellation stays quiet")
        task.job.Status := "exited"
        newer := {generation: TtsFixtureClient.Generation + 1}
        TtsFixtureClient.CurrentTask := newer
        TtsFixtureClient.LastOutcome := "newer-outcome"
        TtsFixtureClient.FinishTask(task, false)
        AssertEqual(newer, TtsFixtureClient.CurrentTask, "old completion cannot clear the new task")
        AssertEqual("newer-outcome", TtsFixtureClient.LastOutcome, "old completion cannot overwrite new outcome")
        TtsFixtureClient.CurrentTask := ""

        task := TtsFixture(root, "cancel-" A_TickCount, TtsFixtureClient.Generation)
        FileAppend "owned input fixture", task.inputFile
        script := root "\child.ps1", pidFile := root "\child-pid.txt"
        FileAppend 'param($PidFile)`n$info=[Diagnostics.ProcessStartInfo]::new()`n$info.FileName="$env:SystemRoot\System32\ping.exe"`n$info.Arguments="127.0.0.1 -n 30"`n$info.UseShellExecute=$false;$info.CreateNoWindow=$true`n$p=[Diagnostics.Process]::Start($info)`n[IO.File]::WriteAllText($PidFile,[string]$p.Id)`nStart-Sleep -Seconds 30`n', script, "UTF-8-RAW"
        command := '"' EnvGet("SystemRoot") '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "' script '" "' pidFile '"'
        job := ProcessNoWindow.StartAsync(command, "", 10000, true)
        AssertEqual(true, job.AssignedToJob, "TTS requires a real process group")
        task.job := job
        deadline := A_TickCount + 5000
        while (!FileExist(pidFile) && A_TickCount < deadline)
            Sleep 25
        AssertEqual(true, FileExist(pidFile) != "", "fixture child started")
        childPid := Integer(Trim(FileRead(pidFile)))
        AssertEqual(true, ProcessExist(childPid) != 0, "fixture descendant is alive before cancel")
        cache := TtsFixtureClient.CacheDirectories()[1]
        DirCreate cache
        ownedTemp := cache "\.tts-tmp." task.id ".partial.mp3"
        unrelatedTemp := cache "\fixture.tmp.unrelated-" A_TickCount ".partial.mp3"
        FileAppend "owned", ownedTemp
        FileAppend "unrelated", unrelatedTemp
        TtsFixtureClient.CurrentTask := task
        TtsFixtureClient.TtsPid := job.Pid
        TtsFixtureClient.LastInputFile := task.inputFile
        TtsFixtureClient.StopCurrent()
        AssertEqual("cancelled", TtsFixtureClient.LastOutcome.status, "cancel has an explicit local terminal outcome")
        deadline := A_TickCount + 5000
        while ((TtsFixtureClient.RetiredTasks.Length || ProcessExist(childPid)) && A_TickCount < deadline) {
            TtsFixtureClient.WatchPid()
            Sleep 25
        }
        AssertEqual(true, job.HandlesClosed, "cancel releases process and job handles")
        AssertEqual(0, ProcessExist(childPid), "cancel terminates the SAPI-like descendant too")
        AssertEqual(false, FileExist(ownedTemp) != "", "cancel cleans request-owned audio fragments")
        AssertEqual(true, FileExist(unrelatedTemp) != "", "cancel preserves another request fragment")
        AssertEqual(false, DirExist(task.directory) != "", "cancel removes request input and directory")

        job := ProcessNoWindow.StartAsync('"' EnvGet("SystemRoot") '\System32\ping.exe" 127.0.0.1 -n 30', "", 100, true)
        WaitAsyncJob(job, 4000)
        AssertEqual("timedout", job.Status, "managed task enforces its hard time budget")
        AssertEqual(true, job.HandlesClosed, "timeout closes managed handles")

        descriptor := ProcessNoWindow.GetOwnPropDesc("TryCreateKillOnCloseJob")
        marker := root "\must-not-run.txt"
        try {
            ProcessNoWindow.DefineProp("TryCreateKillOnCloseJob", {Call: (self, handle) => 0})
            AssertThrows(() => ProcessNoWindow.StartAsync('cmd.exe /c echo forbidden >"' marker '"', "", 1000, true),
                "无法绑定任务进程组", "TTS refuses to run without descendant ownership")
        } finally {
            ProcessNoWindow.DefineProp("TryCreateKillOnCloseJob", descriptor)
        }
        Sleep 50
        AssertEqual(false, FileExist(marker) != "", "job assignment failure never resumes the process")

        ; Stale owner metadata includes creation FILETIME, so PID reuse cannot
        ; make an old request look active. Unknown files/active owners survive.
        pid := DllCall("GetCurrentProcessId", "UInt")
        created := TtsFixtureClient.ProcessStartTicks(pid)
        requestRoot := TtsFixtureClient.CacheDirectories()[1] "\requests"
        liveId := pid "-" created "-0-0-ABCDEF0123456789"
        staleId := pid "-1-0-0-ABCDEF0123456789"
        live := TtsFixture(requestRoot, liveId, 0)
        stale := TtsFixture(requestRoot, staleId, 0)
        stale.inputFile := stale.directory "\lat3ncy-tts-in-data.txt"
        FileAppend "owned stale fixture", stale.inputFile
        TtsFixtureClient.ScavengeRequests()
        AssertEqual(true, DirExist(live.directory) != "", "scavenger preserves a live matching owner")
        AssertEqual(false, DirExist(stale.directory) != "", "scavenger detects old creation time despite PID reuse")
        DirDelete live.directory

        owned := TtsFixtureClient.NewRequest(TtsFixtureClient.Generation)
        FileAppend "request fixture", owned.inputFile
        AssertEqual("request fixture", FileRead(owned.inputFile), "request paths work in a clean checkout with spaces")
        AssertEqual(true, TtsFixtureClient.CleanupTaskFiles(owned), "new owned request is fully cleaned")

        ; Real interpreter + real CLI result writer under the same required Job.
        ; Remove the fixture input before entry, so no synthesis/playback occurs.
        managed := TtsFixtureClient.NewRequest(TtsFixtureClient.Generation)
        FileAppend "fixture input", managed.inputFile
        worker := managed.directory "\worker.py", workerLog := managed.directory "\worker.log"
        FileAppend 'import os,sys`nsys.path.insert(0,sys.argv.pop(1))`nlog=sys.argv.pop(1)`nimport tts_player as tts`ntts.configure_logging(log,log_text=False)`nos.remove(sys.argv[sys.argv.index("--input-file")+1])`nraise SystemExit(tts.main())`n', worker, "UTF-8-RAW"
        SplitPath TtsFixtureClient.ResolveScript(), , &moduleDir
        command := '"' SpeakSelectedText.ResolvePython() '" "' worker '" "' moduleDir '" "' workerLog '"'
            . ' --input-file "' managed.inputFile '" --request-id "' managed.id '" --result-file "' managed.resultFile '"'
        job := ProcessNoWindow.StartAsync(command, "", 10000, true)
        managed.job := job
        WaitAsyncJob(job, 5000)
        AssertEqual(true, job.Done, "managed interpreter finishes without a detached launcher")
        TtsFixtureClient.CurrentTask := managed
        FileDelete worker
        if FileExist(workerLog)
            FileDelete workerLog
        outcome := TtsFixtureClient.FinishTask(managed, false)
        AssertEqual("input", outcome.kind, "real CLI failure travels through the owned request contract")
        AssertEqual(false, DirExist(managed.directory) != "", "managed real CLI request is cleaned")

        task := TtsFixture(root, "exit-" A_TickCount, TtsFixtureClient.Generation)
        FileAppend "owned exit fixture", task.inputFile
        job := ProcessNoWindow.StartAsync('"' EnvGet("SystemRoot") '\System32\ping.exe" 127.0.0.1 -n 30', "", 10000, true)
        task.job := job
        TtsFixtureClient.CurrentTask := task
        TtsFixtureClient.OnToolboxExit()
        AssertEqual(true, job.HandlesClosed, "normal toolbox exit releases the running job")
        AssertEqual(0, ProcessExist(job.Pid), "normal toolbox exit stops the running process")
        AssertEqual(false, DirExist(task.directory) != "", "normal toolbox exit cleans the request directory")
    } finally {
        if IsObject(job)
            job.Dispose()
        if (childPid && ProcessExist(childPid))
            ProcessClose childPid
        TtsFixtureClient.ClearPidWatch()
        if (TtsFixtureClient.ExitBound != savedExit && TtsFixtureClient.ExitBound != "")
            OnExit TtsFixtureClient.ExitBound, 0
        TtsFixtureClient.ExitBound := savedExit
        TtsFixtureClient.CurrentTask := savedTask, TtsFixtureClient.RetiredTasks := savedRetired
        TtsFixtureClient.Generation := savedGeneration, TtsFixtureClient.LastOutcome := savedOutcome
        TtsFixtureClient.TtsPid := 0, TtsFixtureClient.LastInputFile := ""
        for file in [ownedTemp, unrelatedTemp] {
            if (file != "" && FileExist(file))
                FileDelete file
        }
        resolved := NotifyPaths.Expand(root)
        if (InStr(resolved, NotifyPaths.Expand(A_Temp) "\") = 1 && InStr(resolved, "\toolbox-tts-jobs-") > 0)
            DirDelete resolved, true
    }
}
