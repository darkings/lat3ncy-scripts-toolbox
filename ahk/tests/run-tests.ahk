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
panelIncludePosition := InStr(mainSource, "#Include ..\shared\notify\translation-panel.ahk")
imeHudIncludePosition := InStr(mainSource, "#Include ..\shared\notify\ime-hud.ahk")
pythonIncludePosition := InStr(mainSource, "#Include ..\shared\python.ahk")
firstFeatureIncludePosition := InStr(mainSource, "#Include features\caps-lock-ime.ahk")
lastFeatureIncludePosition := InStr(mainSource, "#Include features\foreground-process.ahk")
routerIncludePosition := InStr(mainSource, "#Include hotkey-router.ahk")
startupFalsePosition := InStr(mainSource, "`nToolboxStarting := false")
AssertEqual(true, startupTruePosition > 0, "startup flag exists")
AssertEqual(true, startupHandlerPosition > startupTruePosition, "startup handler follows flag")
AssertEqual(true, rendererIncludePosition > startupHandlerPosition, "renderer loads after startup handler")
AssertEqual(true, notifyIncludePosition > rendererIncludePosition, "notify API loads after renderer")
AssertEqual(true, panelIncludePosition > notifyIncludePosition, "translation panel client loads after notify")
AssertEqual(true, imeHudIncludePosition > panelIncludePosition, "ImeHud client loads after translation panel client")
AssertEqual(true, pythonIncludePosition > imeHudIncludePosition, "python helper loads after ImeHud client")
AssertEqual(true, firstFeatureIncludePosition > pythonIncludePosition, "features load after python helper")
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
AssertEqual("BoundFunc", Type(ToggleDotfiles.HotkeyCallback), "dotfiles bound hotkey callback")
AssertEqual("BoundFunc", Type(ToggleFileExtensions.HotkeyCallback), "file-extensions bound hotkey callback")
AssertEqual("BoundFunc", Type(ForegroundProcess.KillCallback), "kill-process bound hotkey callback")
AssertEqual("BoundFunc", Type(ForegroundProcess.RestartCallback), "restart-process bound hotkey callback")
AssertEqual(true, CapsLockIme.HotkeyCallback.Call("test", receiver => receiver == CapsLockIme), "CapsLock callback this")
AssertEqual(true, AlwaysOnTop.HotkeyCallback.Call("test", receiver => receiver == AlwaysOnTop), "always-on-top callback this")
AssertEqual(true, HideActiveWindow.HotkeyCallback.Call("test", receiver => receiver == HideActiveWindow), "hide-window callback this")
AssertEqual(true, ToggleHiddenFiles.HotkeyCallback.Call("test", receiver => receiver == ToggleHiddenFiles), "hidden-files callback this")
AssertEqual(true, ToggleDotfiles.HotkeyCallback.Call("test", receiver => receiver == ToggleDotfiles), "dotfiles callback this")
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
AssertEqual(2, Notify.PriorityMap["popup"], "notify priority map owns popup level")
AssertEqual(true, HasMethod(Notify, "Popup"), "notify exposes cursor popup")
AssertEqual(true, HasMethod(Notify, "ClampDuration"), "notify clamps HUD duration")
AssertEqual(true, HasMethod(NotifyRenderer, "CloseOrphans"), "renderer can close orphan HUD windows")
AssertEqual(true, HasMethod(NotifyRenderer, "ClampRefreshDuration"), "renderer caps refreshed HUD lifetime")
AssertEqual("Lat3ncyNotifyHUD", NotifyRenderer.HudTitle, "renderer HUD title is stable")
AssertEqual(10000, Notify.MaxDurationMs, "notify HUD hard cap stays 10s")
AssertEqual(10000, NotifyRenderer.MaxDurationMs, "renderer HUD hard cap stays 10s")
AssertEqual(650, Notify.ClampDuration(0), "zero duration falls back to default")
AssertEqual(650, Notify.ClampDuration(-1), "negative duration falls back to default")
AssertEqual(10000, Notify.ClampDuration(999999), "huge duration is clamped to 10s")
AssertEqual(900, Notify.ClampDuration(900), "normal duration is kept")
savedGui := NotifyRenderer._gui
savedShownAt := NotifyRenderer.ShownAt
try {
    NotifyRenderer._gui := 0
    NotifyRenderer.ShownAt := 0
    AssertEqual(900, NotifyRenderer.ClampRefreshDuration(900), "first HUD keeps requested duration")
    AssertEqual(true, NotifyRenderer.ShownAt > 0, "first HUD records shown-at")
    NotifyRenderer._gui := 1
    NotifyRenderer.ShownAt := A_TickCount - 9000
    refreshed := NotifyRenderer.ClampRefreshDuration(5000)
    AssertEqual(true, refreshed <= 1000, "refreshed HUD cannot exceed remaining hard cap")
    AssertEqual(true, refreshed >= 1, "refreshed HUD still has a positive remaining duration")
    NotifyRenderer.ShownAt := A_TickCount - 11000
    AssertEqual(0, NotifyRenderer.ClampRefreshDuration(5000), "expired HUD refresh is rejected")
} finally {
    NotifyRenderer._gui := savedGui
    NotifyRenderer.ShownAt := savedShownAt
}
AssertEqual(520, NotifyRenderer.PopupMaxWidth, "popup max width stays 520")
AssertEqual(20, NotifyRenderer.PopupMaxLines, "popup max lines stay 20")
AssertEqual(20, NotifyRenderer.PopupLineHeight, "popup line height matches 11pt")
AssertEqual(11, NotifyRenderer.PopupTextSize, "popup text is 11pt")
AssertEqual(350, NotifyRenderer.PopupTextWeight, "popup text is SemiLight")
AssertEqual(10, NotifyRenderer.PopupPaddingX, "popup uses tighter horizontal padding")
AssertEqual(6, NotifyRenderer.PopupPaddingY, "popup uses tighter vertical padding")
AssertEqual(16, NotifyRenderer.PaddingX, "regular HUD padding stays 16")
AssertEqual(0.55, NotifyRenderer.PopupMaxWorkAreaRatio, "popup height cap stays 55% of work area")
shortLines := "Hello`nWorld`nFoo`nBar`nBaz"
shortMetrics := NotifyRenderer.MeasurePopupText(shortLines, 400)
AssertEqual(5, shortMetrics["lines"], "five short lines keep five visual rows")
AssertEqual(false, shortMetrics["truncated"], "five short lines are not truncated")
AssertEqual(true, shortMetrics["width"] > 0, "five short lines report content width")
AssertEqual(true, NotifyRenderer.PopupPaddingY * 2 + shortMetrics["lines"] * NotifyRenderer.PopupLineHeight > NotifyRenderer.Height, "five short lines are taller than the 34px HUD")
singleMetrics := NotifyRenderer.MeasurePopupText("你好世界", 400)
AssertEqual(1, singleMetrics["lines"], "short single line stays one row")
AssertEqual(false, singleMetrics["truncated"], "short single line is not truncated")
singleW := NotifyRenderer.MeasureTextWidthAt("你好世界", NotifyRenderer.PopupTextSize, NotifyRenderer.PopupTextWeight)
AssertEqual(true, singleW > 0, "popup measure uses the same 11pt SemiLight as drawing")
AssertEqual(singleW, singleMetrics["width"], "popup box width follows measured glyph width, not a fatter Regular face")
longWord := ""
Loop 80
    longWord .= "字"
wrapMetrics := NotifyRenderer.MeasurePopupText(longWord, 200)
AssertEqual(true, wrapMetrics["lines"] >= 2, "over-wide CJK wraps to at least two rows")
twenty := "1"
Loop 20
    twenty .= "`n" (A_Index + 1)
