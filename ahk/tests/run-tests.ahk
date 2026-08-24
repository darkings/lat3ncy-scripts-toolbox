#Requires AutoHotkey v2.0
#Include ..\main.ahk

; Task 1 contract harness. Run via run-tests.ps1 so stale results are removed and
; AutoHotkey parse/include failures cannot be mistaken for a passing test run.
resultFile := A_Args.Length >= 2 ? A_Args[2] : A_Temp "\lat3ncy-toolbox-test-result.txt"
if FileExist(resultFile)
    FileDelete resultFile

OnError (e, mode) => (FileAppend("FAIL: Unhandled exception at line " e.Line ": " e.Message "`n" e.Stack "`n", resultFile), ExitApp(1))

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

EventSequence(events) {
    sequence := ""
    for event in events
        sequence .= (sequence ? "->" : "") event
    return sequence
}

class FakeSmartPasteCopyRecorder {
    __New(events) {
        this.events := events
        this.shortcut := ""
    }

    Call(shortcut) {
        this.events.Push("Send")
        this.shortcut := shortcut
    }
}

class FakeSmartPasteClipboard {
    __New(copyValue, waitResult := true, throwOnWait := false, events := unset) {
        this.copyValue := copyValue
        this.waitResult := waitResult
        this.throwOnWait := throwOnWait
        this.events := IsSet(events) ? events : []
        this.waitTimeout := unset
        this.restored := false
        this.restoredValue := ""
    }

    Capture() {
        this.events.Push("Capture")
        return "original-image"
    }

    Clear() {
        this.events.Push("Clear")
    }

    ReadText() {
        this.events.Push("ReadText")
        return this.copyValue
    }

    Wait(timeoutSeconds) {
        this.waitTimeout := timeoutSeconds
        this.events.Push("Wait")
        if this.throwOnWait
            throw Error("simulated clipboard failure")
        return this.waitResult
    }

    Restore(snapshot) {
        this.events.Push("Restore")
        this.restored := true
        this.restoredValue := snapshot
    }
}

mainSource := FileRead(A_ScriptDir "\..\main.ahk", "UTF-8")
startupTruePosition := InStr(mainSource, "global ToolboxStarting := true")
startupHandlerPosition := InStr(mainSource, "OnError ToolboxStartupErrorHandler")
rendererIncludePosition := InStr(mainSource, "#Include ..\shared\notify\renderer.ahk")
notifyIncludePosition := InStr(mainSource, "#Include ..\shared\notify\notify.ahk")
firstFeatureIncludePosition := InStr(mainSource, "#Include features\caps-lock-ime.ahk")
lastFeatureIncludePosition := InStr(mainSource, "#Include features\foreground-process.ahk")
routerIncludePosition := InStr(mainSource, "#Include hotkey-router.ahk")
startupFalsePosition := InStr(mainSource, "`nToolboxStarting := false")
AssertEqual(true, startupTruePosition > 0, "startup flag exists")
AssertEqual(true, startupHandlerPosition > startupTruePosition, "startup handler follows flag")
AssertEqual(true, rendererIncludePosition > startupHandlerPosition, "renderer loads after startup handler")
AssertEqual(true, notifyIncludePosition > rendererIncludePosition, "notify API loads after renderer")
AssertEqual(true, firstFeatureIncludePosition > notifyIncludePosition, "features load after shared notify")
AssertEqual(true, startupHandlerPosition < firstFeatureIncludePosition, "startup handler precedes feature includes")
AssertEqual(true, routerIncludePosition > lastFeatureIncludePosition, "router loads after all features")
AssertEqual(true, startupFalsePosition > routerIncludePosition, "startup flag clears after router")
AssertEqual(false, ToolboxStarting, "startup flag cleared after successful includes")
AssertEqual(false, HandleToolboxError(Error("runtime"), "test"), "runtime errors use default behavior")

