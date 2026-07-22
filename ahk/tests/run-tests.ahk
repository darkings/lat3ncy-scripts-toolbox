#Requires AutoHotkey v2.0
#Include ..\main.ahk

; Task 1 contract harness. Run via run-tests.ps1 so stale results are removed and
; AutoHotkey parse/include failures cannot be mistaken for a passing test run.
resultFile := A_Args.Length >= 2 ? A_Args[2] : A_Temp "\lat3ncy-toolbox-test-result.txt"
if FileExist(resultFile)
    FileDelete resultFile

AssertEqual(expected, actual, name) {
    global resultFile
    if (expected !== actual) {
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

AssertThrows(callback, expectedMessage, name) {
    global resultFile
    try callback.Call()
    catch as caught {
        if !(caught is Error) {
            FileAppend "FAIL: " name "`nExpected an Error, got: " Type(caught) "`n", resultFile
            ExitApp 1
        }
        if !InStr(caught.Message, expectedMessage) {
            FileAppend "FAIL: " name "`nExpected error containing: " expectedMessage "`nActual: " caught.Message "`n", resultFile
            ExitApp 1
        }
        return
    }
    FileAppend "FAIL: " name "`nExpected an exception`n", resultFile
    ExitApp 1
}

AssertEqual("toggle-input", CapsLockIme.Action(false, 100), "CapsLock short press")
AssertEqual("enable-caps", CapsLockIme.Action(false, 500), "CapsLock long press")
AssertEqual("disable-caps-force-english", CapsLockIme.Action(true, 100), "CapsLock unlock")
AssertEqual(456, CapsLockIme.ResolveFocusedHwnd(456, 123), "focused HWND wins")
AssertEqual(123, CapsLockIme.ResolveFocusedHwnd(0, 123), "active HWND fallback")
AssertEqual(true, HasMethod(CapsLockIme, "HideTip"), "CapsLock stable tooltip callback")
AssertEqual(true, HasMethod(AlwaysOnTop, "HideTip"), "always-on-top stable tooltip callback")
AssertEqual(true, HasMethod(ToggleHiddenFiles, "HideTip"), "hidden-files stable tooltip callback")
AssertEqual("BoundFunc", Type(CapsLockIme.HotkeyCallback), "CapsLock bound hotkey callback")
AssertEqual("BoundFunc", Type(AlwaysOnTop.HotkeyCallback), "always-on-top bound hotkey callback")
AssertEqual("BoundFunc", Type(ToggleHiddenFiles.HotkeyCallback), "hidden-files bound hotkey callback")
AssertEqual(true, CapsLockIme.HotkeyCallback.Call("test", receiver => receiver == CapsLockIme), "CapsLock callback this")
AssertEqual(true, AlwaysOnTop.HotkeyCallback.Call("test", receiver => receiver == AlwaysOnTop), "always-on-top callback this")
AssertEqual(true, ToggleHiddenFiles.HotkeyCallback.Call("test", receiver => receiver == ToggleHiddenFiles), "hidden-files callback this")
AssertEqual("BoundFunc", Type(CapsLockIme.HideTipCallback), "CapsLock bound tooltip callback")
AssertEqual("BoundFunc", Type(AlwaysOnTop.HideTipCallback), "always-on-top bound tooltip callback")
AssertEqual("BoundFunc", Type(ToggleHiddenFiles.HideTipCallback), "hidden-files bound tooltip callback")
CapsLockIme.HideTipCallback.Call()
AlwaysOnTop.HideTipCallback.Call()
ToggleHiddenFiles.HideTipCallback.Call()
AssertEqual("D:\Code\main.py", OpenSelectedTarget.Normalize('  "D:\Code\main.py:25:8"  '), "normalize target")
AssertEqual("D:\Code\main.py", LocateSelectedTarget.Normalize("file:///D:/Code/main.py"), "normalize file URL")
AssertEqual("plain-text", SmartPaste.ChooseAction(false, false, true, false), "plain text")
AssertEqual("save-image", SmartPaste.ChooseAction(false, true, false, true), "Explorer image")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, true, false, false), "application image")
AssertEqual("normal-paste", SmartPaste.ChooseAction(true, true, true, true), "file list wins")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, false, false, false), "unknown clipboard")
shortcutRegistry := Map()
ValidateFeatureHotkey("first", "^!a", shortcutRegistry)
AssertThrows(() => ValidateFeatureHotkey("duplicate", "^!a", shortcutRegistry), "快捷键冲突", "duplicate shortcut")
AssertThrows(() => ValidateFeatureHotkey("second", "!^a", shortcutRegistry), "快捷键冲突", "equivalent modifier order")
AssertThrows(() => ValidateFeatureHotkey("empty", "", Map()), "不能为空", "empty shortcut")
directionalRegistry := Map()
ValidateFeatureHotkey("directional", "~*$<^>!A", directionalRegistry)
AssertThrows(() => ValidateFeatureHotkey("directional duplicate", "$*~>!<^a", directionalRegistry), "快捷键冲突", "directional modifiers")
sidedRegistry := Map()
ValidateFeatureHotkey("generic control", "^a", sidedRegistry)
ValidateFeatureHotkey("left control", "<^a", sidedRegistry)
identityRegistry := Map()
ValidateFeatureHotkey("plain", "^a", identityRegistry)
AssertThrows(() => ValidateFeatureHotkey("tilde", "~^a", identityRegistry), "快捷键冲突", "tilde callback identity")
AssertThrows(() => ValidateFeatureHotkey("dollar", "$^a", identityRegistry), "快捷键冲突", "dollar callback identity")
ValidateFeatureHotkey("wildcard", "*^a", identityRegistry)

FileAppend "PASS: core assertions`n", resultFile
ExitApp 0