capped := NotifyRenderer.MeasurePopupText(twenty, 400)
AssertEqual(true, capped["truncated"], "twenty-one lines are truncated")
AssertEqual(true, capped["lines"] <= NotifyRenderer.PopupMaxLines, "truncated popup stays within max lines")
AssertEqual(true, InStr(capped["display"], "已复制全文") > 0, "truncated popup hints that full text was copied")

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
AssertEqual(true, CapsLockIme.PersistImeAcrossWindows, "Caps remembers IME across window switches")
AssertEqual(120, CapsLockIme.ImeWatchIntervalMs, "Caps IME watcher interval uses 更稳 preset")
AssertEqual(150, CapsLockIme.ImeRestoreDelayMs, "Caps waits before restoring IME on focus change")
AssertEqual(80, CapsLockIme.ImeRestorePollMs, "Caps IME restore poll uses 更稳 preset")
AssertEqual(6, CapsLockIme.ImeRestoreAttempts, "Caps retries IME restore a few times")
AssertEqual(true, HasMethod(CapsLockIme, "AbortCapsModeForChord"), "Caps can abort caps-mode for a late chord")
AssertEqual(true, CapsLockIme.UseImeHud, "Caps prefers WinUI ImeHud for CN/EN/CAPS")
AssertEqual(true, HasMethod(CapsLockIme, "ShowImeHud"), "Caps can show ImeHud states")
AssertEqual(true, HasMethod(CapsLockIme, "IsImeHudEnabled"), "Caps can gate ImeHud to production")
AssertEqual(false, CapsLockIme.IsImeHudEnabled(), "test mode does not launch ImeHud")
AssertEqual("Lat3ncyImeHudWinUi", ImeHud.WindowClass, "ImeHud production class is WinUI")
AssertEqual("Lat3ncyImeHudWinUi", ImeHud.WindowTitle, "ImeHud production title is WinUI")
AssertEqual(2500, ImeHud.MessageTimeout, "ImeHud COPYDATA timeout covers WinUI ShowState")
AssertEqual(true, HasMethod(ImeHud, "Show"), "ImeHud client can show a state")
AssertEqual(true, HasMethod(ImeHud, "BuildStateCommand"), "ImeHud can format STATE without launching WinUI")
AssertEqual(true, HasMethod(ImeHud, "SendCopyData"), "ImeHud client sends WM_COPYDATA")
AssertEqual("STATE|CN|820|642|0|0", ImeHud.BuildStateCommand("CN", 820, 642, 0, 0), "STATE keeps caret hint")
AssertEqual("STATE|EN|0|0|0|0", ImeHud.BuildStateCommand("EN", 0, 0, 0, 0), "STATE zero coords stay explicit")
AssertEqual("STATE|CAPS|12|34|96|750", ImeHud.BuildStateCommand("CAPS", 12, 34, 96, 750), "STATE keeps dpi and duration")
AssertEqual(false, HasMethod(NotifyPaths, "ImeHudExe"), "path resolver no longer exposes ImeHud.exe")
AssertEqual("Lat3ncyImeHudWinUi", TranslationPanel.WindowClass, "WinUI translation client uses independent class")
AssertEqual("Lat3ncyImeHudWinUi", TranslationPanel.WindowTitle, "WinUI translation client uses independent title")
AssertEqual(true, HasMethod(TranslationPanel, "OpenText"), "translation panel can OPEN with explicit source")
AssertEqual(true, HasMethod(TranslationPanel, "SetResult"), "translation panel can send RESULT")
AssertEqual(true, HasMethod(TranslationPanel, "Close"), "translation panel can CLOSE")
AssertEqual(true, HasMethod(TranslationPanel, "SendCopyData"), "translation panel sends WM_COPYDATA")
AssertEqual(true, HasMethod(NotifyPaths, "ImeHudWinUiExe"), "path resolver exposes ImeHudWinUi.exe")
AssertEqual(true, NotifyPaths.ImeHudWinUiExe() != "", "published ImeHudWinUi.exe is resolvable from tests")
AssertEqual(
    "PANEL|OPEN|12|34|0|mouse-at-hotkey|explicit|hello|world",
    TranslationPanel.BuildOpenCommand("hello|world", 12, 34, 0),
    "OPEN keeps pipes inside explicit payload")
AssertEqual(
    "PANEL|RESULT|explicit|你好|世界",
    TranslationPanel.BuildResultCommand("你好|世界"),
    "RESULT keeps pipes inside explicit payload")
AssertEqual("PANEL|CLOSE", TranslationPanel.BuildCloseCommand(), "CLOSE command is stable")
AssertEqual(true, HasMethod(CapsLockIme, "RememberImeState"), "Caps can remember last IME state")
AssertEqual(true, HasMethod(CapsLockIme, "WatchForeground"), "Caps watches foreground window changes")
AssertEqual(true, HasMethod(CapsLockIme, "RestoreRememberedIme"), "Caps can restore remembered IME")
AssertEqual("BoundFunc", Type(CapsLockIme.WindowWatchCallback), "Caps bound window-watch callback")
AssertEqual("BoundFunc", Type(CapsLockIme.RestoreCallback), "Caps bound IME restore callback")

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