AssertEqual(true, HasMethod(CapsLockIme, "Handle"), "CapsLock handle method exists")
AssertEqual("BoundFunc", Type(CapsLockIme.HotkeyCallback), "CapsLock bound hotkey callback")
AssertEqual("BoundFunc", Type(CapsLockIme.KeyUpCallback), "CapsLock bound key-up callback")
AssertEqual("BoundFunc", Type(CapsLockIme.LongPressCallback), "CapsLock bound long-press callback")
AssertEqual("BoundFunc", Type(AlwaysOnTop.HotkeyCallback), "always-on-top bound hotkey callback")
AssertEqual("BoundFunc", Type(HideActiveWindow.HotkeyCallback), "hide-window bound hotkey callback")
AssertEqual("BoundFunc", Type(ToggleHiddenFiles.HotkeyCallback), "hidden-files bound hotkey callback")
AssertEqual("BoundFunc", Type(ToggleFileExtensions.HotkeyCallback), "file-extensions bound hotkey callback")
AssertEqual("BoundFunc", Type(ForegroundProcess.KillCallback), "kill-process bound hotkey callback")
AssertEqual("BoundFunc", Type(ForegroundProcess.RestartCallback), "restart-process bound hotkey callback")
AssertEqual(true, CapsLockIme.HotkeyCallback.Call("test", receiver => receiver == CapsLockIme), "CapsLock callback this")
AssertEqual(true, AlwaysOnTop.HotkeyCallback.Call("test", receiver => receiver == AlwaysOnTop), "always-on-top callback this")
AssertEqual(true, HideActiveWindow.HotkeyCallback.Call("test", receiver => receiver == HideActiveWindow), "hide-window callback this")
AssertEqual(true, ToggleHiddenFiles.HotkeyCallback.Call("test", receiver => receiver == ToggleHiddenFiles), "hidden-files callback this")
AssertEqual(true, ToggleFileExtensions.HotkeyCallback.Call("test", receiver => receiver == ToggleFileExtensions), "file-extensions callback this")
AssertEqual(true, ForegroundProcess.KillCallback.Call("test", receiver => receiver == ForegroundProcess), "kill-process callback this")
AssertEqual(true, ForegroundProcess.RestartCallback.Call("test", receiver => receiver == ForegroundProcess), "restart-process callback this")
AssertEqual("BoundFunc", Type(NotifyRenderer.HideCallback), "renderer stable hide callback")
AssertEqual("BoundFunc", Type(Notify.ToolTipHideCallback), "notify stable fallback callback")
AssertEqual("252525", NotifyRenderer.BackgroundColor, "renderer owns background color")
AssertEqual(0.82, NotifyRenderer.PositionYRatio, "renderer owns vertical position")
AssertEqual(22, NotifyRenderer.BadgeSize, "renderer owns badge size")
AssertEqual(4, NotifyRenderer.ChipRadius, "chip uses small flyout radius")
AssertEqual(28, NotifyRenderer.ChipSize, "chip size stays 28")
AssertEqual(12, NotifyRenderer.StateChip["中"]["size"], "state 中 size stays 12")
AssertEqual(12, NotifyRenderer.StateChip["A"]["size"], "state A size stays 12")
AssertEqual(12, NotifyRenderer.StateChip["⇪"]["size"], "state caps size stays 12")
AssertEqual(600, NotifyRenderer.StateChip["中"]["weight"], "state 中 weight stays 600")
AssertEqual(600, NotifyRenderer.StateChip["A"]["weight"], "state A weight stays 600")
AssertEqual(600, NotifyRenderer.StateChip["⇪"]["weight"], "state caps weight stays 600")
AssertEqual("2C2C2C", NotifyRenderer.DarkTheme.ChipBg, "dark chip fill")
AssertEqual("F3F3F3", NotifyRenderer.LightTheme.ChipBg, "light chip fill")
AssertEqual(0x00333333, NotifyRenderer.DarkTheme.ChipBorderDwm, "dark chip hairline")
AssertEqual(0x00E5E5E5, NotifyRenderer.LightTheme.ChipBorderDwm, "light chip hairline")
AssertEqual(8, NotifyRenderer.Radius, "renderer owns radius")
AssertEqual(11, NotifyRenderer.TextSize, "renderer owns text size")
AssertEqual(10, NotifyRenderer.IconSize, "renderer owns icon size")
AssertEqual(16, NotifyRenderer.PaddingX, "renderer owns padding")
AssertEqual("2B2B2B", NotifyRenderer.TypeBadgeBg["state"], "renderer owns state badge")
AssertEqual("3FB950", NotifyRenderer.TypeIconColor["success"], "renderer owns success icon color")
AssertEqual(true, NotifyRenderer.IconMap.Has("✓"), "renderer owns fluent icon map")
AssertEqual(true, NotifyRenderer.IconMap.Has("−"), "renderer owns minus icon map")
AssertEqual(true, NotifyRenderer.IconMap.Has("🔍"), "renderer owns search icon map")
AssertEqual(true, NotifyRenderer.IconMap.Has("🔊"), "renderer owns sound icon map")
AssertEqual(true, NotifyRenderer.IconMap.Has("📌"), "renderer owns pin icon map")
AssertEqual(4, Notify.PriorityMap["error"], "notify priority map owns error level")
AssertEqual(1, Notify.PriorityMap["state"], "notify priority map owns state level")

originalNotifyMode := Notify.Mode
Notify.Mode := "full"
AssertEqual(true, Notify.ShouldShow("state"), "full mode shows state")
Notify.Mode := "errors"
AssertEqual(false, Notify.ShouldShow("state"), "errors mode hides state")
AssertEqual(true, Notify.ShouldShow("error"), "errors mode shows errors")
Notify.Mode := "off"
AssertEqual(false, Notify.ShouldShow("error"), "off mode hides errors")
Notify.Mode := originalNotifyMode

AssertEqual(250, CapsLockIme.TapMaxMs, "Caps short-press ceiling stays 250ms")
AssertEqual(500, CapsLockIme.HoldThreshold, "Caps long-press threshold stays 500ms")
AssertEqual(180, CapsLockIme.ChordImeLockoutMs, "Caps IME lockout after chord stays 180ms")
AssertEqual(true, HasMethod(CapsLockIme, "AbortCapsModeForChord"), "Caps can abort caps-mode for a late chord")

CapsLockIme._pressed := true
CapsLockIme._chordUsed := false
CapsLockIme._exitingCaps := false
AssertEqual(true, MarkCapsChordUsed(), "Caps chord marker accepts active press")
AssertEqual(true, CapsLockIme._chordUsed, "Caps chord marker records usage")
AssertEqual(true, CapsLockIme._imeLockoutUntil >= A_TickCount, "Caps chord sets IME lockout")
CapsLockIme._pressed := false
CapsLockIme._chordUsed := false

CapsLockIme._pressed := true
CapsLockIme._exitingCaps := true
AssertEqual(false, MarkCapsChordUsed(), "exit-caps press rejects tool chords")
AssertEqual(false, CapsLockIme._chordUsed, "rejected exit-caps press does not mark chord")
CapsLockIme._pressed := false
CapsLockIme._exitingCaps := false
CapsLockIme._chordUsed := false

; CapsLock KeyDown / KeyUp 完整生命周期调用测试（防范缺少方法或异常抛出）
CapsLockIme.OnKeyDown()
AssertEqual(true, CapsLockIme._pressed, "CapsLock OnKeyDown sets pressed state")
CapsLockIme.OnKeyDown() ; 模拟长按重复触发过滤
AssertEqual(true, CapsLockIme._pressed, "CapsLock repeated KeyDown is filtered")
CapsLockIme.OnKeyUp()
AssertEqual(false, CapsLockIme._pressed, "CapsLock OnKeyUp clears pressed state")

