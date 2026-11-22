#Requires AutoHotkey v2.0
#Warn VarUnset, StdOut
#Include ..\main.ahk
#SingleInstance Off

; Child of the headless test runner. Fixed text, no UI/network/audio.
if (A_Args.Length != 3 || A_Args[1] != "--test")
    ExitApp 2
global TranslationFixtureRoot := A_Args[2]
global TranslationFixtureMode := A_Args[3]
global TranslationFixtureTask := 0
global TranslationFixtureChild := 0
global TranslationFixtureBlocked := false

class TranslationExitFixture extends TranslateSelectedText {
    static Deliveries := 0
    static ResolveScript() => TranslationFixtureRoot "\worker.py"
    static ResolveConfig() => TranslationFixtureRoot "\missing-config.toml"
    static LogPath() => TranslationFixtureRoot "\translation.log"
    static RequestRoot() => TranslationFixtureRoot "\requests"
}

TranslationExitObserve(*) {
    task := TranslationFixtureTask
    if !IsObject(task)
        return 0
    deadline := A_TickCount + 500
    while (TranslationFixtureChild && ProcessExist(TranslationFixtureChild) && A_TickCount < deadline)
        Sleep 10
    data := "handles_closed=" task.job.HandlesClosed "`njob_done=" task.job.Done "`njob_assigned=" task.job.AssignedToJob "`nworker_pid=" task.job.Pid
        . "`ntasks=" TranslationExitFixture.Tasks.Length "`ninput_present=" (!!FileExist(task.inputFile))
        . "`noutput_present=" (!!FileExist(task.outputFile)) "`nchild_alive=" (!!ProcessExist(TranslationFixtureChild))
        . "`ndeliveries=" TranslationExitFixture.Deliveries "`nblocked=" TranslationFixtureBlocked
        . "`ninput_file=" task.inputFile "`noutput_file=" task.outputFile "`n"
    FileAppend data, TranslationFixtureRoot "\report.txt", "UTF-8-RAW"
    return 0
}

TranslationExitFixture.Hooks := Map("open", (text, x, y) => true, "panelOpen", () => true,
    "result", (text) => TranslationExitFixture.Deliveries += 1,
    "error", (message) => TranslationExitFixture.Deliveries += 1)

; Keep the timer from consuming the deliberately unfinished task before exit.
Critical true
TranslationExitFixture.TranslateText("fixed shutdown fixture", 0, 0, true)
TranslationFixtureTask := TranslationExitFixture.CurrentTask
if !IsObject(TranslationFixtureTask)
    ExitApp 3
deadline := A_TickCount + 5000
while (!FileExist(TranslationFixtureRoot "\ready.txt") && A_TickCount < deadline)
    Sleep 10
if !FileExist(TranslationFixtureRoot "\ready.txt")
    ExitApp 4
TranslationFixtureChild := Integer(Trim(FileRead(TranslationFixtureRoot "\ready.txt", "UTF-8")))
OnExit TranslationExitObserve

if (TranslationFixtureMode = "cancel") {
    TranslationExitFixture.CancelCurrent()
    deadline := A_TickCount + 5000
    while (TranslationExitFixture.Tasks.Length && A_TickCount < deadline) {
        TranslationExitFixture.Poll()
        Sleep 10
    }
} else if (TranslationFixtureMode = "shutdown") {
    TranslationExitFixture.Shutdown()
    TranslationExitFixture.Shutdown()
    TranslationFixtureBlocked := TranslationExitFixture.TranslateText("late input") = 0
}
ExitApp 0
