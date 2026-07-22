#Requires AutoHotkey v2.0
#Include ..\main.ahk

resultFile := A_Temp "\lat3ncy-toolbox-test-result.txt"
if FileExist(resultFile)
    FileDelete resultFile

AssertEqual(expected, actual, name) {
    global resultFile
    if (expected != actual) {
        FileAppend "FAIL: " name "`nExpected: " expected "`nActual: " actual "`n", resultFile
        ExitApp 1
    }
}

AssertContains(haystack, needle, name) {
    global resultFile
    if !InStr(haystack, needle) {
        FileAppend "FAIL: " name "`nMissing: " needle "`n", resultFile
        ExitApp 1
    }
}

AssertThrows(callback, name) {
    global resultFile
    try callback.Call()
    catch
        return
    FileAppend "FAIL: " name "`nExpected an exception`n", resultFile
    ExitApp 1
}

AssertEqual("toggle-input", CapsLockIme.Action(false, 100), "CapsLock short press")
AssertEqual("enable-caps", CapsLockIme.Action(false, 500), "CapsLock long press")
AssertEqual("disable-caps-force-english", CapsLockIme.Action(true, 100), "CapsLock unlock")
AssertEqual("D:\Code\main.py", OpenSelectedTarget.Normalize('  "D:\Code\main.py:25:8"  '), "normalize target")
AssertEqual("D:\Code\main.py", LocateSelectedTarget.Normalize("file:///D:/Code/main.py"), "normalize file URL")
AssertEqual("plain-text", SmartPaste.ChooseAction(false, false, true, false), "plain text")
AssertEqual("save-image", SmartPaste.ChooseAction(false, true, false, true), "Explorer image")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, true, false, false), "application image")
AssertEqual("normal-paste", SmartPaste.ChooseAction(true, true, true, true), "file list wins")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, false, false, false), "unknown clipboard")
shortcutRegistry := Map()
ValidateFeatureHotkey("first", "^!a", shortcutRegistry)
AssertThrows(() => ValidateFeatureHotkey("duplicate", "^!a", shortcutRegistry), "duplicate shortcut")
AssertThrows(() => ValidateFeatureHotkey("empty", "", Map()), "empty shortcut")

FileAppend "PASS: core assertions`n", resultFile
ExitApp 0