; 犹豫后松开：超过短按、未到长按，不切输入法。
CapsLockIme.OnKeyDown()
CapsLockIme._downTick := A_TickCount - 300
CapsLockIme.OnKeyUp()
AssertEqual("idle", CapsLockIme._lastReleaseAction, "hesitation release does not toggle IME")
AssertEqual(false, CapsLockIme._pressed, "hesitation release clears pressed state")

; CapsLock chord 使用后松开
CapsLockIme.OnKeyDown()
CapsLockIme.MarkChordUsed()
AssertEqual(true, CapsLockIme._chordUsed, "CapsLock chord marked")
CapsLockIme.OnKeyUp()
AssertEqual(false, CapsLockIme._pressed, "CapsLock OnKeyUp after chord clears pressed state")
AssertEqual(false, CapsLockIme._chordUsed, "CapsLock OnKeyUp resets chord state")
AssertEqual("idle", CapsLockIme._lastReleaseAction, "chord release does not toggle IME")

AssertEqual("D:\Code\main.py", OpenSelectedTarget.Normalize('  "D:\Code\main.py:25:8"  '), "normalize target")
AssertEqual("D:\Code\main.py", LocateSelectedTarget.Normalize("file:///D:/Code/main.py"), "normalize file URL")
AssertEqual("$^v", Shortcuts.SmartPaste, "Smart Paste intercepts Ctrl+V without recursion")
AssertEqual("+!c", Shortcuts.VsCodeCopyPath, "VS Code Copy Path shortcut")
AssertEqual("+!c", Shortcuts.ZedCopyPath, "Zed Copy Path shortcut")
AssertEqual("!sc029", Shortcuts.SwitchAppWindowNext, "same-app window forward shortcut")
AssertEqual("+!sc029", Shortcuts.SwitchAppWindowPrevious, "same-app window backward shortcut")
AssertEqual(2, SwitchAppWindow.StepIndex(1, 3, 1), "same-app window steps forward")
AssertEqual(1, SwitchAppWindow.StepIndex(3, 3, 1), "same-app window wraps forward")
AssertEqual(3, SwitchAppWindow.StepIndex(1, 3, -1), "same-app window wraps backward")
AssertEqual(true, SwitchAppWindow.Contains([10, 20, 30], 20), "same-app snapshot contains HWND")
AssertEqual(false, SwitchAppWindow.Contains([10, 20, 30], 40), "same-app snapshot excludes HWND")
AssertEqual("{F13}", SwitchAppWindow.SingleWindowShortcut("Zed.exe", 1), "Zed single window steps forward")
AssertEqual("{F14}", SwitchAppWindow.SingleWindowShortcut("zed.exe", -1), "Zed single window steps backward")
AssertEqual("", SwitchAppWindow.SingleWindowShortcut("Code.exe", 1), "other single-window apps do not fall back")
AssertEqual("normal-paste", SmartPaste.ChooseAction(true, true, true, false), "file list wins over image")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, false, true, false), "non-image Explorer paste stays native")
AssertEqual("save-explorer-image", SmartPaste.ChooseAction(false, true, true, false), "Explorer image saves")
AssertEqual("probe-copy-path-image", SmartPaste.ChooseAction(false, true, false, true), "VS Code image probes selected folder")
AssertEqual("probe-copy-path-image", SmartPaste.ChooseAction(false, true, false, true), "Zed image probes selected folder")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, true, false, false), "other application image stays native")
vsCodeTestRoot := A_Args.Length >= 3
    ? A_Args[3]
    : A_Temp "\lat3ncy-vscode-folder-" SmartPaste.NewGuid()