savedRememberedIme := CapsLockIme.RememberedImeState
savedWatcherStarted := CapsLockIme._watcherStarted
savedLastHwnd := CapsLockIme._lastForegroundHwnd
savedRestoreAttempts := CapsLockIme._restoreAttemptsLeft
savedPersistIme := CapsLockIme.PersistImeAcrossWindows
try {
    CapsLockIme.RememberedImeState := "unknown"
    CapsLockIme.RememberImeState("english")
    AssertEqual("english", CapsLockIme.RememberedImeState, "Caps remembers english")
    CapsLockIme.RememberImeState("unknown")
    AssertEqual("english", CapsLockIme.RememberedImeState, "unknown does not overwrite remembered IME")
    CapsLockIme.RememberImeState("chinese")
    AssertEqual("chinese", CapsLockIme.RememberedImeState, "Caps remembers chinese")

    CapsLockIme._pressed := false
    CapsLockIme._exitingCaps := false
    AssertEqual(false, CapsLockIme.ShouldSkipImeRestore(), "idle Caps allows IME restore")
    CapsLockIme._pressed := true
    AssertEqual(true, CapsLockIme.ShouldSkipImeRestore(), "pressed Caps skips IME restore")
    CapsLockIme._pressed := false

    CapsLockIme.PersistImeAcrossWindows := false
    CapsLockIme._lastForegroundHwnd := 1
    CapsLockIme._restoreAttemptsLeft := 0
    CapsLockIme.WatchForeground()
    AssertEqual(1, CapsLockIme._lastForegroundHwnd, "disabled persist does not track foreground")
    AssertEqual(0, CapsLockIme._restoreAttemptsLeft, "disabled persist does not schedule restore")

    CapsLockIme.PersistImeAcrossWindows := true
    CapsLockIme.RememberedImeState := "unknown"
    CapsLockIme._restoreAttemptsLeft := 3
    CapsLockIme.RestoreRememberedIme()
    AssertEqual(3, CapsLockIme._restoreAttemptsLeft, "unknown remembered IME does not restore")

    CapsLockIme.EnsureWindowWatcher()
    AssertEqual(false, CapsLockIme._watcherStarted, "test mode does not start IME window watcher")
} finally {
    CapsLockIme.RememberedImeState := savedRememberedIme
    CapsLockIme._watcherStarted := savedWatcherStarted
    CapsLockIme._lastForegroundHwnd := savedLastHwnd
    CapsLockIme._restoreAttemptsLeft := savedRestoreAttempts
    CapsLockIme.PersistImeAcrossWindows := savedPersistIme
    CapsLockIme._pressed := false
    CapsLockIme._exitingCaps := false
}

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
AssertEqual("^{PgDn}", SwitchAppWindow.SingleWindowShortcut("msedge.exe", 1), "Edge single window steps forward")
AssertEqual("^{PgUp}", SwitchAppWindow.SingleWindowShortcut("MSEdge.exe", -1), "Edge single window steps backward")
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
for featureClass in [SearchSelectedText, SmartPaste, OpenSelectedTarget, LocateSelectedTarget, SpeakSelectedText, TranslateSelectedText] {
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
AssertEqual(true, TranslateSelectedText.HasTranslatableText("hello"), "translate accepts English")
AssertEqual(true, TranslateSelectedText.HasTranslatableText("今天学习"), "translate accepts Chinese")
AssertEqual(true, TranslateSelectedText.HasTranslatableText("Windows 11"), "translate accepts mixed English and numbers")
AssertEqual(true, TranslateSelectedText.HasTranslatableText("ChatGPT 中文版"), "translate accepts mixed Chinese and English")
AssertEqual(false, TranslateSelectedText.HasTranslatableText("123456"), "translate rejects pure numbers")
AssertEqual(false, TranslateSelectedText.HasTranslatableText("!@#$%^&*()"), "translate rejects pure symbols")
AssertEqual(false, TranslateSelectedText.HasTranslatableText("   "), "translate rejects whitespace")
AssertEqual("hello world", TranslateSelectedText.Normalize("  hello world  "), "translate normalizes whitespace")
AssertEqual("*$CapsLock", Shortcuts.CapsLockIme, "CapsLock shortcut is *$CapsLock")
AssertEqual("~CapsLock & s", Shortcuts.SpeakSelectedText, "speak shortcut is CapsLock & s")
AssertEqual("~CapsLock & f", Shortcuts.TranslateSelectedText, "translate shortcut is CapsLock & f")
AssertEqual("~CapsLock & g", Shortcuts.SearchSelectedText, "search shortcut is CapsLock & g")
AssertEqual("~CapsLock & o", Shortcuts.OpenSelectedTarget, "open shortcut is CapsLock & o")
AssertEqual("~CapsLock & e", Shortcuts.LocateSelectedTarget, "locate shortcut is CapsLock & e")
AssertEqual("~CapsLock & t", Shortcuts.AlwaysOnTop, "always on top shortcut is CapsLock & t")
AssertEqual("~CapsLock & h", Shortcuts.HideActiveWindow, "hide window shortcut is CapsLock & h")
AssertEqual("~CapsLock & .", Shortcuts.ToggleHiddenFiles, "toggle hidden files shortcut is CapsLock & .")
AssertEqual("~CapsLock & ,", Shortcuts.ToggleDotfiles, "toggle dotfiles shortcut is CapsLock & ,")
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
dotHideAction := ToggleDotfiles.Action(false)
AssertEqual(true, dotHideAction.hide, "dotfiles hide when no saved state")
dotShowAction := ToggleDotfiles.Action(true)
AssertEqual(false, dotShowAction.hide, "dotfiles restore when saved state exists")
AssertEqual(true, ToggleDotfiles.IsDotName(".git"), "dotfiles treat .git as a dot name")
AssertEqual(true, ToggleDotfiles.IsDotName(".gitignore"), "dotfiles treat .gitignore as a dot name")
AssertEqual(false, ToggleDotfiles.IsDotName("."), "dotfiles skip current-dir alias")
AssertEqual(false, ToggleDotfiles.IsDotName(".."), "dotfiles skip parent-dir alias")
AssertEqual(false, ToggleDotfiles.IsDotName("readme.md"), "dotfiles skip ordinary names")
AssertEqual(true, ToggleDotfiles.ShouldHide("A"), "dotfiles hide entries without Hidden")
AssertEqual(false, ToggleDotfiles.ShouldHide("AH"), "dotfiles skip already-hidden entries")
AssertEqual("C:\", ToggleDotfiles.NormalizeDir("C:\"), "dotfiles keep drive-root slash")
AssertEqual("C:\Users\Jie", ToggleDotfiles.NormalizeDir("C:\Users\Jie\"), "dotfiles trim trailing slash")
AssertEqual(true, ToggleDotfiles.IsFilesystemPath("C:\Users\Jie"), "dotfiles accept drive paths")
AssertEqual(true, ToggleDotfiles.IsFilesystemPath("\\server\share"), "dotfiles accept UNC paths")
AssertEqual(false, ToggleDotfiles.IsFilesystemPath("::{20D04FE0-3AEA-1069-A2D8-08002B30309D}"), "dotfiles reject virtual folders")
AssertEqual("C:\repo\.git", ToggleDotfiles.JoinDir("C:\repo", ".git"), "dotfiles join nested names")
AssertEqual("C:\.git", ToggleDotfiles.JoinDir("C:\", ".git"), "dotfiles join drive-root names")
AssertEqual(true, ToggleDotfiles.IsHiddenAttrib("AH"), "dotfiles detect Hidden attribute")
AssertEqual(false, ToggleDotfiles.IsHiddenAttrib("A"), "dotfiles treat missing Hidden as visible")
AssertEqual(true, ToggleDotfiles.ArrayHasName([".git", ".env"], ".env"), "dotfiles name list contains match")
AssertEqual(false, ToggleDotfiles.ArrayHasName([".git"], ".env"), "dotfiles name list rejects miss")
mergedDotNames := ToggleDotfiles.MergeNames([".dartServer"], [".dartServer", ".lingma"])
AssertEqual(2, mergedDotNames.Length, "dotfiles merge keeps unique names")
AssertEqual(".dartServer", mergedDotNames[1], "dotfiles merge keeps first occurrence")
AssertEqual(".lingma", mergedDotNames[2], "dotfiles merge appends new names")
dotfilesTestRoot := A_Temp "\lat3ncy-dotfiles-" A_TickCount
dotfilesStateFile := dotfilesTestRoot "\state.ini"
DirCreate dotfilesTestRoot "\.git"
FileAppend "", dotfilesTestRoot "\.gitignore"
FileAppend "keep", dotfilesTestRoot "\readme.md"
FileAppend "", dotfilesTestRoot "\.already-hidden"
FileSetAttrib "+H", dotfilesTestRoot "\.already-hidden"
savedDotfilesStateFile := ToggleDotfiles.StateFile
ToggleDotfiles.StateFile := dotfilesStateFile
try {
    hideResult := ToggleDotfiles.HideDotfiles(dotfilesTestRoot)
    AssertEqual(2, hideResult.hidden, "dotfiles hide only visible dot entries")
    AssertEqual(3, hideResult.managed, "dotfiles also manage already-hidden entries")
    AssertEqual(true, InStr(FileGetAttrib(dotfilesTestRoot "\.git"), "H") != 0, "dotfiles hide .git directory")
    AssertEqual(true, InStr(FileGetAttrib(dotfilesTestRoot "\.gitignore"), "H") != 0, "dotfiles hide .gitignore")
    AssertEqual(true, InStr(FileGetAttrib(dotfilesTestRoot "\.already-hidden"), "H") != 0, "dotfiles leave already-hidden files hidden")
    AssertEqual(false, InStr(FileGetAttrib(dotfilesTestRoot "\readme.md"), "H") != 0, "dotfiles do not hide ordinary files")
    hiddenNames := ToggleDotfiles.LoadState(dotfilesTestRoot)
    AssertEqual(true, hiddenNames is Array, "dotfiles persist hidden names")
    AssertEqual(true, ToggleDotfiles.ArrayHasName(hiddenNames, ".git"), "dotfiles record .git as managed")
    AssertEqual(true, ToggleDotfiles.ArrayHasName(hiddenNames, ".gitignore"), "dotfiles record .gitignore as managed")
    AssertEqual(true, ToggleDotfiles.ArrayHasName(hiddenNames, ".already-hidden"), "dotfiles adopt already-hidden files")
    restoredCount := ToggleDotfiles.RestoreDotfiles(dotfilesTestRoot)
    AssertEqual(3, restoredCount, "dotfiles restore managed entries including previously self-hidden ones")
    AssertEqual(false, InStr(FileGetAttrib(dotfilesTestRoot "\.git"), "H") != 0, "dotfiles restore .git directory")
    AssertEqual(false, InStr(FileGetAttrib(dotfilesTestRoot "\.gitignore"), "H") != 0, "dotfiles restore .gitignore")
    AssertEqual(false, InStr(FileGetAttrib(dotfilesTestRoot "\.already-hidden"), "H") != 0, "dotfiles restore previously self-hidden files")
    AssertEqual(false, ToggleDotfiles.LoadState(dotfilesTestRoot) is Array, "dotfiles clear names after restore")
} finally {
    ToggleDotfiles.StateFile := savedDotfilesStateFile
    try FileSetAttrib "-H", dotfilesTestRoot "\.git"
    try FileSetAttrib "-H", dotfilesTestRoot "\.gitignore"
    try FileSetAttrib "-H", dotfilesTestRoot "\.already-hidden"
    try DirDelete dotfilesTestRoot, true
}
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
dshRestartSource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\Restart-Watcher.ps1", "UTF-8")
dshUninstallSource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\Uninstall-Watcher.ps1", "UTF-8")
dshConfigSource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\config.toml", "UTF-8")
toastAdapterSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\_lib\notify.ps1", "UTF-8")
themeUtilsSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\ThemeUtils.ps1", "UTF-8")
themeUpdateSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Update-ThemeSchedule.ps1", "UTF-8")
themeLightSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Set-Theme-Light.ps1", "UTF-8")
themeDarkSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Set-Theme-Dark.ps1", "UTF-8")
themeApplySource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Apply-ThemeNow.ps1", "UTF-8")
themeCursorsSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Apply-CursorsNow.ps1", "UTF-8")
themeInstallSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Install-ThemeScheduler.ps1", "UTF-8")
themeUninstallSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Uninstall-ThemeScheduler.ps1", "UTF-8")
themeConfigSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\config.toml", "UTF-8")
audioSwitcherSource := FileRead(A_ScriptDir "\..\features\audio-switcher.ahk", "UTF-8")
runNoWindowSource := FileRead(A_ScriptDir "\..\..\shared\notify\run-nowindow.ahk", "UTF-8")
AssertContains(runNoWindowSource, "class ProcessNoWindow", "no-window helper defines ProcessNoWindow")
AssertContains(runNoWindowSource, "CREATE_NO_WINDOW := 0x08000000", "no-window helper uses CREATE_NO_WINDOW")
AssertContains(runNoWindowSource, "CreateProcessW", "no-window helper calls CreateProcessW")
AssertContains(runNoWindowSource, "static WAIT_TIMEOUT := 258", "no-window helper can time out")
AssertContains(runNoWindowSource, "CREATE_SUSPENDED", "wait mode starts the child suspended")
AssertContains(runNoWindowSource, "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE", "wait mode uses a kill-on-close job")
AssertContains(runNoWindowSource, "TerminateJobObject", "timeout prefers TerminateJobObject")
AssertContains(runNoWindowSource, "TryCreateKillOnCloseJob", "job creation failure still resumes the child")
AssertContains(runNoWindowSource, 'throw Error("超时")', "no-window helper reports timeout")
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
AssertThrows(
    () => ProcessNoWindow.RunWait("cmd.exe /c ping 127.0.0.1 -n 8 >nul", "", 200),
    "超时",
    "no-window helper times out and terminates the child")
; 非等待模式返回真实 PID，不是退出码；WatchPid 只在进程消失后删临时文件。不启动 TTS、不播放。
noWaitPid := ProcessNoWindow.Run("ping.exe 127.0.0.1 -n 8")
try {
    AssertEqual(true, noWaitPid > 0, "non-wait Run returns a positive pid")
    AssertEqual(true, ProcessExist(noWaitPid) != 0, "non-wait Run pid is a live process")
    watchFile := A_Temp "\lat3ncy-tts-watch-" A_TickCount "-" Random(1000, 9999) ".txt"
    FileAppend "probe", watchFile, "UTF-8"
    savedPid := SpeakSelectedText.TtsPid
    savedFile := SpeakSelectedText.LastInputFile
    savedWatch := SpeakSelectedText.WatchBound
    try {
        SpeakSelectedText.TtsPid := noWaitPid
        SpeakSelectedText.LastInputFile := watchFile
        SpeakSelectedText.WatchBound := ""
        SpeakSelectedText.WatchPid()
        AssertEqual(true, FileExist(watchFile) != "", "WatchPid keeps temp input while pid exists")
        AssertEqual(watchFile, SpeakSelectedText.LastInputFile, "WatchPid keeps LastInputFile while pid exists")
        AssertEqual(noWaitPid, SpeakSelectedText.TtsPid, "WatchPid keeps TtsPid while process exists")
        try ProcessClose(noWaitPid)
        deadline := A_TickCount + 3000
        while (ProcessExist(noWaitPid) && A_TickCount < deadline)
            Sleep 50
        SpeakSelectedText.WatchPid()
        AssertEqual(false, FileExist(watchFile) != "", "WatchPid deletes temp input after pid exits")
        AssertEqual("", SpeakSelectedText.LastInputFile, "WatchPid clears LastInputFile after pid exits")
        AssertEqual(0, SpeakSelectedText.TtsPid, "WatchPid clears TtsPid after pid exits")
    } finally {
        SpeakSelectedText.TtsPid := savedPid
        SpeakSelectedText.LastInputFile := savedFile
        SpeakSelectedText.WatchBound := savedWatch
        if FileExist(watchFile)
            FileDelete watchFile
    }
} finally {
    if (noWaitPid && ProcessExist(noWaitPid)) {
        try ProcessClose(noWaitPid)
    }
}
AssertContains(audioSwitcherSource, "ProcessNoWindow.RunWait(", "audio switcher waits without allocating a console")
AssertContains(audioSwitcherSource, "ChildTimeoutMs := 18000", "audio switcher parent timeout exceeds C# 12s wait")
AssertContains(audioSwitcherSource, "this.ChildTimeoutMs", "audio switcher passes timeout to ProcessNoWindow")
AssertNotContains(audioSwitcherSource, "cmd.exe /c", "audio switcher no longer wraps exe with cmd")
AssertContains(audioSwitcherSource, "耳机未就绪", "audio switcher HUD keeps headset-not-ready text")
AssertContains(audioSwitcherSource, "正在检查音频设备", "audio switcher shows HUD before waiting on exe")
AssertContains(audioSwitcherSource, "音频切换正在进行", "audio switcher no longer silently drops busy/debounce presses")
AssertContains(audioSwitcherSource, "MarkSuccess", "audio switcher only debounces after a successful switch")
AssertContains(audioSwitcherSource, "蓝牙已连但立体声未就绪", "audio switcher does not auto-elevate stereo-not-ready")
AssertContains(audioSwitcherSource, "ShouldAutoElevate", "audio switcher gates sudo behind an explicit helper")
AssertContains(audioSwitcherSource, "IsPermissionError", "audio switcher only auto-elevates permission errors")
AssertContains(audioSwitcherSource, "RemainingTimeout", "elevated retry shares the original timeout budget")
audioSwitcherCs := FileRead(A_ScriptDir "\..\..\tools\audio-switcher\AudioSwitcher.cs", "UTF-8")
audioSwitcherCfg := FileRead(A_ScriptDir "\..\..\tools\audio-switcher\config.toml", "UTF-8")
AssertContains(audioSwitcherCs, "TogglePreferredOutputs()", "audio switcher toggle uses preferred G27Q2/AirPods pair")
AssertContains(audioSwitcherCs, "IsPreferredHeadset", "audio switcher prefers AirPods stereo")
AssertContains(audioSwitcherCs, "Hands-Free", "audio switcher excludes Hands-Free endpoints")
AssertContains(audioSwitcherCs, "BluetoothSetServiceState", "audio switcher can enable AirPods A2DP")
AssertContains(audioSwitcherCs, "BluetoothGetDeviceInfo", "audio switcher refreshes device info before enabling A2DP")
AssertContains(audioSwitcherCs, "BluetoothServiceEnable", "audio switcher only enables Bluetooth audio sink")
AssertNotContains(audioSwitcherCs, "BluetoothServiceDisable", "audio switcher never disconnects AirPods")
AssertNotContains(audioSwitcherCs, "BluetoothSetServiceState A2DP Disable", "audio switcher no longer bounce-disables A2DP")
AssertContains(audioSwitcherCs, "PnpFallbackEnabled = false", "audio switcher disables PNP fallback by default")
AssertContains(audioSwitcherCs, "skip Pnp fallback", "audio switcher can skip Enable-PnpDevice")
AssertContains(audioSwitcherCs, "PreferredHeadsetBluetoothConnected()", "audio switcher still inspects Bluetooth connected state")
AssertContains(audioSwitcherCs, "HeadsetConnectAttempt", "audio switcher separates link success from Bluetooth connected")
AssertContains(audioSwitcherCs, "FinishHeadsetConnect(", "audio switcher classifies headset connect failures")
AssertContains(audioSwitcherCs, "LinkActionSucceeded", "audio switcher waits for ACTIVE only after a real link action")
AssertContains(audioSwitcherCs, "ERROR|蓝牙已连但立体声未就绪", "audio switcher fail-fast when Bluetooth is up but stereo is not ACTIVE")
AssertContains(audioSwitcherCs, "ERROR|连接超时", "audio switcher reports wait timeout separately")
AssertContains(audioSwitcherCs, "ERROR|耳机未取出或不在附近", "audio switcher reports remembered-but-disconnected headset")
AssertContains(audioSwitcherCs, "ERROR|设备节点不存在", "audio switcher maps missing PnP node separately")
AssertContains(audioSwitcherCs, "ERROR|耳机未激活", "audio switcher refuses SetDefault on non-ACTIVE endpoints")
AssertContains(audioSwitcherCs, "--debug-dump", "audio switcher exposes read-only debug dump")
AssertContains(audioSwitcherCfg, "pnp_fallback = false", "audio switcher config keeps PNP fallback off")
AssertContains(audioSwitcherCfg, "auto_elevate = false", "audio switcher config keeps auto elevate off")
AssertContains(audioSwitcherCfg, "connect_wait_ms = 12000", "audio switcher config wait stays 12s")
AssertContains(audioSwitcherCs, "0000110B-0000-1000-8000-00805F9B34FB", "audio switcher enables A2DP sink only")
AssertContains(audioSwitcherCs, "G27Q2", "audio switcher falls back to G27Q2")
AssertContains(audioSwitcherCs, "耳机未就绪", "audio switcher keeps a generic headset-not-ready fallback")
AssertContains(audioSwitcherCs, "0xE000020B", "audio switcher still detects missing device instance")
AssertContains(audioSwitcherCs, "(device.State & DeviceStateActive) == 0", "audio switcher never SetDefaults a non-active endpoint")
AssertNotContains(audioSwitcherCs, "knownHeadset", "audio switcher no longer SetDefaults stale AirPods endpoints")
AssertContains(audioSwitcherCs, "ConnectPreferredHeadset()", "audio switcher connects remembered AirPods before reporting not ready")
AssertContains(audioSwitcherCs, "DeviceStateMaskAll", "audio switcher looks up unpaired-but-remembered AirPods endpoints")
AssertContains(audioSwitcherCs, "PKEY_Device_DeviceDesc", "audio switcher can identify remembered AirPods by DeviceDesc")
AssertContains(audioSwitcherCs, "AddRememberedHeadsetIds(", "audio switcher recovers remembered AirPods endpoint IDs from the registry")
AssertContains(audioSwitcherCs, "ConnectAirPodsAudioProfile()", "audio switcher starts AirPods A2DP like the Bluetooth panel")
AssertContains(audioSwitcherCs, "WSASetService", "audio switcher registers the Bluetooth audio profile before waiting")
screenshotSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\screenshot.ps1", "UTF-8")
screenshotOcrSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\screenshot-ocr.ps1", "UTF-8")
ocrPySource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\ocr\ocr.py", "UTF-8")
AssertContains(screenshotSource, "ms-screenclip:", "screenshot opens the system clip overlay via protocol")
AssertNotContains(screenshotSource, "Start-Sleep -Milliseconds 700", "screenshot no longer waits 700ms after injecting the overlay")
AssertNotContains(screenshotSource, "Get-Process -Name 'SnippingTool'", "screenshot no longer probes SnippingTool before exiting")
AssertContains(screenshotOcrSource, "ms-screenclip:", "screenshot OCR opens the overlay before starting Python")
AssertContains(screenshotOcrSource, "--no-screenshot", "screenshot OCR tells RapidOCR not to inject Win+Shift+S again")
AssertContains(ocrPySource, "if inject_screenshot:", "ocr can still inject Win+Shift+S when launched directly")
AssertEqual(true, InStr(ocrPySource, "if inject_screenshot:") < InStr(ocrPySource, "engine = load_engine()"), "ocr injects screenshot before loading RapidOCR")
restartAhkSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\restart-autohotkey.ps1", "UTF-8")
resetNavicatRaycastSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\reset-navicat.ps1", "UTF-8")
toggleRgbSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\toggle-rgb.ps1", "UTF-8")
AssertContains(restartAhkSource, "@raycast.mode silent", "restart AutoHotkey stays silent so Raycast closes")
AssertContains(restartAhkSource, "Show-SystemToast -Title '✓ AutoHotkey 已重载'", "restart AutoHotkey success uses system toast")
AssertNotContains(restartAhkSource, "Show-ToolboxNotify", "restart AutoHotkey no longer uses shared HUD")
AssertNotContains(restartAhkSource, "Write-Output `"✓ $successText`"", "restart AutoHotkey no longer falls back to stdout HUD")
AssertContains(resetNavicatRaycastSource, "@raycast.mode silent", "reset Navicat stays silent so Raycast closes")
AssertContains(resetNavicatRaycastSource, "Show-SystemToast -Title '✓ Navicat 试用期已重置'", "reset Navicat success uses system toast")
AssertNotContains(resetNavicatRaycastSource, "Show-ToolboxNotify", "reset Navicat no longer uses shared HUD")
AssertContains(resetNavicatRaycastSource, "*>$null", "reset Navicat swallows child script output")
AssertContains(resetNavicatRaycastSource, "Show-SystemToast", "reset Navicat failures use system toast")
AssertNotContains(resetNavicatRaycastSource, "Write-Output '√ Navicat 试用期已重置'", "reset Navicat no longer uses stdout as the primary success HUD")
AssertContains(toggleRgbSource, "@raycast.mode silent", "toggle RGB stays silent so Raycast closes")
AssertContains(toggleRgbSource, "Show-SystemToast -Title `"💡 $Text`"", "toggle RGB success uses system toast")
AssertContains(toggleRgbSource, "RGB 灯光已关闭", "toggle RGB reports lights off")
AssertContains(toggleRgbSource, "RGB 灯光已开启", "toggle RGB reports lights on")
AssertNotContains(toggleRgbSource, "Show-ToolboxNotify", "toggle RGB no longer uses shared HUD")
AssertContains(screenshotOcrSource, "Show-SystemToast -Title '✓ OCR 文本已复制'", "screenshot OCR success uses system toast")
AssertNotContains(screenshotOcrSource, "Show-ToolboxNotify", "screenshot OCR no longer uses shared HUD")
AssertNotContains(ocrPySource, "Show-ToolboxNotify", "ocr.py comments no longer mention shared HUD adapter")
AssertNotContains(ocrPySource, "notify-cli.ahk", "ocr.py no longer launches notify-cli")
AssertNotContains(ocrPySource, "notify.exe", "ocr.py no longer looks for notify.exe")
AssertNotContains(ocrPySource, "notify_shared", "ocr.py no longer has notify_shared HUD helper")
AssertContains(ocrPySource, "toast.ps1", "manual OCR uses system toast")
AssertContains(toastAdapterSource, "function Show-SystemToast", "toast adapter still exposes Show-SystemToast")
AssertNotContains(toastAdapterSource, "function Show-ToolboxNotify", "toast adapter no longer exposes Show-ToolboxNotify")
AssertNotContains(toastAdapterSource, "notify-cli.ahk", "toast adapter no longer launches notify-cli.ahk")
AssertNotContains(toastAdapterSource, "notify.exe", "toast adapter no longer looks for notify.exe")
AssertContains(toastAdapterSource, "Start-ToolboxNotifyProcess -FilePath `"powershell.exe`"", "toast adapter reuses hidden process starter")
AssertNotContains(toastAdapterSource, "Start-Process -FilePath `"powershell.exe`"", "toast adapter no longer uses Start-Process")
AssertEqual(false, FileExist(A_ScriptDir "\..\..\shared\notify\notify-cli.ahk") != "", "legacy notify-cli.ahk is gone")
AssertEqual(false, DirExist(A_ScriptDir "\..\..\shared\notify\dev") != "", "legacy shared/notify/dev directory is gone")
AssertContains(dshNotifySource, "CreateNoWindow = $true", "dsh process starter creates no window")
AssertContains(dshNotifySource, "UseShellExecute = $false", "dsh process starter does not use the shell")
AssertContains(dshNotifySource, "function Invoke-TailscaleCommand", "dsh still owns tailscale wrapper")
AssertNotContains(dshNotifySource, 'cmd /c "tailscale', "dsh no longer shells tailscale through cmd")
AssertNotContains(dshNotifySource, 'cmd /c "sudo tailscale', "dsh no longer shells sudo tailscale through cmd")
AssertNotContains(dshStatusSource, "cmd /c", "dsh status no longer shells schtasks through cmd")
AssertNotContains(dshUninstallSource, "cmd /c", "dsh uninstall no longer shells schtasks through cmd")
AssertContains(dshInstallSource, "Start-DshHiddenProcess", "dsh install launches watcher without a console")
AssertNotContains(dshInstallSource, "Start-Process powershell.exe", "dsh install no longer uses Start-Process powershell")
AssertContains(dshRestartSource, "'/End'", "dsh restart ends the existing watcher task")
AssertContains(dshRestartSource, "'/Run'", "dsh restart reruns the existing watcher task")
AssertNotContains(dshRestartSource, "'/Delete'", "dsh restart does not delete the watcher task")
AssertNotContains(dshRestartSource, "'/Create'", "dsh restart does not recreate the watcher task")
AssertNotContains(dshRestartSource, "serve --https", "dsh restart does not touch Tailscale Serve")
AssertContains(dshNotifySource, "function Get-DshWatcherTaskInfo", "dsh utils expose watcher task info helper")
AssertContains(dshNotifySource, "Get-ScheduledTask -TaskName $taskName", "dsh watcher info prefers ScheduledTasks cmdlet")
AssertContains(dshNotifySource, "/FO', 'LIST', '/V'", "dsh watcher info still has schtasks LIST/V fallback")
AssertContains(dshStatusSource, "Get-DshWatcherTaskInfo", "dsh status uses shared watcher task info")
AssertContains(dshStatusSource, "watcher_last_run", "dsh status exposes watcher last run time")
AssertContains(dshRestartSource, "Get-DshWatcherTaskInfo", "dsh restart reports status via shared helper")
AssertContains(dshRestartSource, "AddSeconds(8)", "dsh restart polls the existing task instead of a fixed sleep")
AssertContains(dshRestartSource, "match 'Running'", "dsh restart confirms Running or reports the actual state")
AssertContains(dshNotifySource, "function Get-DshPortInfo", "dsh port probe is shared by Port and Source")
AssertContains(dshNotifySource, "ServeStatus", "dsh serve check can reuse an existing status string")
AssertContains(dshWatchSource, "Get-DshPortInfo", "dsh watcher resolves port once per reconcile")
AssertContains(dshWatchSource, "-ServeStatus $raw", "dsh watcher reuses the serve status it just fetched")
AssertContains(dshWatchSource, "Watcher started pid=", "dsh watcher logs its pid at startup")
AssertContains(dshWatchSource, "CommandLine 读不到时忽略这次 node 事件", "dsh watcher ignores unreadable node events")
AssertContains(dshStatusSource, "Get-DshPortInfo", "dsh status resolves port once")
AssertContains(dshStatusSource, "-ServeStatus $rawServe", "dsh status reuses serve status")
AssertContains(themeUtilsSource, "-WindowStyle Hidden", "theme action hides PowerShell")
AssertContains(themeUtilsSource, "-Hidden", "theme settings mark the task hidden")
AssertContains(themeUtilsSource, "function Set-WindowsColorMode", "theme mode writes Apps/System then refreshes shell")
AssertContains(themeUtilsSource, "Restart-ThemeExplorerShell", "theme mode can restart Explorer to resync tray")
AssertContains(themeUtilsSource, "RefreshImmersiveColorPolicyState", "theme refresh uses uxtheme color policy")
AssertContains(themeUtilsSource, "WM_THEMECHANGED", "theme refresh broadcasts WM_THEMECHANGED")
AssertContains(themeUtilsSource, "Invoke-ThemeShellRefresh -RestartExplorer:", "system color switch restarts Explorer")
AssertContains(themeUtilsSource, "CabinetWClass", "theme refresh enumerates Explorer folder windows")
AssertContains(themeUtilsSource, "ExploreWClass", "theme refresh also covers legacy Explorer windows")
AssertContains(themeUtilsSource, "DwmSetWindowAttribute", "theme refresh sets Explorer DWM immersive dark mode")
AssertContains(themeUtilsSource, "DWMWA_CAPTION_COLOR", "theme refresh paints Explorer caption to match Apps")
AssertContains(themeUtilsSource, "DWMWA_BORDER_COLOR", "theme refresh paints Explorer border to match Apps")
AssertContains(themeUtilsSource, "DWMWA_TEXT_COLOR", "theme refresh paints Explorer caption text to match Apps")
AssertContains(themeUtilsSource, "RedrawWindow", "theme refresh force-repaints Explorer client and frame")
AssertContains(themeUtilsSource, "RefreshExplorerWindows", "theme refresh exposes Explorer window DWM helper")
AssertContains(themeUtilsSource, "SendMessageTimeoutStr(hWnd, WM_SETTINGCHANGE", "theme refresh pokes open Explorer windows with ImmersiveColorSet")
AssertContains(themeUtilsSource, "Shell.Application", "theme refresh reloads open Explorer views without closing them")
AssertContains(themeUtilsSource, "$window.Refresh()", "theme refresh calls Shell.Application.Refresh on folder windows")
AssertContains(themeUtilsSource, "function Set-WindowsCursorScheme", "theme can switch cursor schemes with color mode")
AssertContains(themeUtilsSource, "function Disable-AccessibilityCursorOverlay", "cursor scheme clears the Accessibility colored pointer overlay")
AssertContains(themeUtilsSource, "CursorColor", "cursor overlay uses the Accessibility CursorColor value")
AssertContains(themeUtilsSource, "SPI_SETCURSORS", "cursor switch refreshes pointers via SystemParametersInfo")
AssertContains(themeUtilsSource, "SetSystemCursor", "cursor switch also applies live pointers via SetSystemCursor")
AssertContains(themeUtilsSource, "function Sync-ThemeFileCursors", "cursor switch writes the live .theme so unlock cannot restore Windows 11 pointers")
AssertContains(themeUtilsSource, "MSFT_TaskSessionStateChangeTrigger", "cursor restore uses a session-state scheduled task")
AssertContains(themeUtilsSource, "SessionUnlock", "cursor restore fires on unlock")
AssertContains(themeCursorsSource, "Set-WindowsCursorScheme -Mode $desired", "unlock restore reapplies the current cursor scheme")
AssertContains(themeCursorsSource, "$offsets = @(0, 1, 3, 8)", "unlock restore retries after Windows 11 delayed default pointers")
AssertContains(themeInstallSource, "Theme-Apply-Cursors", "installer registers the unlock cursor task")
AssertContains(themeUninstallSource, "Theme-Apply-Cursors", "uninstaller removes the unlock cursor task")
AssertContains(themeUpdateSource, "Theme-Apply-Cursors", "schedule updater keeps the unlock cursor task")
AssertContains(themeUtilsSource, "HKCU:\Control Panel\Cursors", "cursor switch writes the current-user cursor key")
AssertContains(themeUtilsSource, "resources\cursors\", "cursor switch defaults to repo resources/cursors")
AssertContains(themeLightSource, "Set-WindowsCursorScheme -Mode 'light'", "light theme applies the light cursor scheme")
AssertContains(themeDarkSource, "Set-WindowsCursorScheme -Mode 'dark'", "dark theme applies the dark cursor scheme")
AssertContains(themeApplySource, "Set-WindowsCursorScheme -Mode `$desired", "login align still applies cursor when color is already correct")
AssertContains(themeConfigSource, "[cursor]", "theme config exposes an independent cursor section")
AssertContains(themeConfigSource, "切深浅色时同步换鼠标", "cursor switch is documented independently from wallpaper")
AssertContains(themeConfigSource, "enabled = true", "cursor switch is enabled")
AssertContains(themeConfigSource, "light_scheme = `"Cursor Concept 3 Light`"", "theme config names the light cursor scheme")
AssertContains(themeConfigSource, "dark_scheme  = `"Cursor Concept 3 Dark`"", "theme config names the dark cursor scheme")
AssertEqual(true, DirExist(A_ScriptDir "\..\..\resources\cursors\light") != "", "light cursor pack exists")
AssertEqual(true, DirExist(A_ScriptDir "\..\..\resources\cursors\dark") != "", "dark cursor pack exists")
AssertEqual(true, FileExist(A_ScriptDir "\..\..\resources\cursors\Agreement.txt") != "", "cursor pack keeps the author license")
AssertEqual(true, FileExist(A_ScriptDir "\..\..\resources\cursors\light\arrow.cur") != "", "light cursor pack includes arrow.cur")
AssertEqual(true, FileExist(A_ScriptDir "\..\..\resources\cursors\dark\arrow.cur") != "", "dark cursor pack includes arrow.cur")
AssertContains(themeUpdateSource, "Repair-ThemeScheduledTaskWindow", "theme schedule updater keeps hidden actions")
AssertContains(dshNotifySource, 'Show-SystemToast -Title "$resolvedIcon DSH Remote"', "dsh toast uses resolved icon title")
AssertContains(dshNotifySource, 'success" { "✓"', "dsh maps success to check icon")
AssertNotContains(dshNotifySource, 'Icon = "0"', "dsh notify default icon is not a placeholder zero")
AssertNotContains(dshWatchSource, 'Icon "0"', "dsh watcher no longer sends placeholder icon")
AssertContains(dshWatchSource, "$reconcileSec = 60", "dsh watcher default reconcile is 60s")
AssertContains(dshWatchSource, "if ($cfgPoll -ge 30)", "dsh watcher ignores poll_interval below 30s")
AssertContains(dshWatchSource, "[Math]::Max(30, $PollInterval)", "dsh watcher command-line poll below 30s is raised to 30")
AssertNotContains(dshWatchSource, 'Write-Log "Reconcile (periodic ${reconcileSec}s)"', "dsh watcher no longer logs periodic heartbeat")
AssertNotContains(dshWatchSource, "non-DSH, ignored", "dsh watcher no longer logs non-DSH node events")
AssertContains(dshNotifySource, "poll_interval = 60", "dsh config default poll_interval is 60")
AssertContains(dshConfigSource, "poll_interval = 60", "dsh config.toml poll_interval stays 60")
AssertContains(dshConfigSource, "配置值 < 30 会被忽略", "dsh config.toml documents the 30s floor")
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
translateSource := FileRead(A_ScriptDir "\..\features\translate-selected-text.ahk", "UTF-8")
pythonSource := FileRead(A_ScriptDir "\..\..\shared\python.ahk", "UTF-8")
dshStartSource := FileRead(A_ScriptDir "\..\..\tools\dsh-remote\Start-DshRemote.ps1", "UTF-8")
AssertContains(pythonSource, "class ToolboxPython", "shared python helper defines ToolboxPython")
AssertContains(mainSource, "#Include ..\shared\python.ahk", "main loads shared python helper once")
AssertContains(mainSource, "#Include ..\shared\notify\translation-panel.ahk", "main loads WinUI translation panel client")
AssertNotContains(mainSource, "#Include ..\shared\notify\anchor.ahk", "main does not re-include caret anchor")
AssertContains(mainSource, "#Include ..\shared\notify\ime-hud.ahk", "main loads ImeHud client")
AssertNotContains(speakSource, "python.ahk", "speak does not include python helper")
AssertNotContains(translateSource, "python.ahk", "translate does not include python helper")
AssertContains(speakSource, "ToolboxPython.ResolveW()", "speak resolves python via shared helper")
AssertContains(translateSource, "ToolboxPython.ResolveW()", "translate resolves python via shared helper")
AssertNotContains(dshStartSource, "Get-DshProcessSnapshot", "start does not snapshot processes before port probe")
AssertContains(dshNotifySource, "if ($null -eq $Snapshot) { $Snapshot = Get-DshProcessSnapshot }", "port probe snapshots only after store miss")
AssertNotContains(speakSource, "Shortcuts.", "speak is independent from shortcut config")
AssertContains(speakSource, "Caps+S", "speak log uses Caps+S")
AssertNotContains(speakSource, "Ctrl+Alt+S", "speak log no longer mentions Ctrl+Alt+S")
AssertContains(speakSource, "18000", "speak headset warmup timeout exceeds C# 12s wait")
AssertContains(speakSource, "lat3ncy-tts-in-", "speak uses unique TTS input files")
AssertNotContains(speakSource, "lat3ncy-tts-input.txt", "speak no longer reuses a fixed TTS input file")
AssertContains(speakSource, "WatchPid", "speak watches the TTS pid to delete temp input")
AssertContains(speakSource, 'ClipboardAll()', "speak captures clipboard safely")
AssertContains(speakSource, 'finally', "speak restores clipboard in finally block")
AssertContains(speakSource, 'mciSendStringW', "speak uses MCI to close audio")
AssertNotContains(translateSource, "Shortcuts.", "translate is independent from shortcut config")
AssertContains(translateSource, "ClipboardAll()", "translate captures clipboard safely")
AssertContains(translateSource, "finally", "translate restores clipboard in finally block")
AssertContains(translateSource, "MouseGetPos", "translate records mouse-at-hotkey before copying selection")
AssertContains(translateSource, 'CoordMode "Mouse", "Screen"', "translate MouseGetPos uses screen pixels, not client")
AssertContains(translateSource, "TranslationPanel.OpenText(", "translate opens WinUI panel with explicit source")
AssertContains(translateSource, "TranslationPanel.SetResult(", "translate success fills explicit RESULT")
AssertContains(translateSource, "TranslationPanel.Close()", "translate failure closes the WinUI panel")
AssertNotContains(translateSource, "Notify.Popup(", "translate no longer uses AHK popup HUD for success")
AssertContains(translateSource, 'if (code = "auth"', "translate treats cloud auth as a dedicated failure")
AssertContains(translateSource, "翻译密钥无效", "translate auth failure has a stable toast fallback")
AssertContains(translateSource, 'Notify.Error("×", message)', "translate failures use system toast, not HUD")
AssertContains(translateSource, "lat3ncy-translate-in-", "translate uses unique input files")
AssertContains(translateSource, "ProcessNoWindow.RunWait(", "translate waits without a console")
AssertContains(translateSource, "14000", "translate parent timeout covers tencent plus fallbacks")
translatePySource := FileRead(A_ScriptDir "\\..\\..\\tools\\translate\\translate.py", "UTF-8")
translateCfgSource := FileRead(A_ScriptDir "\\..\\..\\tools\\translate\\config.toml", "UTF-8")
AssertContains(translatePySource, "def translate_tencent(", "translate helper implements Tencent TMT")
AssertContains(translatePySource, "TextTranslate", "translate uses Tencent TextTranslate")
AssertContains(translatePySource, "TENCENTCLOUD_SECRET_ID", "translate reads Tencent env keys")
AssertContains(translatePySource, "read_user_env", "translate can read HKCU user env without restarting AHK")
AssertContains(translatePySource, "class AuthError", "cloud auth errors are typed")
AssertContains(translatePySource, 'code="auth"', "cloud auth writes auth status for AHK")
AssertContains(translatePySource, "except AuthError:", "cloud auth does not fall back to Google")
AssertContains(translatePySource, "腾讯云密钥无效", "Tencent auth toast text is stable")
AssertContains(translateCfgSource, 'engine = "tencent"', "translate config defaults to Tencent")
AssertContains(translateCfgSource, "timeout_s = 4", "translate request timeout stays 4s")
ambientSource := FileRead(A_ScriptDir "\..\..\tools\rgb\ambient.py", "UTF-8")
AssertContains(ambientSource, "mss reopened after grab fail", "ambient reopens mss after lock-screen BitBlt")
AssertContains(ambientSource, "skip-grab", "ambient keeps running when grab returns None")
AssertContains(ambientSource, "grab failed:", "ambient swallows capture exceptions in the main loop")

searchSource := FileRead(A_ScriptDir "\..\features\search-selected-text.ahk", "UTF-8")
openSource := FileRead(A_ScriptDir "\..\features\open-selected-target.ahk", "UTF-8")
locateSource := FileRead(A_ScriptDir "\..\features\locate-selected-target.ahk", "UTF-8")
smartPasteSource := FileRead(A_ScriptDir "\..\features\smart-paste\smart-paste.ahk", "UTF-8")
capsLockSource := FileRead(A_ScriptDir "\..\features\caps-lock-ime.ahk", "UTF-8")
routerSource := FileRead(A_ScriptDir "\..\hotkey-router.ahk", "UTF-8")
rendererSource := FileRead(A_ScriptDir "\..\..\shared\notify\renderer.ahk", "UTF-8")
notifySource := FileRead(A_ScriptDir "\..\..\shared\notify\notify.ahk", "UTF-8")
pathsSource := FileRead(A_ScriptDir "\..\..\shared\notify\paths.ahk", "UTF-8")
translationPanelSource := FileRead(A_ScriptDir "\..\..\shared\notify\translation-panel.ahk", "UTF-8")
anchorSource := FileRead(A_ScriptDir "\..\..\shared\notify\anchor.ahk", "UTF-8")
hardcodedRepoRoot := "C:\Users\Jie\Projects\lat3ncy-scripts-toolbox"
for sourcePair in [
    ["main.ahk", mainSource],
    ["notify.ahk", notifySource],
    ["paths.ahk", pathsSource],
    ["anchor.ahk", anchorSource]
] {
    AssertNotContains(sourcePair[2], hardcodedRepoRoot, sourcePair[1] " has no hardcoded repo path")
}
AssertContains(pathsSource, "class NotifyPaths", "shared path resolver exists")
AssertContains(pathsSource, "A_WorkingDir", "path resolver covers temp test stubs")
AssertContains(pathsSource, "ImeHudWinUiExe()", "path resolver can find WinUI renderer")
AssertContains(pathsSource, "ime-hud-winui\out\ImeHudWinUi.exe", "WinUI exe path stays under ime-hud-winui/out")
AssertNotContains(pathsSource, "static ImeHudExe()", "path resolver no longer exposes ImeHud.exe")
AssertNotContains(pathsSource, "tools\ime-hud\ImeHud.exe", "path resolver no longer looks for old ImeHud.exe")
AssertEqual(false, DirExist(A_ScriptDir "\..\..\tools\ime-hud") != "", "legacy tools\\ime-hud directory is gone")
runnerSource := FileRead(A_ScriptDir "\run-tests.ps1", "UTF-8")
AssertNotContains(runnerSource, "ImeHud.dll", "test runner no longer executes WPF ImeHud.dll")
AssertContains(runnerSource, "legacy tools/ime-hud still exists", "test runner rejects leftover WPF ImeHud directory")
imeHudClientSource := FileRead(A_ScriptDir "\..\..\shared\notify\ime-hud.ahk", "UTF-8")
AssertContains(imeHudClientSource, "class ImeHud", "IME HUD client exists")
AssertContains(imeHudClientSource, "Lat3ncyImeHudWinUi", "IME HUD client talks to WinUI title")
AssertContains(imeHudClientSource, "NotifyPaths.ImeHudWinUiExe()", "IME HUD client resolves WinUI exe")
AssertContains(imeHudClientSource, "MessageTimeout := 2500", "IME HUD COPYDATA timeout covers WinUI ShowState")
AssertContains(rendererSource, "#Include anchor.ahk", "renderer loads caret anchor for AHK chips")
AssertContains(imeHudClientSource, "#Include anchor.ahk", "IME HUD client loads caret anchor")
AssertContains(imeHudClientSource, "InputAnchor.Get()", "IME HUD Show samples caret before sending STATE")
AssertContains(imeHudClientSource, "static BuildStateCommand(", "IME HUD can format STATE without launching WinUI")
AssertNotContains(imeHudClientSource, "x := 0, y := 0, durationMs := 0", "IME HUD Show no longer defaults caret to origin")
AssertNotContains(imeHudClientSource, "NotifyPaths.ImeHudExe()", "IME HUD client does not launch ImeHud.exe")
AssertNotContains(imeHudClientSource, "Lat3ncyImeHud`"", "IME HUD client does not look up a non-WinUI HUD title")
AssertContains(translationPanelSource, "class TranslationPanel", "WinUI translation client exists")
AssertContains(translationPanelSource, "Lat3ncyImeHudWinUi", "translation client talks to independent WinUI title")
AssertContains(translationPanelSource, "NotifyPaths.ImeHudWinUiExe()", "translation client resolves WinUI exe")
AssertNotContains(translationPanelSource, "NotifyPaths.ImeHudExe()", "translation client does not launch ImeHud.exe")
AssertNotContains(translationPanelSource, "Lat3ncyImeHud`"", "translation client does not look up a non-WinUI HUD title")
AssertContains(translationPanelSource, "WM_COPYDATA", "translation client sends WM_COPYDATA")
AssertContains(translateSource, "#Include ..\..\shared\notify\translation-panel.ahk", "translate loads WinUI panel client")
AssertContains(anchorSource, "GetWin32Caret", "anchor probes Win32 caret in-process")
AssertContains(anchorSource, "hwndCaretOffset := 8 + 5 * A_PtrSize", "Win32 caret reads hwndCaret, not hwndMoveSize")
AssertContains(anchorSource, "rcCaretOffset := 8 + 6 * A_PtrSize", "Win32 caret RECT starts after six HWND fields")
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
AssertContains(capsLockSource, "PersistImeAcrossWindows", "Caps can persist IME across windows")
AssertContains(capsLockSource, "RememberImeState", "Caps records last explicit IME state")
AssertContains(capsLockSource, "WatchForeground", "Caps restores IME after focus change")
AssertContains(capsLockSource, "static UseImeHud := true", "Caps can roll back to AHK HUD with one switch")
AssertContains(capsLockSource, 'this.ShowImeHud("CN")', "Caps shows CN through ImeHud")
AssertContains(capsLockSource, 'this.ShowImeHud("EN")', "Caps shows EN through ImeHud")
AssertContains(capsLockSource, 'this.ShowImeHud("CAPS")', "Caps shows CAPS through ImeHud")
AssertContains(capsLockSource, "#Include ..\..\shared\notify\ime-hud.ahk", "Caps loads ImeHud client")
AssertContains(capsLockSource, "ImmSetOpenStatus", "Caps closes IME when switching to English")
AssertContains(capsLockSource, "IMC_SETOPENSTATUS", "Caps window path also sets IME open status")
AssertContains(capsLockSource, "SendImeToggleShift", "Caps Shift fallback uses SendEvent")
AssertContains(capsLockSource, "LShift down", "Caps Shift fallback is a left-shift key event")
AssertNotContains(capsLockSource, 'Send "{Shift}"', "Caps no longer relies on SendInput Shift")
AssertContains(capsLockSource, 'A_ScriptName != "main.ahk"', "Caps IME watcher only starts from main.ahk")
AssertContains(routerSource, "RegisterCapsChord", "router owns Caps chord wiring")
AssertContains(routerSource, "MarkCapsChordUsed()", "router marks Caps chord before dispatch")
AssertContains(routerSource, "if !MarkCapsChordUsed()", "router drops rejected Caps chords")
AssertContains(routerSource, "划词翻译", "router registers translate chord")
AssertContains(routerSource, "切换点文件", "router registers dotfiles chord")
AssertContains(routerSource, "Shortcuts.ToggleDotfiles", "router binds the dotfiles shortcut")
AssertContains(routerSource, "SmartPaste.Configure", "router injects Smart Paste shortcuts")
AssertContains(rendererSource, "class NotifyRenderer", "shared renderer exists")
AssertContains(notifySource, 'this.Show("popup", "", text, duration)', "translate popup has no switch icon")
AssertContains(notifySource, "LastPopupTruncated", "truncated popup copies full text")
AssertContains(rendererSource, "static MeasurePopupText(", "renderer measures popup by real line breaks")
AssertContains(rendererSource, "opaqueClient := isTextOnly || isPopup", "popup uses opaque client like the chip")
AssertContains(rendererSource, 'this.PopupTextSize " w" this.PopupTextWeight " q5', "popup draws with measured size and SemiLight")
AssertContains(rendererSource, "EnableSystemDropShadow", "chip enables system drop shadow")
AssertContains(rendererSource, "CS_DROPSHADOW", "chip uses CS_DROPSHADOW")
AssertContains(rendererSource, "opaqueClient ? 3 : 2", "chip uses ROUNDSMALL corners")
AssertContains(rendererSource, "theme.ChipBg", "chip fill is independent from long HUD")
AssertContains(rendererSource, "static HudTitle := `"Lat3ncyNotifyHUD`"", "renderer tags HUD windows for orphan recovery")
AssertContains(rendererSource, "static ClampRefreshDuration(duration)", "renderer caps continuous HUD refresh")
AssertContains(rendererSource, "static CloseOrphans()", "renderer recovers orphan HUD windows")
AssertContains(notifySource, "static ClampDuration(duration, fallback := 0)", "notify clamps zero and huge durations")
AssertContains(notifySource, "static MaxDurationMs := 10000", "notify HUD hard cap is 10s")
AssertContains(mainSource, "NotifyRenderer.CloseOrphans()", "main closes orphan HUD windows on startup")
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
    FileRead(A_ScriptDir "\..\features\toggle-dotfiles.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\toggle-file-extensions.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\foreground-process.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\audio-switcher.ahk", "UTF-8"),
    FileRead(A_ScriptDir "\..\features\switch-app-window.ahk", "UTF-8"),
    translateSource
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
dotfilesSource := FileRead(A_ScriptDir "\..\features\toggle-dotfiles.ahk", "UTF-8")
AssertContains(mainSource, "#Include features\toggle-dotfiles.ahk", "main loads toggle-dotfiles")
AssertContains(dotfilesSource, "FileSetAttrib `"+H`"", "dotfiles hide by setting Hidden")
AssertContains(dotfilesSource, "FileSetAttrib `"-H`"", "dotfiles restore by clearing Hidden")
AssertContains(dotfilesSource, "alreadyHidden", "dotfiles adopt already-hidden entries")
AssertContains(dotfilesSource, "ClearNames", "dotfiles restore clears managed names")
AssertContains(dotfilesSource, "GetActiveExplorerDir", "dotfiles target the active Explorer folder")
AssertContains(dotfilesSource, "Loop Files", "dotfiles enumerate top-level entries only")
AssertNotContains(dotfilesSource, '"R"', "dotfiles do not recurse into subfolders")
AssertNotContains(dotfilesSource, "prehidden", "dotfiles no longer skip original hidden files")
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



