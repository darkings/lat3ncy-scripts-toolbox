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

AssertNotContains(haystack, needle, name) {
    global resultFile
    if InStr(haystack, needle) {
        FileAppend "FAIL: " name "`nUnexpected: " needle "`n", resultFile
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

mainSource := FileRead(A_ScriptDir "\..\main.ahk", "UTF-8")
startupTruePosition := InStr(mainSource, "global ToolboxStarting := true")
startupHandlerPosition := InStr(mainSource, "OnError ToolboxStartupErrorHandler")
firstFeatureIncludePosition := InStr(mainSource, "#Include features\caps-lock-ime.ahk")
lastFeatureIncludePosition := InStr(mainSource, "#Include features\toggle-hidden-files.ahk")
startupFalsePosition := InStr(mainSource, "`nToolboxStarting := false")
AssertEqual(true, startupTruePosition > 0, "startup flag exists")
AssertEqual(true, startupHandlerPosition > startupTruePosition, "startup handler follows flag")
AssertEqual(true, startupHandlerPosition < firstFeatureIncludePosition, "startup handler precedes feature includes")
AssertEqual(true, startupFalsePosition > lastFeatureIncludePosition, "startup flag clears after feature includes")
AssertEqual(false, ToolboxStarting, "startup flag cleared after successful includes")
AssertEqual(false, HandleToolboxError(Error("runtime"), "test"), "runtime errors use default behavior")

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
AssertEqual("normal-paste", SmartPaste.ChooseAction(true, false, true, true), "file list without image wins")
AssertEqual("plain-text", SmartPaste.ChooseAction(false, false, true, true), "Explorer text remains plain text")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, false, false, false), "unknown clipboard")
AssertEqual('"C:\\"', SmartPaste.QuoteArgument("C:\"), "quote root destination safely")
AssertEqual(true, HasMethod(SmartPaste, "EnsureHelperAvailable"), "smart paste exposes helper validation")
realSmartPasteHelper := A_ScriptDir "\..\features\smart-paste\save-clipboard-image.ps1"
AssertEqual(realSmartPasteHelper, SmartPaste.EnsureHelperAvailable(realSmartPasteHelper), "smart paste helper exists")
missingSmartPasteHelper := A_Temp "\lat3ncy-missing-smart-paste-helper-" SmartPaste.NewGuid() ".ps1"
AssertThrows(
    () => SmartPaste.EnsureHelperAvailable(missingSmartPasteHelper),
    "智能粘贴辅助脚本不存在",
    "smart paste missing helper fails early")
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
AssertEqual("https://example.com/a", OpenSelectedTarget.Normalize("https://example.com/a"), "preserve URL target")
AssertEqual("url", OpenSelectedTarget.Classify("https://example.com/a"), "classify URL target")
AssertEqual("hello%20%E4%B8%AD%E6%96%87", SearchSelectedText.UriEncode("hello 中文"), "UTF-8 URI encoding")
AssertEqual("main.py", OpenSelectedTarget.TargetLabel("D:\Code\main.py"), "open target label")
AssertEqual("main.py", LocateSelectedTarget.TargetLabel("D:\Code\main.py"), "locate target label")
for targetClass in [OpenSelectedTarget, LocateSelectedTarget] {
    AssertEqual("D:\Code\main.py", targetClass.Normalize("file:///D:/Code/main.py"), "existing local file URI")
    AssertEqual("C:\Program Files\a.txt", targetClass.Normalize("file:///C:/Program%20Files/a.txt"), "escaped local file URI")
    AssertEqual("\\server\share\a b.txt", targetClass.Normalize("file://server/share/a%20b.txt"), "escaped UNC file URI")
    AssertEqual("C:\中文\a.txt", targetClass.Normalize("file:///C:/%E4%B8%AD%E6%96%87/a.txt"), "UTF-8 local file URI")
    AssertEqual("\\server\share\中文.txt", targetClass.Normalize("file://server/share/%E4%B8%AD%E6%96%87.txt"), "UTF-8 UNC file URI")
}
for featureClass in [SearchSelectedText, SmartPaste, OpenSelectedTarget, LocateSelectedTarget] {
    AssertEqual("BoundFunc", Type(featureClass.HotkeyCallback), "selected action bound hotkey callback")
    AssertEqual("BoundFunc", Type(featureClass.HideTipCallback), "selected action bound tooltip callback")
    AssertEqual(true, featureClass.HotkeyCallback == featureClass.HotkeyCallback, "selected action stable hotkey callback")
    AssertEqual(true, featureClass.HideTipCallback == featureClass.HideTipCallback, "selected action stable tooltip callback")
    AssertEqual(true, featureClass.HotkeyCallback.Call("test", receiver => receiver == featureClass), "selected action callback this")
    featureClass.HideTipCallback.Call()
}
searchSource := FileRead(A_ScriptDir "\..\features\search-selected-text.ahk", "UTF-8")
openSource := FileRead(A_ScriptDir "\..\features\open-selected-target.ahk", "UTF-8")
locateSource := FileRead(A_ScriptDir "\..\features\locate-selected-target.ahk", "UTF-8")
smartPasteSource := FileRead(A_ScriptDir "\..\features\smart-paste\smart-paste.ahk", "UTF-8")
smartPasteHelperSource := FileRead(A_ScriptDir "\..\features\smart-paste\save-clipboard-image.ps1", "UTF-8")
AssertNotContains(searchSource, "OpenSelectedTarget", "search does not depend on open")
AssertNotContains(searchSource, "LocateSelectedTarget", "search does not depend on locate")
AssertNotContains(openSource, "SearchSelectedText", "open does not depend on search")
AssertNotContains(openSource, "LocateSelectedTarget", "open does not depend on locate")
AssertNotContains(locateSource, "SearchSelectedText", "locate does not depend on search")
AssertNotContains(locateSource, "OpenSelectedTarget", "locate does not depend on open")
AssertContains(searchSource, "打开搜索失败", "search Run failure hint")
AssertContains(openSource, "打开目标失败", "open Run failure hint")
AssertContains(locateSource, "定位目标失败", "locate Run failure hint")
AssertContains(smartPasteSource, '"UInt", 15', "smart paste detects CF_HDROP")
AssertContains(smartPasteSource, 'RegisterClipboardFormatW', "smart paste registers PNG clipboard format")
AssertContains(smartPasteSource, 'A_ScriptDir "\features\smart-paste\save-clipboard-image.ps1"', "smart paste helper path uses entry directory")
AssertContains(smartPasteSource, 'Send "^v"', "smart paste keeps ordinary paste fallback")
AssertContains(smartPasteSource, 'ObjBindMethod(SmartPaste, "Paste")', "smart paste binds hotkey callback")
AssertContains(smartPasteSource, 'ObjBindMethod(SmartPaste, "HideTip")', "smart paste binds tooltip callback")
smartPasteStartupSource := SubStr(smartPasteSource, InStr(smartPasteSource, "if !IsToolboxTestMode()"))
startupEnsurePosition := InStr(smartPasteStartupSource, "SmartPaste.EnsureHelperAvailable()")
startupRegisterPosition := InStr(smartPasteStartupSource, 'RegisterFeatureHotkey("智能粘贴"')
AssertEqual(true, startupEnsurePosition > 0, "smart paste startup validates helper")
AssertEqual(true, startupEnsurePosition < startupRegisterPosition, "smart paste validates helper before registration")
AssertContains(smartPasteHelperSource, '[IO.FileMode]::CreateNew', "image helper allocates unique temp file")
AssertContains(smartPasteHelperSource, '[IO.File]::Move(', "image helper atomically publishes PNG")
AssertContains(smartPasteHelperSource, '$stream.Length -le 0', "image helper rejects empty PNG")
AssertContains(smartPasteHelperSource, '[Text.UTF8Encoding]::new($false)', "image helper writes UTF-8 without BOM")
AssertContains(smartPasteHelperSource, 'GetDataObject()', "image helper reads clipboard data object")
AssertContains(smartPasteHelperSource, "GetDataPresent('PNG')", "image helper detects registered PNG data")
AssertContains(smartPasteHelperSource, "GetData('PNG')", "image helper reads registered PNG data")
AssertContains(smartPasteHelperSource, '[Drawing.Image]::FromStream', "image helper decodes registered PNG stream")
AssertNotContains(smartPasteHelperSource, 'Remove-Item -LiteralPath $outputPath', "image helper never removes published output")

FileAppend "PASS: core assertions`n", resultFile
ExitApp 0