DirCreate vsCodeTestRoot
vsCodeTestFile := vsCodeTestRoot "\selected.txt"
FileAppend "test", vsCodeTestFile, "UTF-8"
try {
    AssertEqual(vsCodeTestRoot, SmartPaste.DirectoryFromCopiedPath(vsCodeTestRoot), "copy-path selected folder")
    AssertEqual(vsCodeTestRoot, SmartPaste.DirectoryFromCopiedPath('"' vsCodeTestRoot '"'), "copy-path quoted folder")
    AssertEqual("", SmartPaste.DirectoryFromCopiedPath(vsCodeTestFile), "copy-path selected file falls back")
    AssertEqual("", SmartPaste.DirectoryFromCopiedPath(vsCodeTestRoot "`n" vsCodeTestRoot), "copy-path multi-selection falls back")
    vsCodeMissingPath := vsCodeTestRoot "\missing"
    AssertEqual("", SmartPaste.DirectoryFromCopiedPath(vsCodeMissingPath), "copy-path missing folder falls back")

    successEvents := []
    successClipboard := FakeSmartPasteClipboard(vsCodeTestRoot, true, false, successEvents)
    successRecorder := FakeSmartPasteCopyRecorder(successEvents)
    AssertEqual(
        vsCodeTestRoot,
        SmartPaste.GetCopyPathSelectedDirectory(Shortcuts.VsCodeCopyPath, successClipboard, successRecorder),
        "copy-path directory probe succeeds")
    AssertEqual("+!c", successRecorder.shortcut, "copy-path probe invokes Copy Path")
    AssertEqual(true, successClipboard.restored, "copy-path success restores clipboard")
    AssertEqual("original-image", successClipboard.restoredValue, "copy-path success restores original snapshot")
    AssertEqual(
        "Capture->Clear->Send->Wait->ReadText->Restore",
        EventSequence(successEvents),
        "copy-path success clipboard order")
    AssertEqual(0.75, successClipboard.waitTimeout, "copy-path success wait timeout")

    timeoutEvents := []
    timeoutClipboard := FakeSmartPasteClipboard(vsCodeTestRoot, false, false, timeoutEvents)
    timeoutRecorder := FakeSmartPasteCopyRecorder(timeoutEvents)
    AssertEqual("", SmartPaste.GetCopyPathSelectedDirectory("+!c", timeoutClipboard, timeoutRecorder), "copy-path timeout falls back")
    AssertEqual(true, timeoutClipboard.restored, "copy-path timeout restores clipboard")
    AssertEqual(
        "Capture->Clear->Send->Wait->Restore",
        EventSequence(timeoutEvents),
        "copy-path timeout skips clipboard read")
    AssertEqual(0.75, timeoutClipboard.waitTimeout, "copy-path timeout wait timeout")

    errorEvents := []
    errorClipboard := FakeSmartPasteClipboard(vsCodeTestRoot, true, true, errorEvents)
    errorRecorder := FakeSmartPasteCopyRecorder(errorEvents)
    AssertThrows(
        () => SmartPaste.GetCopyPathSelectedDirectory("+!c", errorClipboard, errorRecorder),
        "simulated clipboard failure",
        "copy-path probe exposes error after restoration")
    AssertEqual(true, errorClipboard.restored, "copy-path exception restores clipboard")
    AssertEqual(
        "Capture->Clear->Send->Wait->Restore",
        EventSequence(errorEvents),
        "copy-path exception restores after failed wait")
    AssertEqual(0.75, errorClipboard.waitTimeout, "copy-path exception wait timeout")

    fileProbeEvents := []
    fileProbeClipboard := FakeSmartPasteClipboard(vsCodeTestFile, true, false, fileProbeEvents)
    fileProbeRecorder := () => fileProbeEvents.Push("Send")
    AssertEqual(
        vsCodeTestRoot,
        SmartPaste.GetCurrentFileParentDirectory(["^k", "p"], fileProbeClipboard, fileProbeRecorder),
        "current-file probe returns parent directory")
    AssertEqual(
        "Capture->Clear->Send->Wait->ReadText->Restore",
        EventSequence(fileProbeEvents),
        "current-file probe clipboard order")
    AssertEqual(true, fileProbeClipboard.restored, "current-file probe restores clipboard")

    dirProbeClipboard := FakeSmartPasteClipboard(vsCodeTestRoot, true, false, [])
    AssertEqual(
        vsCodeTestRoot,
        SmartPaste.GetCurrentFileParentDirectory(["^k", "p"], dirProbeClipboard, () => ""),
        "current-file probe keeps directory as-is")

    emptyProbeClipboard := FakeSmartPasteClipboard("", true, false, [])
    AssertEqual(
        "",
        SmartPaste.GetCurrentFileParentDirectory(["^k", "p"], emptyProbeClipboard, () => ""),
        "current-file probe empty clipboard falls back")

    multiProbeClipboard := FakeSmartPasteClipboard(vsCodeTestRoot "`n" vsCodeTestRoot, true, false, [])
    AssertEqual(
        "",
        SmartPaste.GetCurrentFileParentDirectory(["^k", "p"], multiProbeClipboard, () => ""),
        "current-file probe multi-selection falls back")

    timeoutProbeClipboard := FakeSmartPasteClipboard(vsCodeTestRoot, false, false, [])
    AssertEqual(
        "",
        SmartPaste.GetCurrentFileParentDirectory(["^k", "p"], timeoutProbeClipboard, () => ""),
        "current-file probe timeout falls back")
    AssertEqual(true, timeoutProbeClipboard.restored, "current-file probe timeout restores clipboard")

    errorProbeClipboard := FakeSmartPasteClipboard(vsCodeTestRoot, true, true, [])
    AssertThrows(
        () => SmartPaste.GetCurrentFileParentDirectory(["^k", "p"], errorProbeClipboard, () => ""),
        "simulated clipboard failure",
        "current-file probe exposes error after restoration")
    AssertEqual(true, errorProbeClipboard.restored, "current-file probe exception restores clipboard")
} finally {
    FileDelete vsCodeTestFile
    DirDelete vsCodeTestRoot
}
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
for featureClass in [SearchSelectedText, SmartPaste, OpenSelectedTarget, LocateSelectedTarget, SpeakSelectedText] {
    AssertEqual("BoundFunc", Type(featureClass.HotkeyCallback), "selected action bound hotkey callback")
    AssertEqual(true, featureClass.HotkeyCallback == featureClass.HotkeyCallback, "selected action stable hotkey callback")
    AssertEqual(true, featureClass.HotkeyCallback.Call("test", receiver => receiver == featureClass), "selected action callback this")
}

