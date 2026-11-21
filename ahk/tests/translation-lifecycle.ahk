class TranslationUnresponsiveJob {
    Done := false
    HandlesClosed := false
    Disposed := false
    Cancel() {
    }
    Poll() {
    }
    Dispose() {
        this.Disposed := true
        this.Done := true
        this.HandlesClosed := true
    }
}

class TranslationShutdownClient extends TranslateSelectedText {
    static Log(message) {
    }
}

TranslationLifecycleTests() {
    root := A_Temp "\toolbox-translation-exit-" SmartPaste.NewGuid()
    DirCreate root
    SplitPath A_LineFile, , &testDir
    worker := 'import argparse,pathlib,subprocess,sys,time`n'
        . 'p=argparse.ArgumentParser();p.add_argument("--input-file");p.add_argument("--output-file");a,_=p.parse_known_args()`n'
        . 'with open(a.input_file,encoding="utf-8-sig") as held:`n'
        . '    child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"],creationflags=0x08000000)`n'
        . '    pathlib.Path(a.output_file).write_text("status=ok\nengine=fixture\ncached=0\ntext=pending",encoding="utf-8")`n'
        . '    pathlib.Path(__file__).with_name("ready.txt").write_text(str(child.pid),encoding="utf-8")`n'
        . '    time.sleep(60)`n'
    job := 0
    try {
        for mode in ["exit", "cancel", "shutdown"] {
            directory := root "\" mode " with spaces"
            DirCreate directory
            FileAppend worker, directory "\worker.py", "UTF-8-RAW"
            command := '"' A_AhkPath '" /ErrorStdOut=UTF-8 "' testDir '\translation-exit-fixture.ahk" --test "' directory '" ' mode
            job := ProcessNoWindow.StartAsync(command, directory "\stdout.txt", 15000, true)
            while !job.Done {
                job.Poll()
                Sleep 10
            }
            AssertEqual("exited", job.Status, "translation lifecycle fixture exits within its budget: " mode)
            AssertEqual(0, job.ExitCode, "translation lifecycle fixture succeeds: " mode)
            report := FileRead(directory "\report.txt", "UTF-8")
            for field in ["handles_closed", "job_done", "job_assigned"]
                AssertEqual("1", TranslateSelectedText.ParseField(report, field), "translation exit has real job ownership and closed handles: " mode " " field)
            for field in ["tasks", "input_present", "output_present", "child_alive", "deliveries"]
                AssertEqual("0", TranslateSelectedText.ParseField(report, field), "translation exit is quiet and leaves no task/private file/child: " mode " " field)
            if (mode = "shutdown")
                AssertEqual("1", TranslateSelectedText.ParseField(report, "blocked"), "shutdown is idempotent and blocks late translation starts")
            loop files directory "\*", "F"
                FileDelete A_LoopFileFullPath
            DirDelete directory
        }

        ; A non-signalling job cannot keep shutdown waiting without a bound.
        entry := TranslationShutdownClient
        entry.RequestGate := TranslationRequestGate(), entry.ShuttingDown := false
        entry.ShutdownBudgetMs := 30, entry.Tasks := []
        for index in [1, 2] {
            task := {id: index, job: TranslationUnresponsiveJob(), inputFile: root "\in-" index, outputFile: root "\out-" index}
            FileAppend "owned input", task.inputFile
            FileAppend "owned output", task.outputFile
            entry.Tasks.Push(task)
        }
        tasks := entry.Tasks
        entry.CurrentTask := tasks[2]
        entry.RequestGate.Begin()
        entry.Shutdown()
        entry.Shutdown()
        AssertEqual(0, entry.Tasks.Length, "bounded shutdown drains current and previously pending tasks")
        AssertEqual(0, entry.RequestGate.CurrentId, "shutdown rejects late completion identity")
        AssertEqual("", entry.PollTimer, "shutdown disables the result timer")
        AssertEqual(0, entry.TranslateText("late input"), "shutdown rejects new work before file/process side effects")
        for task in tasks {
            AssertEqual(true, task.job.Disposed && task.job.HandlesClosed, "expired shutdown budget disposes each job")
            AssertEqual(false, !!FileExist(task.inputFile) || !!FileExist(task.outputFile), "forced disposal still cleans owned files")
        }
    } finally {
        if IsObject(job)
            job.Dispose()
        ; All children/files are individually owned and removed above.
        try DirDelete root
    }
}

TranslationLifecycleTests()