AssertEqual(true, SpeakSelectedText.HasSpeakableText("hello"), "speak accepts English")
AssertEqual(true, SpeakSelectedText.HasSpeakableText("今天学习"), "speak accepts Chinese")
AssertEqual(true, SpeakSelectedText.HasSpeakableText("Windows 11"), "speak accepts mixed English and numbers")
AssertEqual(true, SpeakSelectedText.HasSpeakableText("ChatGPT 中文版"), "speak accepts mixed Chinese and English")
AssertEqual(false, SpeakSelectedText.HasSpeakableText("123456"), "speak rejects pure numbers")
AssertEqual(false, SpeakSelectedText.HasSpeakableText("!@#$%^&*()"), "speak rejects pure symbols")
AssertEqual(false, SpeakSelectedText.HasSpeakableText("   "), "speak rejects whitespace")
AssertEqual("hello world", SpeakSelectedText.Normalize("  hello world  "), "speak normalizes whitespace")
AssertEqual("*$CapsLock", Shortcuts.CapsLockIme, "CapsLock shortcut is *$CapsLock")
AssertEqual("~CapsLock & s", Shortcuts.SpeakSelectedText, "speak shortcut is CapsLock & s")
AssertEqual("~CapsLock & g", Shortcuts.SearchSelectedText, "search shortcut is CapsLock & g")
AssertEqual("~CapsLock & o", Shortcuts.OpenSelectedTarget, "open shortcut is CapsLock & o")
AssertEqual("~CapsLock & e", Shortcuts.LocateSelectedTarget, "locate shortcut is CapsLock & e")
AssertEqual("~CapsLock & t", Shortcuts.AlwaysOnTop, "always on top shortcut is CapsLock & t")
AssertEqual("~CapsLock & h", Shortcuts.HideActiveWindow, "hide window shortcut is CapsLock & h")
AssertEqual("~CapsLock & .", Shortcuts.ToggleHiddenFiles, "toggle hidden files shortcut is CapsLock & .")
AssertEqual("~CapsLock & x", Shortcuts.ToggleFileExtensions, "toggle file extensions shortcut is CapsLock & x")
AssertEqual("~CapsLock & q", Shortcuts.KillForegroundProcess, "kill foreground process shortcut is CapsLock & q")
AssertEqual("~CapsLock & r", Shortcuts.RestartForegroundProcess, "restart foreground process shortcut is CapsLock & r")
AssertEqual(true, HideActiveWindow.IsProtectedWindow("Shell_TrayWnd", 1), "taskbar cannot be hidden")
AssertEqual(true, HideActiveWindow.IsProtectedWindow("Progman", 1), "desktop cannot be hidden")
AssertEqual(true, HideActiveWindow.IsOwnProcess(ProcessExist()), "hide window blocks toolbox process")
AssertEqual(false, HideActiveWindow.IsProtectedWindow("Chrome_WidgetWin_1", 1), "normal app window can be hidden")
AssertEqual(false, HideActiveWindow.IsHideable(0), "empty hwnd is not hideable")
visibleWindows := HideActiveWindow.VisibleWindows()
AssertEqual(true, visibleWindows is Array, "visible window snapshot is an array")
nextHideTarget := HideActiveWindow.NextTarget()
if nextHideTarget
    AssertEqual(true, HideActiveWindow.IsHideable(nextHideTarget), "next hide target stays unminimized")
hideSource := FileRead(A_ScriptDir "\..\features\hide-active-window.ahk", "UTF-8")
AssertContains(hideSource, "WinGetList()", "hide window enumerates z-order")
AssertContains(hideSource, "windows[1]", "hide window always takes the topmost visible target")
AssertContains(hideSource, "WinGetMinMax", "already minimized windows stay out of the queue")
hiddenAction := ToggleHiddenFiles.Action(1)
AssertEqual(2, hiddenAction.value, "hidden files hide action")
AssertEqual(false, hiddenAction.visible, "hidden files hide visibility")
extHideAction := ToggleFileExtensions.Action(0)
AssertEqual(1, extHideAction.value, "file extensions hide action")
AssertEqual(false, extHideAction.visible, "file extensions hide visibility")
extShowAction := ToggleFileExtensions.Action(1)
AssertEqual(0, extShowAction.value, "file extensions show action")
AssertEqual(true, extShowAction.visible, "file extensions show visibility")
AssertEqual(false, ForegroundProcess.IsProtected("explorer.exe", "kill"), "explorer kill is not a protected no-op")
AssertEqual(false, ForegroundProcess.IsProtected("explorer.exe", "restart"), "explorer can be restarted")
AssertEqual(true, ForegroundProcess.IsExplorer("explorer.exe"), "explorer identity matches")
AssertEqual(true, ForegroundProcess.IsExplorer("Explorer.EXE"), "explorer identity is case-insensitive")
AssertEqual(700, ForegroundProcess.DebounceMs, "foreground process action debounce stays 700ms")
AssertEqual(250, Notify.ToastDebounceMs, "toast coalesces rapid result notifications")
foregroundSource := FileRead(A_ScriptDir "\..\features\foreground-process.ahk", "UTF-8")
notifySourceForToast := FileRead(A_ScriptDir "\..\..\shared\notify\notify.ahk", "UTF-8")
toastSource := FileRead(A_ScriptDir "\..\..\shared\notify\toast.ps1", "UTF-8")
dshNotifySource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\DshRemoteUtils.ps1", "UTF-8")
dshWatchSource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\Watch-DshRemote.ps1", "UTF-8")
dshStatusSource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\Get-DshRemoteStatus.ps1", "UTF-8")
dshInstallSource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\Install-Watcher.ps1", "UTF-8")
dshUninstallSource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\Uninstall-Watcher.ps1", "UTF-8")
toastAdapterSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\_lib\notify.ps1", "UTF-8")
themeUtilsSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\ThemeUtils.ps1", "UTF-8")
themeUpdateSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Update-ThemeSchedule.ps1", "UTF-8")
audioSwitcherSource := FileRead(A_ScriptDir "\..\features\audio-switcher.ahk", "UTF-8")
runNoWindowSource := FileRead(A_ScriptDir "\..\..\shared\notify\run-nowindow.ahk", "UTF-8")
AssertContains(runNoWindowSource, "class ProcessNoWindow", "no-window helper defines ProcessNoWindow")
AssertContains(runNoWindowSource, "CREATE_NO_WINDOW := 0x08000000", "no-window helper uses CREATE_NO_WINDOW")
AssertContains(runNoWindowSource, "CreateProcessW", "no-window helper calls CreateProcessW")
AssertContains(runNoWindowSource, "stdInputOffset := A_PtrSize = 8 ? 80 : 56", "STARTUPINFO standard handles use documented offsets")
AssertNotContains(runNoWindowSource, "stdInputOffset := A_PtrSize = 8 ? 72 : 56", "STARTUPINFO does not treat lpReserved2 as stdin")
AssertEqual(42, ProcessNoWindow.RunWait("cmd.exe /c exit 42"), "no-window helper returns child exit code")
noWindowOut := A_Temp "\lat3ncy-nowindow-" A_TickCount ".txt"
try {
    AssertEqual(0, ProcessNoWindow.RunWait("cmd.exe /c echo nowindow-ok", noWindowOut), "no-window helper can redirect stdout")
    AssertEqual(true, FileExist(noWindowOut) != "", "no-window helper creates stdout file")
} finally {
    if FileExist(noWindowOut)
        FileDelete noWindowOut
}
AssertContains(audioSwitcherSource, "ProcessNoWindow.RunWait(", "audio switcher waits without allocating a console")
AssertNotContains(audioSwitcherSource, "cmd.exe /c", "audio switcher no longer wraps exe with cmd")
AssertContains(audioSwitcherSource, "耳机未就绪", "audio switcher HUD keeps headset-not-ready text")
audioSwitcherCs := FileRead(A_ScriptDir "\..\..\tools\audio-switcher\AudioSwitcher.cs", "UTF-8")
AssertContains(audioSwitcherCs, "TogglePreferredOutputs()", "audio switcher toggle uses preferred G27Q2/AirPods pair")
AssertContains(audioSwitcherCs, "IsPreferredHeadset", "audio switcher prefers AirPods stereo")
AssertContains(audioSwitcherCs, "Hands-Free", "audio switcher excludes Hands-Free endpoints")
AssertContains(audioSwitcherCs, "BluetoothSetServiceState", "audio switcher can enable AirPods A2DP")
AssertContains(audioSwitcherCs, "BluetoothGetDeviceInfo", "audio switcher refreshes device info before enabling A2DP")
AssertContains(audioSwitcherCs, "BluetoothServiceEnable", "audio switcher only enables Bluetooth audio sink")
AssertNotContains(audioSwitcherCs, "BluetoothServiceDisable", "audio switcher never disconnects AirPods")
AssertContains(audioSwitcherCs, "0000110B-0000-1000-8000-00805F9B34FB", "audio switcher enables A2DP sink only")
AssertContains(audioSwitcherCs, "G27Q2", "audio switcher falls back to G27Q2")
AssertContains(audioSwitcherCs, "耳机未就绪", "audio switcher reports headset not ready")
AssertContains(audioSwitcherCs, "0xE000020B", "audio switcher maps missing device instance to headset-not-ready")
AssertContains(audioSwitcherCs, "(device.State & DeviceStateActive) == 0", "audio switcher never SetDefaults a non-active endpoint")
AssertNotContains(audioSwitcherCs, "knownHeadset", "audio switcher no longer SetDefaults stale AirPods endpoints")
AssertContains(audioSwitcherCs, "ConnectPreferredHeadset()", "audio switcher connects remembered AirPods before reporting not ready")
AssertContains(audioSwitcherCs, "DeviceStateMaskAll", "audio switcher looks up unpaired-but-remembered AirPods endpoints")
AssertContains(audioSwitcherCs, "PKEY_Device_DeviceDesc", "audio switcher can identify remembered AirPods by DeviceDesc")
AssertContains(audioSwitcherCs, "AddRememberedHeadsetIds(", "audio switcher recovers remembered AirPods endpoint IDs from the registry")
AssertContains(audioSwitcherCs, "ConnectAirPodsAudioProfile()", "audio switcher starts AirPods A2DP like the Bluetooth panel")
AssertContains(audioSwitcherCs, "WSASetService", "audio switcher registers the Bluetooth audio profile before waiting")
AssertContains(toastAdapterSource, "Start-ToolboxNotifyProcess -FilePath `"powershell.exe`"", "toast adapter reuses hidden process starter")
AssertNotContains(toastAdapterSource, "Start-Process -FilePath `"powershell.exe`"", "toast adapter no longer uses Start-Process")
AssertContains(dshNotifySource, "CreateNoWindow = $true", "dsh process starter creates no window")
AssertContains(dshNotifySource, "UseShellExecute = $false", "dsh process starter does not use the shell")
AssertContains(dshNotifySource, "function Invoke-TailscaleCommand", "dsh still owns tailscale wrapper")
AssertNotContains(dshNotifySource, 'cmd /c "tailscale', "dsh no longer shells tailscale through cmd")
AssertNotContains(dshNotifySource, 'cmd /c "sudo tailscale', "dsh no longer shells sudo tailscale through cmd")
AssertNotContains(dshStatusSource, "cmd /c", "dsh status no longer shells schtasks through cmd")
AssertNotContains(dshUninstallSource, "cmd /c", "dsh uninstall no longer shells schtasks through cmd")
AssertContains(dshInstallSource, "Start-DshHiddenProcess", "dsh install launches watcher without a console")
AssertNotContains(dshInstallSource, "Start-Process powershell.exe", "dsh install no longer uses Start-Process powershell")
AssertContains(themeUtilsSource, "-WindowStyle Hidden", "theme action hides PowerShell")
AssertContains(themeUtilsSource, "-Hidden", "theme settings mark the task hidden")
AssertContains(themeUpdateSource, "Repair-ThemeScheduledTaskWindow", "theme schedule updater keeps hidden actions")
AssertContains(dshNotifySource, 'Show-SystemToast -Title "$resolvedIcon DSH Remote"', "dsh toast uses resolved icon title")
AssertContains(dshNotifySource, 'success" { "✓"', "dsh maps success to check icon")
AssertNotContains(dshNotifySource, 'Icon = "0"', "dsh notify default icon is not a placeholder zero")
AssertNotContains(dshWatchSource, 'Icon "0"', "dsh watcher no longer sends placeholder icon")
AssertContains(foregroundSource, "return this.Restart(_hotkeyName)", "explorer Caps+Q reuses Caps+R entry")
AssertContains(foregroundSource, "this.RestartExplorer()", "explorer restart still has dedicated path")
AssertContains(foregroundSource, "this.LastTick := A_TickCount", "debounce clock starts after action ends")
AssertContains(notifySourceForToast, "static FlushToast(*)", "notify coalesces toast to last pending")
AssertContains(toastSource, "lat3ncy-toolbox", "toast replaces previous toolbox notification")
AssertEqual(true, ForegroundProcess.IsProtected("dwm.exe", "restart"), "system process stays protected")
AssertEqual(false, ForegroundProcess.IsProtected("Code.exe", "kill"), "normal app can be killed")
AssertEqual("Code", ForegroundProcess.DisplayName("Code.exe"), "process display name drops exe")
AssertEqual('"C:\Program Files\app.exe"', ForegroundProcess.QuotePath("C:\Program Files\app.exe"), "quoted process path")
AssertEqual("app.exe --reuse-window", ForegroundProcess.PreferredLaunchCommand("C:\app.exe", "app.exe --reuse-window"), "restart prefers command line")
AssertEqual('"C:\app.exe"', ForegroundProcess.PreferredLaunchCommand("C:\app.exe", ""), "restart falls back to path")
AssertEqual("~Alt Up", Shortcuts.SwitchAppWindowReset, "same-app reset shortcut")

speakSource := FileRead(A_ScriptDir "\..\features\speak-selected-text.ahk", "UTF-8")
AssertNotContains(speakSource, "Shortcuts.", "speak is independent from shortcut config")
AssertContains(speakSource, 'ClipboardAll()', "speak captures clipboard safely")
AssertContains(speakSource, 'finally', "speak restores clipboard in finally block")
AssertContains(speakSource, 'mciSendStringW', "speak uses MCI to close audio")

searchSource := FileRead(A_ScriptDir "\..\features\search-selected-text.ahk", "UTF-8")
openSource := FileRead(A_ScriptDir "\..\features\open-selected-target.ahk", "UTF-8")
locateSource := FileRead(A_ScriptDir "\..\features\locate-selected-target.ahk", "UTF-8")
smartPasteSource := FileRead(A_ScriptDir "\..\features\smart-paste\smart-paste.ahk", "UTF-8")
capsLockSource := FileRead(A_ScriptDir "\..\features\caps-lock-ime.ahk", "UTF-8")
routerSource := FileRead(A_ScriptDir "\..\hotkey-router.ahk", "UTF-8")
rendererSource := FileRead(A_ScriptDir "\..\..\shared\notify\renderer.ahk", "UTF-8")
notifySource := FileRead(A_ScriptDir "\..\..\shared\notify\notify.ahk", "UTF-8")
pathsSource := FileRead(A_ScriptDir "\..\..\shared\notify\paths.ahk", "UTF-8")
anchorSource := FileRead(A_ScriptDir "\..\..\shared\notify\anchor.ahk", "UTF-8")
captureSource := FileRead(A_ScriptDir "\..\..\shared\notify\dev\capture.ps1", "UTF-8")
hardcodedRepoRoot := "C:\Users\Jie\Projects\lat3ncy-scripts-toolbox"
for sourcePair in [
    ["main.ahk", mainSource],
    ["notify.ahk", notifySource],
    ["paths.ahk", pathsSource],
    ["anchor.ahk", anchorSource],
    ["capture.ps1", captureSource]
] {
    AssertNotContains(sourcePair[2], hardcodedRepoRoot, sourcePair[1] " has no hardcoded repo path")
}
AssertContains(pathsSource, "class NotifyPaths", "shared path resolver exists")
AssertContains(pathsSource, "A_WorkingDir", "path resolver covers temp test stubs")
AssertContains(anchorSource, "GetWin32Caret", "anchor probes Win32 caret in-process")
AssertEqual(true, InStr(anchorSource, "GetWin32Caret(activeHwnd)") < InStr(anchorSource, "RunWait("), "Win32 caret precedes locator process")
AssertNotContains(pathsSource, "HudHostExe", "path resolver no longer exposes hud-host.exe")
AssertNotContains(rendererSource, "ShowChipWithHost", "renderer no longer routes chips through hud host")
AssertNotContains(rendererSource, "lat3ncy-hud-host", "renderer no longer uses hud host pipe")
AssertContains(notifySource, "#Include paths.ahk", "notify API loads path resolver")
AssertContains(notifySource, "#Include run-nowindow.ahk", "notify API loads no-window process helper")
AssertContains(notifySource, "ProcessNoWindow.Run(", "toast launches PowerShell without a console")
AssertNotContains(notifySource, "WindowStyle Hidden", "toast no longer uses Hidden window style")
AssertContains(notifySource, "this.ShowToolTip(icon, text, duration)", "toast failure falls back to ToolTip")
AssertContains(mainSource, "for arg in A_Args", "debug/test flags scan all arguments")
AssertContains(mainSource, 'A_Temp "\lat3ncy-toolbox-notify.log"', "debug log stays in TEMP")
AssertNotContains(mainSource, "debug-notify.log", "main no longer writes repo-root debug log")
smartPasteHelperSource := FileRead(A_ScriptDir "\..\features\smart-paste\save-clipboard-image.ps1", "UTF-8")
AssertContains(capsLockSource, "TapMaxMs", "Caps state machine owns short-press ceiling")
AssertContains(capsLockSource, "AbortCapsModeForChord", "Caps state machine can undo late caps-mode")
AssertContains(capsLockSource, "_exitingCaps", "Caps state machine blocks chords while exiting caps")
AssertContains(capsLockSource, "ChordImeLockoutMs", "Caps state machine owns post-chord IME lockout")
AssertContains(routerSource, "RegisterCapsChord", "router owns Caps chord wiring")
AssertContains(routerSource, "MarkCapsChordUsed()", "router marks Caps chord before dispatch")
AssertContains(routerSource, "if !MarkCapsChordUsed()", "router drops rejected Caps chords")
AssertContains(routerSource, "SmartPaste.Configure", "router injects Smart Paste shortcuts")
AssertContains(rendererSource, "class NotifyRenderer", "shared renderer exists")
AssertContains(rendererSource, "EnableSystemDropShadow", "chip enables system drop shadow")
AssertContains(rendererSource, "CS_DROPSHADOW", "chip uses CS_DROPSHADOW")
AssertContains(rendererSource, "opaqueClient ? 3 : 2", "chip uses ROUNDSMALL corners")
AssertContains(rendererSource, "theme.ChipBg", "chip fill is independent from long HUD")
AssertNotContains(rendererSource, 'hud.BackColor := isTextOnly ? theme.TypeBadgeBg["state"]', "chip no longer uses badge fill")
AssertContains(notifySource, "class Notify", "shared notify API exists")
AssertContains(notifySource, "ToolTip", "notify API owns ToolTip fallback")
for featureSource in [
    capsLockSource,
    speakSource,
    searchSource,
    openSource,
    locateSource,
    smartPasteSource,
    FileRead(A_ScriptDir "\..\features\always-on-top.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\hide-active-window.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\toggle-hidden-files.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\toggle-file-extensions.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\foreground-process.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\audio-switcher.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\switch-app-window.ahk", "UTF-8")
] {
    AssertNotContains(featureSource, "RegisterFeatureHotkey", "feature does not register hotkeys")
    AssertNotContains(featureSource, "Shortcuts.", "feature does not read shortcut config")
    AssertNotContains(featureSource, "ToolTip", "feature does not render ToolTip")
    AssertNotContains(featureSource, "ShowTip", "feature does not own notification helper")
}
AssertNotContains(searchSource, "OpenSelectedTarget", "search does not depend on open")
AssertNotContains(searchSource, "LocateSelectedTarget", "search does not depend on locate")
AssertNotContains(openSource, "SearchSelectedText", "open does not depend on search")
AssertNotContains(openSource, "LocateSelectedTarget", "open does not depend on locate")
AssertNotContains(locateSource, "SearchSelectedText", "locate does not depend on search")
AssertNotContains(locateSource, "OpenSelectedTarget", "locate does not depend on open")
alwaysOnTopSource := FileRead(A_ScriptDir "\..\features\always-on-top.ahk", "UTF-8")
hideWindowSource := FileRead(A_ScriptDir "\..\features\hide-active-window.ahk", "UTF-8")
fileExtSource := FileRead(A_ScriptDir "\..\features\toggle-file-extensions.ahk", "UTF-8")
AssertContains(searchSource, "打开搜索失败", "search Run failure hint")
AssertContains(openSource, "打开目标失败", "open Run failure hint")
AssertContains(locateSource, "定位目标失败", "locate Run failure hint")
AssertContains(alwaysOnTopSource, 'Notify.Success("📌"', "always-on-top reports pin state")
AssertContains(alwaysOnTopSource, "已取消置顶", "always-on-top reports unpin state")
AssertNotContains(fileExtSource, "已显示扩展名", "file extensions stay silent on success")
AssertNotContains(fileExtSource, "已隐藏扩展名", "file extensions hide path stays silent")
AssertNotContains(hideWindowSource, "没有可隐藏的窗口", "hide window stays silent when nothing left")
AssertNotContains(smartPasteSource, "请选择目录或打开文件后重试", "smart paste fallback stays silent")
AssertContains(smartPasteSource, '"UInt", 15', "smart paste detects CF_HDROP")
AssertContains(smartPasteSource, 'RegisterClipboardFormatW', "smart paste registers PNG clipboard format")
AssertContains(smartPasteSource, 'A_ScriptDir "\features\smart-paste\save-clipboard-image.ps1"', "smart paste helper path uses entry directory")
AssertNotContains(smartPasteSource, "SendText A_Clipboard", "Smart Paste no longer reformats text")
AssertNotContains(smartPasteSource, "static HasText()", "Smart Paste no longer classifies text")
AssertContains(smartPasteSource, 'WinActive("ahk_exe Code.exe")', "Smart Paste detects VS Code")
AssertContains(smartPasteSource, "ClipboardAll()", "VS Code probe captures all clipboard formats")
AssertContains(smartPasteSource, "finally", "VS Code probe restores clipboard in finally")
AssertContains(smartPasteSource, 'Send "^v"', "smart paste keeps ordinary paste fallback")
AssertContains(smartPasteSource, 'ObjBindMethod(SmartPaste, "Paste")', "smart paste binds hotkey callback")
AssertContains(smartPasteSource, "#Include ..\..\..\shared\notify\run-nowindow.ahk", "smart paste loads no-window helper")
AssertContains(smartPasteSource, "ProcessNoWindow.RunWait(command)", "smart paste waits without allocating a console")
AssertNotContains(smartPasteSource, 'RunWait(command, , "Hide")', "smart paste no longer uses RunWait Hide")
AssertContains(smartPasteSource, 'Notify.Success("✓"', "smart paste uses shared success notification")
startupConfigurePosition := InStr(routerSource, "SmartPaste.Configure(")
startupEnsurePosition := InStr(routerSource, "SmartPaste.EnsureHelperAvailable()")
startupRegisterPosition := InStr(routerSource, "Shortcuts.SmartPaste")
AssertEqual(true, startupConfigurePosition > 0, "smart paste startup injects shortcuts")
AssertEqual(true, startupConfigurePosition < startupEnsurePosition, "smart paste config precedes helper validation")
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



