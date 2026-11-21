#Requires AutoHotkey v2.0
#Warn VarUnset, StdOut
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

global AsyncTimerTicks := 0
AsyncTimerTick() {
    global AsyncTimerTicks
    AsyncTimerTicks += 1
}

; 非阻塞轮询到任务完成；测试里用 Sleep 让 AHK 定时器有机会运行。
WaitAsyncJob(job, timeoutMs := 10000) {
    deadline := A_TickCount + timeoutMs
    while (!job.Done && A_TickCount < deadline) {
        job.Poll()
        Sleep 25
    }
    return job
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

; 翻译轮询测试替身：完成状态只由 Poll() 推进，复现真实 ProcessNoWindowJob 的契约。
class FakeTranslationJob {
    __New(finalStatus := "exited", completeOnPoll := true) {
        this.Status := "running"
        this.FinalStatus := finalStatus
        this.CompleteOnPoll := completeOnPoll
        this.Done := false
        this.PollCount := 0
        this.CancelCount := 0
        this.Cancelled := false
        this.Pid := 999999
        this.HandlesClosed := false
    }

    Poll() {
        this.PollCount += 1
        if this.CompleteOnPoll {
            this.Done := true
            this.Status := this.FinalStatus
        } else if (this.CancelCount > 0) {
            this.Done := true
            this.Status := "cancelled"
            this.Cancelled := true
        }
        return this.Status
    }

    Cancel() {
        this.CancelCount += 1
    }

    Dispose() {
        this.Done := true
        this.HandlesClosed := true
    }
}

; 构造翻译任务并复位模块静态状态；返回清理用的快照。
PrepareTranslationPollState(gate, task) {
    saved := {
        tasks: TranslateSelectedText.Tasks,
        current: TranslateSelectedText.CurrentTask,
        gate: TranslateSelectedText.RequestGate,
        hooks: TranslateSelectedText.Hooks,
        timer: TranslateSelectedText.PollTimer
    }
    TranslateSelectedText.Tasks := [task]
    TranslateSelectedText.CurrentTask := task
    TranslateSelectedText.RequestGate := gate
    TranslateSelectedText.PollTimer := ""
    TranslateSelectedText.Hooks := 0
    return saved
}

RestoreTranslationPollState(saved) {
    TranslateSelectedText.Tasks := saved.tasks
    TranslateSelectedText.CurrentTask := saved.current
    TranslateSelectedText.RequestGate := saved.gate
    TranslateSelectedText.Hooks := saved.hooks
    TranslateSelectedText.PollTimer := saved.timer
}

global PollHookCaptured := 0
PollHookPopup(text) {
    global PollHookCaptured
    PollHookCaptured.popup := text
}
PollHookError(message) {
    global PollHookCaptured
    PollHookCaptured.error := message
}
PollHookResult(text) {
    global PollHookCaptured
    PollHookCaptured.result := text
}
PollHookClose() {
    global PollHookCaptured
    PollHookCaptured.close += 1
}
PollHookPanelOpen() {
    global PollHookCaptured
    return PollHookCaptured.panelOpen
}
NewTranslationHooks() {
    global PollHookCaptured
    PollHookCaptured := { popup: "", error: "", result: "", close: 0, panelOpen: true }
    return Map(
        "popup", PollHookPopup,
        "error", PollHookError,
        "result", PollHookResult,
        "close", PollHookClose,
        "panelOpen", PollHookPanelOpen
    )
}

mainSource := FileRead(A_ScriptDir "\..\main.ahk", "UTF-8")
startupTruePosition := InStr(mainSource, "global ToolboxStarting := true")
startupHandlerPosition := InStr(mainSource, "OnError ToolboxStartupErrorHandler")
rendererIncludePosition := InStr(mainSource, "#Include ..\shared\notify\renderer.ahk")
notifyIncludePosition := InStr(mainSource, "#Include ..\shared\notify\notify.ahk")
panelIncludePosition := InStr(mainSource, "#Include ..\shared\notify\translation-panel.ahk")
imeHudIncludePosition := InStr(mainSource, "#Include ..\shared\notify\ime-hud.ahk")
toolboxInstanceIncludePosition := InStr(mainSource, "#Include ..\shared\notify\toolbox-instance.ahk")
pythonIncludePosition := InStr(mainSource, "#Include ..\shared\python.ahk")
firstFeatureIncludePosition := InStr(mainSource, "#Include features\caps-lock-ime.ahk")
lastFeatureIncludePosition := InStr(mainSource, "#Include features\foreground-process.ahk")
routerIncludePosition := InStr(mainSource, "#Include hotkey-router.ahk")
markerInitPosition := InStr(mainSource, "ToolboxInstance.Init(toolboxRepoDir)")
startupFalsePosition := InStr(mainSource, "`nToolboxStarting := false")
AssertEqual(true, startupTruePosition > 0, "startup flag exists")
AssertEqual(true, startupHandlerPosition > startupTruePosition, "startup handler follows flag")
AssertEqual(true, rendererIncludePosition > startupHandlerPosition, "renderer loads after startup handler")
AssertEqual(true, notifyIncludePosition > rendererIncludePosition, "notify API loads after renderer")
AssertEqual(true, panelIncludePosition > notifyIncludePosition, "translation panel client loads after notify")
AssertEqual(true, imeHudIncludePosition > panelIncludePosition, "ImeHud client loads after translation panel client")
AssertEqual(true, toolboxInstanceIncludePosition > imeHudIncludePosition, "instance marker loads after ImeHud client")
AssertEqual(true, pythonIncludePosition > toolboxInstanceIncludePosition, "python helper loads after instance marker")
AssertEqual(true, markerInitPosition > routerIncludePosition, "instance marker is created after the router")
AssertEqual(true, markerInitPosition < startupFalsePosition, "instance marker is created before startup success")
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
AssertEqual(600, ImeHud.MessageTimeout, "ImeHud COPYDATA timeout stays short so a cold HUD retries fast")
AssertEqual(3, ImeHud.SendAttempts, "ImeHud retries short COPYDATA timeouts before killing the HUD")
AssertEqual(350, ImeHud.FirstWaitMs, "ImeHud does not block long when the caret helper has no answer yet")
AssertEqual(43200000, ImeHud.CaretServerMs, "caret helper stays resident for a whole session")
AssertEqual(true, HasMethod(ImeHud, "Show"), "ImeHud client can show a state")
AssertEqual(true, HasMethod(ImeHud, "BuildStateCommand"), "ImeHud can format STATE without launching WinUI")
AssertEqual(true, HasMethod(ImeHud, "SendCopyData"), "ImeHud client sends WM_COPYDATA")
AssertEqual("STATE|CN|820|642|0|0", ImeHud.BuildStateCommand("CN", 820, 642, 0, 0), "STATE keeps caret hint")
AssertEqual("STATE|EN|0|0|0|0", ImeHud.BuildStateCommand("EN", 0, 0, 0, 0), "STATE zero coords stay explicit")
AssertEqual("STATE|CAPS|12|34|96|750", ImeHud.BuildStateCommand("CAPS", 12, 34, 96, 750), "STATE keeps dpi and duration")

; --- 锚点来源 + 跟随循环：隔离 WinUI（DisableSend）后直接驱动真实客户端 ---
AssertEqual(false, ImeHud.DisableSend, "production ImeHud always sends to WinUI")
AssertEqual("unknown", ImeHud.NormalizeSource(""), "empty anchor source normalizes to unknown")
AssertEqual("text-caret", ImeHud.NormalizeSource("text-caret"), "anchor source keeps safe characters")
AssertEqual("win32caret", ImeHud.NormalizeSource("win32|caret"), "anchor source drops protocol separators")
AssertEqual("STATE|CN|820|642|0|0", ImeHud.BuildStateCommand("CN", 820, 642, 0, 0), "STATE without source stays backward compatible")
AssertEqual("STATE|CN|820|642|0|0||text-caret", ImeHud.BuildStateCommand("CN", 820, 642, 0, 0, 0, "text-caret"), "STATE keeps a source even without a target hwnd")
AssertEqual("STATE|EN|10|20|0|0|4242|target-window-bottom", ImeHud.BuildStateCommand("EN", 10, 20, 0, 0, 4242, "target-window-bottom"), "STATE keeps degraded sources visible")

AssertEqual(true, InputAnchor.IsRealCaretSource("text-caret"), "text-caret counts as a real caret")
AssertEqual(true, InputAnchor.IsRealCaretSource("win32-caret"), "win32-caret counts as a real caret")
AssertEqual(true, InputAnchor.IsRealCaretSource("imm-caret"), "imm-caret counts as a real caret")
AssertEqual(false, InputAnchor.IsRealCaretSource("focus-bounds"), "focus-bounds is not a real caret")
AssertEqual(false, InputAnchor.IsRealCaretSource("focus-text"), "focus-text is not a real caret")
AssertEqual(false, InputAnchor.IsRealCaretSource("target-window-bottom"), "window-bottom is not a real caret")
AssertEqual(false, InputAnchor.IsRealCaretSource(""), "empty source is not a real caret")

followFile := A_Temp "\lat3ncy-follow-test-" A_TickCount ".txt"
try FileDelete(followFile)
try FileAppend(
    "A|1500|900|22|text-caret`n"
    . "A|1516|900|22|text-caret`n"
    . "A|1532|900|22|focus-bounds`n"
    . "E|timeout-followed`n",
    followFile,
    "UTF-8")
ImeHud._followFile := followFile
ImeHud._followOffset := 0
ImeHud._followSeen := 0
ImeHud._followUpgraded := false
ImeHud._followPid := 999999
ImeHud._followState := "CN"
ImeHud._followTarget := 4242
ImeHud.LastAnchorSource := "focus-bounds"
ImeHud.DisableSend := true
ImeHud.FollowTick()
moveCommand := ImeHud.LastCommand
AssertEqual("MOVE|CN|1516|900|0|0|4242|text-caret", moveCommand, "MOVE forwards the followed caret position")
AssertEqual(2, ImeHud._followSeen, "follow ignores degraded follow lines")
AssertEqual(true, ImeHud._followUpgraded, "follow records the upgrade from a degraded anchor to a real caret")
AssertEqual(0, ImeHud._followPid, "follow stops on the end marker from the watcher")
ImeHud.DisableSend := false
ImeHud._followFile := ""

AssertEqual(false, HasMethod(NotifyPaths, "ImeHudExe"), "path resolver no longer exposes ImeHud.exe")
AssertEqual("Lat3ncyImeHudWinUi", TranslationPanel.WindowClass, "WinUI translation client uses independent class")
AssertEqual("Lat3ncyImeHudWinUi", TranslationPanel.WindowTitle, "WinUI translation client uses independent title")
AssertEqual(true, HasMethod(TranslationPanel, "OpenText"), "translation panel can OPEN with explicit source")
AssertEqual(true, HasMethod(TranslationPanel, "SetResult"), "translation panel can send RESULT")
AssertEqual(true, HasMethod(TranslationPanel, "Close"), "translation panel can CLOSE")
AssertEqual(true, HasMethod(TranslationPanel, "SendCopyData"), "translation panel sends WM_COPYDATA")
AssertEqual(true, HasMethod(NotifyPaths, "ImeHudWinUiExe"), "path resolver exposes ImeHudWinUi.exe")
productionHudPath := NotifyPaths.Expand(A_ScriptDir "\..\..\tools\ime-hud-winui\out\ImeHudWinUi.exe")
AssertEqual(FileExist(productionHudPath) ? productionHudPath : "", NotifyPaths.ImeHudWinUiExe(), "renderer resolver uses production output only when published")
AssertEqual(true, FileExist(A_ScriptDir "\..\..\tools\ime-hud-winui\test-out\ImeHudWinUi.exe") != "", "source-built test renderer exists independently of production output")
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
ttsRuntimeFixture := A_Temp "\lat3ncy-tts-runtime-" A_TickCount
try {
    DirCreate ttsRuntimeFixture "\.venv\Scripts"
    runtimeCandidate := ttsRuntimeFixture "\.venv\Scripts\pythonw.exe"
    FileAppend "fixture; never executed", runtimeCandidate
    AssertEqual(runtimeCandidate, SpeakSelectedText.ResolvePython(ttsRuntimeFixture "\tts_player.py"), "speak prefers its module environment")
    FileDelete runtimeCandidate
    AssertEqual(ToolboxPython.ResolveW(), SpeakSelectedText.ResolvePython(ttsRuntimeFixture "\tts_player.py"), "speak retains global fallback when module environment is absent")
} finally {
    if DirExist(ttsRuntimeFixture)
        DirDelete ttsRuntimeFixture, true
}
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
toastAdapterSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\_lib\notify.ps1", "UTF-8")
themeUtilsSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\ThemeUtils.ps1", "UTF-8")
themeUpdateSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Update-ThemeSchedule.ps1", "UTF-8")
themeLightSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Set-Theme-Light.ps1", "UTF-8")
themeDarkSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Set-Theme-Dark.ps1", "UTF-8")
themeApplySource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Apply-ThemeNow.ps1", "UTF-8")
themeCursorsSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Apply-CursorsNow.ps1", "UTF-8")
themeTailSource := FileRead(A_ScriptDir "\..\..\tools\theme-scheduler\Set-Theme-Tail.ps1", "UTF-8")
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
noWaitPid := ProcessNoWindow.Run("ping.exe 127.0.0.1 -n 8")
try {
    AssertEqual(true, noWaitPid > 0 && ProcessExist(noWaitPid) != 0, "non-wait Run still returns a live pid")
} finally {
    if ProcessExist(noWaitPid)
        ProcessClose noWaitPid
}

; --- 异步子进程：等待期间热键线程已返回，AHK 定时器仍能运行 ---
AsyncTimerTicks := 0
SetTimer(AsyncTimerTick, 50)
asyncJob := ProcessNoWindow.StartAsync("cmd.exe /c ping 127.0.0.1 -n 4 >nul", "", 10000)
try {
    Sleep 400
    AssertEqual(false, asyncJob.Done, "async job keeps running after the start call returned")
    AssertEqual(true, AsyncTimerTicks > 0, "AHK timer keeps firing while the async job runs")
    WaitAsyncJob(asyncJob)
    AssertEqual("exited", asyncJob.Status, "async job reports natural exit")
    AssertEqual(true, asyncJob.HandlesClosed, "async job closes process and job handles")
} finally {
    SetTimer(AsyncTimerTick, 0)
    if (!asyncJob.Done)
        asyncJob.Dispose()
}
AssertEqual(true, AsyncTimerTicks > 0, "timer ticks are observable after the async job finishes")

; --- 异步 stdout 重定向：Done 之后再读文件，内容完整可解析 ---
asyncOutFile := A_Temp "\lat3ncy-async-out-" A_TickCount "-" Random(1000, 9999) ".txt"
asyncOutJob := ProcessNoWindow.StartAsync("cmd.exe /c echo async-ok", asyncOutFile, 10000)
try {
    WaitAsyncJob(asyncOutJob)
    AssertEqual("exited", asyncOutJob.Status, "async stdout job completes normally")
    AssertEqual("async-ok", Trim(FileRead(asyncOutFile, "UTF-8"), "`r`n"), "async stdout file is complete after Done")
} finally {
    if (!asyncOutJob.Done)
        asyncOutJob.Dispose()
    if FileExist(asyncOutFile)
        FileDelete asyncOutFile
}

; --- 异步超时：杀进程树并回收句柄，不能留下后台子进程 ---
timeoutJob := ProcessNoWindow.StartAsync("cmd.exe /c ping 127.0.0.1 -n 8 >nul", "", 200)
WaitAsyncJob(timeoutJob, 6000)
AssertEqual("timedout", timeoutJob.Status, "async job reports timeout")
AssertEqual(true, timeoutJob.TimedOut, "async job marks timeout")
AssertEqual(true, timeoutJob.HandlesClosed, "timed out async job closes handles")
AssertEqual(0, timeoutJob.hProcess, "timed out async job drops the process handle")
AssertEqual(0, timeoutJob.hJob, "timed out async job drops the job handle")
timeoutDeadline := A_TickCount + 3000
while (ProcessExist(timeoutJob.Pid) && A_TickCount < timeoutDeadline)
    Sleep 50
AssertEqual(0, ProcessExist(timeoutJob.Pid), "timed out async job terminates the child process tree")

; --- 取消：立即标记 cancelled，完成轮询后句柄和进程都被清理 ---
cancelJob := ProcessNoWindow.StartAsync("cmd.exe /c ping 127.0.0.1 -n 8 >nul", "", 10000)
Sleep 100
cancelJob.Cancel()
WaitAsyncJob(cancelJob, 6000)
AssertEqual("cancelled", cancelJob.Status, "async cancel reports cancelled")
AssertEqual(true, cancelJob.Cancelled, "async cancel marks the job")
AssertEqual(true, cancelJob.HandlesClosed, "cancelled async job closes handles")
cancelDeadline := A_TickCount + 3000
while (ProcessExist(cancelJob.Pid) && A_TickCount < cancelDeadline)
    Sleep 50
AssertEqual(0, ProcessExist(cancelJob.Pid), "cancelled async job terminates the child process tree")

; --- 乱序完成：快任务先完成，gate 只允许最新请求落到面板 ---
slowJob := ProcessNoWindow.StartAsync("cmd.exe /c ping 127.0.0.1 -n 4 >nul", "", 10000)
fastJob := ProcessNoWindow.StartAsync("cmd.exe /c ping 127.0.0.1 -n 1 >nul", "", 10000)
completionOrder := []
fastSeen := false
slowSeen := false
orderDeadline := A_TickCount + 8000
while ((!slowJob.Done || !fastJob.Done) && A_TickCount < orderDeadline) {
    slowJob.Poll()
    fastJob.Poll()
    if (fastJob.Done && !fastSeen) {
        completionOrder.Push("fast")
        fastSeen := true
    }
    if (slowJob.Done && !slowSeen) {
        completionOrder.Push("slow")
        slowSeen := true
    }
    Sleep 25
}
AssertEqual("fast->slow", EventSequence(completionOrder), "async completions are observed in finish order")
AssertEqual(true, slowJob.Done && fastJob.Done, "both async ordering jobs completed")
if (!slowJob.Done)
    slowJob.Dispose()
if (!fastJob.Done)
    fastJob.Dispose()

requestGate := TranslationRequestGate()
requestOne := requestGate.Begin()
requestTwo := requestGate.Begin()
AssertEqual("discard-stale", TranslationCompletionPolicy.Decide(requestGate, requestOne, "exited", false, true, true), "stale request is discarded after a new trigger")
AssertEqual("apply", TranslationCompletionPolicy.Decide(requestGate, requestTwo, "exited", false, true, true), "latest request fills the panel")
AssertEqual("discard-dismissed", TranslationCompletionPolicy.Decide(requestGate, requestTwo, "exited", false, true, false), "user-closed panel discards the late result")
AssertEqual("timeout", TranslationCompletionPolicy.Decide(requestGate, requestTwo, "timedout", false, true, false), "timed out request maps to timeout")
AssertEqual("error", TranslationCompletionPolicy.Decide(requestGate, requestTwo, "error", false, true, true), "failed request maps to error")
AssertEqual("apply-fallback", TranslationCompletionPolicy.Decide(requestGate, requestTwo, "exited", false, false, false), "missing panel falls back to a popup")
AssertEqual("discard", requestGate.Complete(requestOne), "old request cannot complete the gate")
AssertEqual("apply", requestGate.Complete(requestTwo), "current request completes the gate once")
AssertEqual("discard", requestGate.Complete(requestTwo), "duplicate completion is discarded")
AssertEqual("文本过长（12 字符，上限 10）", TranslateSelectedText.MessageForError("too_long", "", "12", "10"), "too_long message includes both lengths")
AssertEqual("文本过长（12 字符，上限 10）", TranslateSelectedText.MessageForError("too_long", "文本过长（上限 10 字符）", "12", "10"), "too_long UI keeps the actual text length")
AssertEqual("翻译超时", TranslateSelectedText.MessageForError("timeout", "", "", ""), "timeout has a stable user message")
AssertEqual("翻译配置错误", TranslateSelectedText.MessageForError("config", "", "", ""), "config errors are not reported as network failures")
AssertEqual("自定义错误", TranslateSelectedText.MessageForError("auth", "自定义错误"), "explicit provider message wins")
AssertEqual("A`nB`nengine=google", TranslateSelectedText.ParseField("status=ok`ntext=A`nB`nengine=google", "text"), "text keeps the remaining protocol payload")

; 实例标记哈希必须与 PowerShell 侧 Get-ToolboxInstanceHash 完全一致。
AssertEqual("811c9dc5", ToolboxInstance.Hash(""), "instance hash FNV empty")
AssertEqual("e40c292c", ToolboxInstance.Hash("a"), "instance hash FNV a")
AssertEqual("e40c292c", ToolboxInstance.Hash("A"), "instance hash lower-cases input")
AssertEqual("1a47e90b", ToolboxInstance.Hash("abc"), "instance hash FNV abc")
AssertEqual(ToolboxInstance.Hash("C:\Repo\"), ToolboxInstance.Hash("c:\repo"), "instance hash trims slash and case")
AssertEqual(true, InStr(ToolboxInstance.MutexName("C:\Repo"), "Local\Lat3ncyToolboxInstance-") = 1, "instance mutex name stays namespaced")
markerTestRepo := A_Temp "\lat3ncy-marker-test-" A_TickCount "-" Random(1000, 9999)
markerHandle := ToolboxInstance.Init(markerTestRepo)
AssertEqual(true, markerHandle != 0, "instance marker creates a named mutex")
openedMarker := DllCall("OpenMutexW", "UInt", 0x00100000, "Int", 0, "WStr", ToolboxInstance.MutexName(markerTestRepo), "Ptr")
AssertEqual(true, openedMarker != 0, "instance marker mutex is openable by name")
if openedMarker
    DllCall("CloseHandle", "Ptr", openedMarker)

; --- 翻译模块实际 Poll() 入口：完成 / 超时 / 取消 / 用户关面板 ---
pollDir := A_Temp "\lat3ncy-translate-poll-" A_TickCount "-" Random(1000, 9999)
DirCreate pollDir
try {
    ; 完成：定时器必须先 Poll() 子进程，再读结果并填面板。
    completionGate := TranslationRequestGate()
    completionId := completionGate.Begin()
    completionJob := FakeTranslationJob("exited", true)
    completionOut := pollDir "\ok.txt"
    FileAppend "status=ok`ndirection=en-zh`nengine=google_gtx`ncached=0`ntext=translated-result`n", completionOut, "UTF-8"
    completionTask := {id: completionId, job: completionJob, inputFile: "", outputFile: completionOut, panelOpened: true, dismissed: false}
    completionHooks := NewTranslationHooks()
    completionSaved := PrepareTranslationPollState(completionGate, completionTask)
    try {
        TranslateSelectedText.Hooks := completionHooks
        TranslateSelectedText.Poll()
        AssertEqual(1, completionJob.PollCount, "translate Poll drives job.Poll")
        AssertEqual(true, completionJob.Done, "translate Poll observes job completion")
        AssertEqual("translated-result", PollHookCaptured.result, "translate Poll applies the completed result")
        AssertEqual(0, TranslateSelectedText.Tasks.Length, "completed translation task is removed")
        AssertEqual("", TranslateSelectedText.CurrentTask, "completed translation clears the current task")
        AssertEqual(false, FileExist(completionOut) != "", "completed translation deletes the output file")
    } finally {
        RestoreTranslationPollState(completionSaved)
    }

    ; 超时：同一个真实入口必须把 timedout 映射成用户提示并关面板。
    timeoutGate := TranslationRequestGate()
    timeoutId := timeoutGate.Begin()
    timeoutJob := FakeTranslationJob("timedout", true)
    timeoutTask := {id: timeoutId, job: timeoutJob, inputFile: "", outputFile: "", panelOpened: true, dismissed: false}
    timeoutHooks := NewTranslationHooks()
    timeoutSaved := PrepareTranslationPollState(timeoutGate, timeoutTask)
    try {
        TranslateSelectedText.Hooks := timeoutHooks
        TranslateSelectedText.Poll()
        AssertEqual(1, timeoutJob.PollCount, "translate Poll polls a timed out job")
        AssertEqual("翻译超时", PollHookCaptured.error, "translate Poll reports timeout")
        AssertEqual(1, PollHookCaptured.close, "translate Poll closes the panel on timeout")
        AssertEqual(0, TranslateSelectedText.Tasks.Length, "timed out translation task is removed")
    } finally {
        RestoreTranslationPollState(timeoutSaved)
    }

    ; 取消：新请求 CancelCurrent() 后，旧任务仍要被 Poll 推进并清理。
    cancelGate := TranslationRequestGate()
    cancelId := cancelGate.Begin()
    cancelJob := FakeTranslationJob("exited", false)
    cancelTask := {id: cancelId, job: cancelJob, inputFile: "", outputFile: "", panelOpened: false, dismissed: false}
    cancelHooks := NewTranslationHooks()
    cancelSaved := PrepareTranslationPollState(cancelGate, cancelTask)
    try {
        TranslateSelectedText.Hooks := cancelHooks
        TranslateSelectedText.Poll()
        AssertEqual(1, cancelJob.PollCount, "running translation job is polled before cancellation")
        AssertEqual(1, TranslateSelectedText.Tasks.Length, "running translation task stays queued")
        TranslateSelectedText.CancelCurrent()
        AssertEqual(1, cancelJob.CancelCount, "CancelCurrent cancels the child job")
        TranslateSelectedText.Poll()
        AssertEqual(2, cancelJob.PollCount, "cancelled task is polled again to reap it")
        AssertEqual(0, TranslateSelectedText.Tasks.Length, "cancelled translation task is removed")
        AssertEqual("", PollHookCaptured.error, "cancelled translation does not show an error")
        AssertEqual("", PollHookCaptured.popup, "cancelled translation does not show a popup")
    } finally {
        RestoreTranslationPollState(cancelSaved)
    }

    ; 用户关面板：Poll 必须取消子进程，完成后不能再写结果。
    dismissGate := TranslationRequestGate()
    dismissId := dismissGate.Begin()
    dismissJob := FakeTranslationJob("exited", false)
    dismissTask := {id: dismissId, job: dismissJob, inputFile: "", outputFile: "", panelOpened: true, dismissed: false}
    dismissHooks := NewTranslationHooks()
    PollHookCaptured.panelOpen := false
    dismissSaved := PrepareTranslationPollState(dismissGate, dismissTask)
    try {
        TranslateSelectedText.Hooks := dismissHooks
        TranslateSelectedText.Poll()
        AssertEqual(1, dismissJob.PollCount, "dismissed request is polled before cancel")
        AssertEqual(1, dismissJob.CancelCount, "closing the panel cancels the child job")
        AssertEqual(true, dismissTask.dismissed, "closing the panel marks the task dismissed")
        TranslateSelectedText.Poll()
        AssertEqual(2, dismissJob.PollCount, "dismissed job is polled again to reap it")
        AssertEqual(0, TranslateSelectedText.Tasks.Length, "dismissed translation task is removed")
        AssertEqual("", PollHookCaptured.result, "dismissed translation does not write a result")
        AssertEqual("", PollHookCaptured.error, "dismissed translation does not show an error")
    } finally {
        RestoreTranslationPollState(dismissSaved)
    }

    ; 真实子进程：cmd 已退出但 Job.Done 仍为 false，必须由翻译模块 Poll() 推进。
    realOut := pollDir "\real.txt"
    FileAppend "status=ok`ndirection=en-zh`nengine=google_gtx`ncached=0`ntext=real-poll-result`n", realOut, "UTF-8"
    realJob := ProcessNoWindow.StartAsync("cmd.exe /c exit 0", "", 10000)
    realGate := TranslationRequestGate()
    realId := realGate.Begin()
    realTask := {id: realId, job: realJob, inputFile: "", outputFile: realOut, panelOpened: true, dismissed: false}
    realHooks := NewTranslationHooks()
    realSaved := PrepareTranslationPollState(realGate, realTask)
    try {
        realDeadline := A_TickCount + 3000
        while (ProcessExist(realJob.Pid) && A_TickCount < realDeadline)
            Sleep 20
        AssertEqual(0, ProcessExist(realJob.Pid), "real translation child has exited")
        AssertEqual(false, realJob.Done, "real child exit is invisible before Job.Poll")
        TranslateSelectedText.Hooks := realHooks
        realDeadline := A_TickCount + 5000
        while (TranslateSelectedText.Tasks.Length > 0 && A_TickCount < realDeadline) {
            TranslateSelectedText.Poll()
            Sleep 30
        }
        AssertEqual(true, realJob.Done, "translate Poll advances a real child job to Done")
        AssertEqual("real-poll-result", PollHookCaptured.result, "translate Poll applies a real exited job result")
        AssertEqual(0, TranslateSelectedText.Tasks.Length, "real completed task is removed")
    } finally {
        RestoreTranslationPollState(realSaved)
        if (!realJob.Done)
            realJob.Dispose()
    }

    ; 真实超时：timedout 也必须经过模块 Poll() 才终止并弹提示。
    realTimeoutJob := ProcessNoWindow.StartAsync("cmd.exe /c ping 127.0.0.1 -n 8 >nul", "", 300)
    realTimeoutGate := TranslationRequestGate()
    realTimeoutId := realTimeoutGate.Begin()
    realTimeoutTask := {id: realTimeoutId, job: realTimeoutJob, inputFile: "", outputFile: "", panelOpened: true, dismissed: false}
    realTimeoutHooks := NewTranslationHooks()
    realTimeoutSaved := PrepareTranslationPollState(realTimeoutGate, realTimeoutTask)
    try {
        Sleep 500
        AssertEqual(false, realTimeoutJob.Done, "real timeout job is not done before Poll")
        TranslateSelectedText.Hooks := realTimeoutHooks
        realTimeoutDeadline := A_TickCount + 8000
        while (TranslateSelectedText.Tasks.Length > 0 && A_TickCount < realTimeoutDeadline) {
            TranslateSelectedText.Poll()
            Sleep 30
        }
        AssertEqual("timedout", realTimeoutJob.Status, "real timeout is reported by the module poll")
        AssertEqual(true, realTimeoutJob.HandlesClosed, "real timeout closes the job handles")
        AssertEqual("翻译超时", PollHookCaptured.error, "real timeout shows the timeout message")
        AssertEqual(0, TranslateSelectedText.Tasks.Length, "real timed out task is removed")
    } finally {
        RestoreTranslationPollState(realTimeoutSaved)
        if (!realTimeoutJob.Done)
            realTimeoutJob.Dispose()
    }
} finally {
    DirDelete pollDir, true
}

AssertContains(audioSwitcherSource, "ProcessNoWindow.StartAsync(", "audio switcher starts the slow exe without blocking the hotkey thread")
AssertNotContains(audioSwitcherSource, "ProcessNoWindow.RunWait(", "audio switcher no longer synchronously waits on the exe")
AssertEqual(true, HasMethod(AudioSwitcher, "Poll"), "audio switcher completes through a timer poll")
AssertEqual('"C:\Tools\audio.exe" --toggle', AudioSwitcher.BuildToggleCommand("C:\Tools\audio.exe"), "audio switcher command stays quoted")
AssertEqual("SWITCHED", AudioSwitcher.ParseProtocol("SWITCHED|G27Q2").status, "audio switcher parses protocol status")
AssertEqual("G27Q2", AudioSwitcher.ParseProtocol("SWITCHED|G27Q2").detail, "audio switcher parses protocol detail")
AssertContains(audioSwitcherSource, "ChildTimeoutMs := 48000", "audio switcher parent timeout covers slow A2DP renegotiation")
AssertContains(audioSwitcherSource, "正在唤醒耳机", "audio switcher shows a slow-path HUD while waking the headset")
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
; Finish() 丢弃未完成任务时必须 Dispose：否则 hProcess/hJob 泄漏，且 KILL_ON_JOB_CLOSE 不触发。
leakJob := FakeTranslationJob()
AudioSwitcher.Job := leakJob
AudioSwitcher.Task := ""
AudioSwitcher.Busy := true
AudioSwitcher.Finish()
AssertEqual(true, leakJob.HandlesClosed, "audio switcher disposes an unfinished job instead of leaking handles")
AssertEqual("", AudioSwitcher.Job, "audio switcher clears the job reference on finish")
AssertEqual(false, AudioSwitcher.Busy, "audio switcher releases the busy flag on finish")
audioSwitcherCs := FileRead(A_ScriptDir "\..\..\tools\audio-switcher\AudioSwitcher.cs", "UTF-8")
audioSwitcherCfg := FileRead(A_ScriptDir "\..\..\tools\audio-switcher\config.toml", "UTF-8")
AssertContains(audioSwitcherCs, "TogglePreferredOutputs()", "audio switcher toggle uses preferred G27Q2/AirPods pair")
AssertContains(audioSwitcherCs, "IsPreferredHeadset", "audio switcher prefers AirPods stereo")
AssertContains(audioSwitcherCs, "Hands-Free", "audio switcher excludes Hands-Free endpoints")
AssertContains(audioSwitcherCs, "BluetoothSetServiceState", "audio switcher can enable AirPods A2DP")
AssertContains(audioSwitcherCs, "BluetoothGetDeviceInfo", "audio switcher refreshes device info before enabling A2DP")
AssertContains(audioSwitcherCs, "BluetoothServiceEnable", "audio switcher only enables Bluetooth audio sink")
AssertContains(audioSwitcherCs, "TryRecoverA2dpLink", "audio switcher can recover a stuck A2DP link")
AssertContains(audioSwitcherCs, "BluetoothServiceDisable", "audio switcher uses A2DP disable only inside stuck-link recovery")
AssertContains(audioSwitcherCs, "recover A2DP disable", "audio switcher re-negotiates A2DP disable/enable in recovery")
AssertContains(audioSwitcherCs, "recover skip not-paired", "audio switcher never bounces A2DP for an unpaired headset")
AssertNotContains(audioSwitcherCs, "BluetoothRemoveDevice", "audio switcher never unpairs the headset")
AssertContains(audioSwitcherCs, "PnpFallbackEnabled = false", "audio switcher disables PNP fallback by default")
AssertContains(audioSwitcherCs, "skip Pnp fallback", "audio switcher can skip Enable-PnpDevice")
AssertContains(audioSwitcherCs, "PreferredHeadsetBluetoothConnected()", "audio switcher still inspects Bluetooth connected state")
AssertContains(audioSwitcherCs, "HeadsetConnectAttempt", "audio switcher separates link success from Bluetooth connected")
AssertContains(audioSwitcherCs, "FinishHeadsetConnect(", "audio switcher classifies headset connect failures")
AssertContains(audioSwitcherCs, "LinkActionSucceeded", "audio switcher waits the full budget after a real link action")
AssertContains(audioSwitcherCs, "StuckWaitMs", "audio switcher waits before declaring stereo not ready")
AssertContains(audioSwitcherCs, "ERROR|蓝牙已连但立体声未就绪", "audio switcher reports stereo-not-ready after wait and recovery")
AssertContains(audioSwitcherCs, "ERROR|连接超时", "audio switcher reports wait timeout separately")
AssertContains(audioSwitcherCs, "ERROR|耳机未取出或不在附近", "audio switcher reports remembered-but-disconnected headset")
AssertContains(audioSwitcherCs, "ERROR|设备节点不存在", "audio switcher maps missing PnP node separately")
AssertContains(audioSwitcherCs, "ERROR|耳机未激活", "audio switcher refuses SetDefault on non-ACTIVE endpoints")
AssertContains(audioSwitcherCs, "--debug-dump", "audio switcher exposes read-only debug dump")
AssertContains(audioSwitcherCs, "--recover", "audio switcher exposes manual A2DP recovery")
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
; 失败透传契约：ocr.py 把 "ERROR: <原因>" 写进 result 文件（诊断证据保留）。
AssertContains(ocrPySource, 'write_result(result_file, f"ERROR: {error_message}")', "ocr.py writes ERROR: line to result file on failure")
; detached 契约：Raycast host 对 runScript 有 30s IPC 硬超时（@raycast.timeout 管不到），
; 引擎冷启动可能超时 → ps1 只负责启动，绝不 WaitForExit；结果 Toast 由 ocr.py 自己弹。
AssertNotContains(screenshotOcrSource, "WaitForExit", "screenshot OCR never blocks on the Python process (Raycast 30s IPC timeout)")
AssertContains(screenshotOcrSource, "--notify-on-done", "screenshot OCR lets ocr.py raise the result toast itself")
AssertContains(ocrPySource, "notify_on_done", "ocr.py supports --notify-on-done for detached mode")
; 进程树契约：-WindowStyle 会强制 UseShellExecute=false，pythonw 继承 stdout 管道，
; Raycast 要等整棵树结束才认为脚本完成 → 30s IPC 超时。WMI 优先，普通 Start-Process
; 仅作兜底（实测 6-11s 退出，仍 < 30s），但绝不能带 -WindowStyle。
AssertContains(screenshotOcrSource, "Invoke-CimMethod", "screenshot OCR spawns pythonw detached via WMI")
AssertNotContains(screenshotOcrSource, "-WindowStyle Hidden", "screenshot OCR never spawns pythonw with inherited pipes (-WindowStyle)")
; 剪贴板序列号守护：只识别本次框选产生的新图，不吞剪贴板里的旧截图。
AssertContains(ocrPySource, "_clipboard_sequence", "ocr.py ignores stale clipboard images")
; RapidOCR 回归：专用 3.14 venv 优先于全局 pythonw（onnxruntime wheel 滞后最新 Python）。
AssertContains(screenshotOcrSource, 'ocr\.venv314\Scripts\pythonw.exe', "screenshot OCR prefers the pinned 3.14 venv for RapidOCR")
AssertContains(screenshotOcrSource, "Get-Command pythonw.exe", "screenshot OCR still falls back to global pythonw")
AssertContains(screenshotOcrSource, "$pythonExe", "screenshot OCR launches through the resolved python path")
AssertContains(ocrPySource, "if inject_screenshot:", "ocr can still inject Win+Shift+S when launched directly")
AssertEqual(true, InStr(ocrPySource, "if inject_screenshot:") < InStr(ocrPySource, "engine = load_engine()"), "ocr injects screenshot before loading RapidOCR")
restartAhkSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\restart-autohotkey.ps1", "UTF-8")
toggleRgbSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\toggle-rgb.ps1", "UTF-8")
nextWallpaperSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\next-wallpaper.ps1", "UTF-8")
AssertContains(restartAhkSource, "@raycast.mode silent", "restart AutoHotkey stays silent so Raycast closes")
AssertContains(restartAhkSource, "Show-SystemToast -Title", "restart AutoHotkey success uses system toast")
AssertContains(restartAhkSource, "IME HUD 已重载", "restart AutoHotkey reports the IME HUD reload too")
; 常驻 HUD 跑的是旧 exe，不一起结束的话新协议永远不生效。
AssertContains(restartAhkSource, "ImeHudWinUi.exe", "restart AutoHotkey also targets the resident IME HUD")
AssertContains(restartAhkSource, "function Stop-ToolboxImeHud", "restart AutoHotkey stops the resident HUD")
AssertContains(restartAhkSource, "Stop-ToolboxImeHud", "restart AutoHotkey actually calls the HUD stop")
AssertContains(restartAhkSource, "请用管理员权限重跑本脚本", "restart AutoHotkey fails loudly when the HUD cannot be stopped")
; Raycast 会把脚本的任何 stdout 当成结果弹自己的通知；生产脚本必须安静，
; 只走系统 Toast（诊断脚本是 fullOutput，单独放行）。
AssertNotContains(restartAhkSource, "Write-Host", "restart AutoHotkey writes nothing to stdout")
AssertNotContains(restartAhkSource, "Write-Output", "restart AutoHotkey does not use Write-Output either")
reloadImeHudSource := FileRead(A_ScriptDir "\..\..\tools\raycast-scripts\reload-ime-hud.ps1", "UTF-8")
AssertNotContains(reloadImeHudSource, "Write-Host", "reload IME HUD writes nothing to stdout")
AssertNotContains(reloadImeHudSource, "Write-Output", "reload IME HUD does not use Write-Output either")
AssertContains(reloadImeHudSource, "Show-SystemToast", "reload IME HUD reports through the system toast only")
AssertNotContains(restartAhkSource, "Show-ToolboxNotify", "restart AutoHotkey no longer uses shared HUD")
AssertNotContains(restartAhkSource, "Write-Output `"✓ $successText`"", "restart AutoHotkey no longer falls back to stdout HUD")
AssertContains(toggleRgbSource, "@raycast.mode silent", "toggle RGB stays silent so Raycast closes")
AssertNotContains(toggleRgbSource, 'Show-SystemToast -Title "💡 $Text"', "toggle RGB success stays silent")
AssertContains(toggleRgbSource, "RGB 灯光已关闭", "toggle RGB reports lights off")
AssertContains(toggleRgbSource, "RGB 灯光已开启", "toggle RGB reports lights on")
AssertNotContains(toggleRgbSource, "Show-ToolboxNotify", "toggle RGB no longer uses shared HUD")
AssertContains(nextWallpaperSource, "@raycast.mode silent", "next wallpaper stays silent so Raycast closes")
AssertContains(nextWallpaperSource, "lat3ncy-next-wallpaper", "next wallpaper serializes concurrent calls")
AssertContains(nextWallpaperSource, "Get-NextWallpaperImage", "next wallpaper advances the configured pool")
AssertContains(nextWallpaperSource, "Get-DesktopWallpaperPath", "next wallpaper starts from the current desktop image")
AssertContains(nextWallpaperSource, "Set-DesktopWallpaper", "next wallpaper sets the desktop image")
AssertContains(nextWallpaperSource, "Sync-LockScreenWallpaper", "next wallpaper syncs the same image to the lock screen")
AssertNotContains(nextWallpaperSource, "Show-SystemToast -Title 'Wallpaper and lock screen updated'", "next wallpaper success stays silent")
AssertContains(ocrPySource, "✓ OCR 文本已复制", "ocr.py reports the copied text through the system toast")
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
AssertContains(toastAdapterSource, "Start-ToolboxNotifyProcess -FilePath", "toast adapter reuses hidden process starter")
AssertContains(toastAdapterSource, "powershell.exe", "toast adapter launches powershell.exe through the hidden starter")
AssertContains(toastAdapterSource, "-File', `$runnerPath", "toast adapter passes the payload via a UTF-8 runner so 5.1 does not mangle non-ASCII")
AssertNotContains(toastAdapterSource, "Start-Process -FilePath `"powershell.exe`"", "toast adapter no longer uses Start-Process")
AssertEqual(false, FileExist(A_ScriptDir "\..\..\shared\notify\notify-cli.ahk") != "", "legacy notify-cli.ahk is gone")
AssertEqual(false, DirExist(A_ScriptDir "\..\..\shared\notify\dev") != "", "legacy shared/notify/dev directory is gone")
AssertEqual(false, DirExist(A_ScriptDir "\..\..\tools\dsh-remote") != "", "dsh-remote tool is gone")
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
AssertContains(themeUtilsSource, "function ConvertTo-CanonicalPath", "wallpaper selection canonicalizes paths")
AssertContains(themeUtilsSource, "function Test-SameWallpaperPath", "wallpaper selection compares canonical paths")
AssertContains(themeUtilsSource, "function Get-NextWallpaperImage", "theme can pick the next wallpaper from the pool")
AssertContains(themeUtilsSource, "Get-NextWallpaperImage -Config $Config -CurrentPath (Get-DesktopWallpaperPath) -Mode $Mode", "light and dark advance the same ordered pool")
AssertNotContains(themeUtilsSource, "DayOfYear % $count", "wallpaper selection no longer uses the date index")
AssertContains(themeUtilsSource, "function Set-WindowsCursorScheme", "theme can switch cursor schemes with color mode")
AssertContains(themeUtilsSource, "function Disable-AccessibilityCursorOverlay", "cursor scheme clears the Accessibility colored pointer overlay")
AssertContains(themeUtilsSource, "CursorColor", "cursor overlay uses the Accessibility CursorColor value")
AssertContains(themeUtilsSource, "SPI_SETCURSORS", "cursor switch refreshes pointers via SystemParametersInfo")
AssertContains(themeUtilsSource, "SetSystemCursor", "cursor switch also applies live pointers via SetSystemCursor")
AssertContains(themeUtilsSource, "function Sync-ThemeFileCursors", "cursor switch writes the live .theme so unlock cannot restore Windows 11 pointers")
AssertContains(themeUtilsSource, "MSFT_TaskSessionStateChangeTrigger", "cursor restore uses a session-state scheduled task")
AssertContains(themeUtilsSource, "SessionUnlock", "cursor restore fires on unlock")
AssertContains(themeCursorsSource, "Set-WindowsCursorScheme -Mode $desired", "unlock restore reapplies the current cursor scheme")
AssertContains(themeCursorsSource, "$offsets = @(0, 1.5, 4)", "unlock restore retries after Windows 11 delayed default pointers")
AssertContains(themeInstallSource, "Theme-Apply-Cursors", "installer registers the unlock cursor task")
AssertContains(themeUninstallSource, "Theme-Apply-Cursors", "uninstaller removes the unlock cursor task")
AssertContains(themeUpdateSource, "Theme-Apply-Cursors", "schedule updater keeps the unlock cursor task")
AssertContains(themeUtilsSource, "HKCU:\Control Panel\Cursors", "cursor switch writes the current-user cursor key")
AssertContains(themeUtilsSource, "resources\cursors\", "cursor switch defaults to repo resources/cursors")
AssertContains(themeLightSource, "Start-ThemeTail -Mode 'light'", "light theme dispatches the independent tail process")
AssertContains(themeDarkSource, "Start-ThemeTail -Mode 'dark'", "dark theme dispatches the independent tail process")
AssertContains(themeTailSource, "Set-WindowsCursorScheme -Mode $Mode", "tail applies the cursor scheme for the new mode")
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
AssertContains(themeConfigSource, "[keyboard_backlight]", "theme config exposes keyboard_backlight section")
AssertContains(themeUtilsSource, "function Set-ThinkPadKeyboardBacklight", "theme utils defines keyboard backlight setter")
AssertContains(themeUtilsSource, "function Test-ThinkPadCapability", "theme utils defines ThinkPad capability test")
AssertContains(themeTailSource, "Set-ThinkPadKeyboardBacklight", "tail aligns the keyboard backlight")
AssertContains(themeTailSource, "Sync-LockScreenWallpaper", "tail syncs the lock screen wallpaper")
AssertContains(themeApplySource, "Set-ThinkPadKeyboardBacklight -Mode `$desired", "theme apply aligns backlight on logon")
AssertContains(themeUpdateSource, "Repair-ThemeScheduledTaskWindow", "theme schedule updater keeps hidden actions")
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
AssertContains(pythonSource, "class ToolboxPython", "shared python helper defines ToolboxPython")
AssertContains(mainSource, "#Include ..\shared\python.ahk", "main loads shared python helper once")
AssertContains(mainSource, "#Include ..\shared\notify\translation-panel.ahk", "main loads WinUI translation panel client")
AssertNotContains(mainSource, "#Include ..\shared\notify\anchor.ahk", "main does not re-include caret anchor")
AssertContains(mainSource, "#Include ..\shared\notify\ime-hud.ahk", "main loads ImeHud client")
AssertNotContains(speakSource, "python.ahk", "speak does not include python helper")
AssertNotContains(translateSource, "python.ahk", "translate does not include python helper")
AssertContains(speakSource, "ToolboxPython.ResolveW()", "speak resolves python via shared helper")
AssertContains(translateSource, "ToolboxPython.ResolveW()", "translate resolves python via shared helper")
AssertNotContains(speakSource, "Shortcuts.", "speak is independent from shortcut config")
AssertContains(speakSource, "Caps+S", "speak log uses Caps+S")
AssertNotContains(speakSource, "Ctrl+Alt+S", "speak log no longer mentions Ctrl+Alt+S")
AssertContains(speakSource, "18000", "speak headset warmup timeout exceeds C# 12s wait")
AssertContains(speakSource, "ProcessNoWindow.StartAsync(", "speak warmup no longer blocks the hotkey thread")
AssertNotContains(speakSource, "ProcessNoWindow.RunWait(", "speak warmup has no synchronous wait")
AssertEqual(true, HasMethod(SpeakSelectedText, "PollWarmup"), "speak completes headset warmup through a timer poll")
AssertNotContains(speakSource, "ShortText(raw", "speak never logs the selected text")
AssertContains(speakSource, "lat3ncy-tts-in-", "speak uses unique TTS input files")
AssertNotContains(speakSource, "lat3ncy-tts-input.txt", "speak no longer reuses a fixed TTS input file")
AssertContains(speakSource, "WatchPid", "speak watches the TTS pid to delete temp input")
AssertContains(speakSource, 'ClipboardAll()', "speak captures clipboard safely")
AssertContains(speakSource, 'finally', "speak restores clipboard in finally block")
AssertNotContains(speakSource, '"close all"', "speak cancellation owns its job instead of closing unrelated audio")
AssertNotContains(translateSource, "Shortcuts.", "translate is independent from shortcut config")
AssertContains(translateSource, "ClipboardAll()", "translate captures clipboard safely")
AssertContains(translateSource, "finally", "translate restores clipboard in finally block")
AssertContains(translateSource, "MouseGetPos", "translate records mouse-at-hotkey before copying selection")
AssertContains(translateSource, 'CoordMode "Mouse", "Screen"', "translate MouseGetPos uses screen pixels, not client")
AssertContains(translateSource, "TranslationPanel.OpenText(", "translate opens WinUI panel with explicit source")
AssertContains(translateSource, "TranslationPanel.SetResult(", "translate success fills explicit RESULT")
AssertContains(translateSource, "TranslationPanel.Close()", "translate failure closes the WinUI panel")
AssertNotContains(translateSource, "RunWait(", "translate no longer blocks the hotkey thread")
AssertContains(translateSource, "Notify.Popup(text, 8000)", "translate uses a popup only when the panel is unavailable")
AssertEqual(true, HasMethod(TranslateSelectedText, "Poll"), "translate completes through a timer poll")
AssertEqual(true, HasMethod(TranslateSelectedText, "CancelCurrent"), "translate can cancel the previous request")
AssertContains(translateSource, 'case "auth":', "translate maps cloud auth to a dedicated failure")
AssertContains(translateSource, "翻译密钥无效", "translate auth failure has a stable toast fallback")
AssertContains(translateSource, 'Notify.Error("×", message)', "translate failures use system toast, not HUD")
AssertContains(translateSource, "lat3ncy-translate-in-", "translate uses unique input files")
AssertContains(translateSource, "ProcessNoWindow.StartAsync(", "translate starts the helper without a console or blocking wait")
AssertContains(translateSource, "14000", "translate parent timeout covers tencent plus fallbacks")
panelOpenProbe := TranslationPanel.IsOpen()
AssertEqual(true, panelOpenProbe = 0 || panelOpenProbe = 1, "translation panel visibility probe returns 0/1")
translatePySource := FileRead(A_ScriptDir "\\..\\..\\tools\\translate\\translate.py", "UTF-8")
translateCfgSource := FileRead(A_ScriptDir "\\..\\..\\tools\\translate\\config.toml", "UTF-8")
AssertContains(translatePySource, "def translate_tencent(", "translate helper implements Tencent TMT")
AssertContains(translatePySource, "TextTranslate", "translate uses Tencent TextTranslate")
AssertContains(translatePySource, "TENCENTCLOUD_SECRET_ID", "translate reads Tencent env keys")
AssertContains(translatePySource, "read_user_env", "translate can read HKCU user env without restarting AHK")
AssertContains(translatePySource, "class AuthError", "cloud auth errors are typed")
AssertContains(translatePySource, '"auth",', "cloud auth writes auth status for AHK")
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
locatorSource := FileRead(A_ScriptDir "\..\..\shared\notify\AnchorLocator.cs", "UTF-8")
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
AssertContains(imeHudClientSource, "User32\FindWindowW", "IME HUD client finds the hidden resident window")
; WinExist 会跳过隐藏窗口，但 Show() 取前台窗口时用它是对的：
; 只约束 FindWindow 查找器本身不能走 WinExist。
findWindowStart := InStr(imeHudClientSource, "static FindWindow(")
AssertEqual(true, findWindowStart > 0, "IME HUD client has a FindWindow lookup")
AssertNotContains(SubStr(imeHudClientSource, findWindowStart), "WinExist(", "IME HUD window lookup does not skip the hidden resident window")
AssertContains(imeHudClientSource, "MessageTimeout := 600", "IME HUD COPYDATA timeout stays short")
AssertContains(rendererSource, "#Include anchor.ahk", "renderer loads caret anchor for AHK chips")
AssertContains(imeHudClientSource, "#Include anchor.ahk", "IME HUD client loads caret anchor")
AssertContains(imeHudClientSource, "InputAnchor.TryCaret(&x, &y, targetHwnd)", "IME HUD hot path tries Win32 caret first")
AssertContains(imeHudClientSource, "ProcessNoWindow.RunWait(command, outputFile, this.LocatorTimeoutMs)", "IME HUD falls back to the locator with a bounded timeout")
AssertContains(imeHudClientSource, "static ProbeLocator(", "IME HUD parses structured locator output")
AssertContains(imeHudClientSource, "static LocateAnchor(", "IME HUD resolves an anchor with an explicit source")
AssertContains(imeHudClientSource, "static LastAnchorSource", "IME HUD records the anchor source")
AssertContains(imeHudClientSource, "static LastAnchorReal", "IME HUD records whether the anchor is a real caret")
AssertContains(imeHudClientSource, "static FollowEnabled", "IME HUD follow can be switched off")
AssertContains(imeHudClientSource, "static FollowAnchor(", "IME HUD can follow the caret while the chip is visible")
AssertContains(imeHudClientSource, "static CaretHelperPath()", "IME HUD resolves the UIA caret helper")
AssertContains(imeHudClientSource, "static StartCaretHelper(", "IME HUD can read the caret via the PowerShell helper")
AssertContains(imeHudClientSource, "caret-uia.ps1", "IME HUD helper name stays caret-uia.ps1")
AssertContains(imeHudClientSource, "ProcessNoWindow.Run(command, false, outputFile)", "caret helper launch stays non-blocking")
AssertContains(imeHudClientSource, "CARET", "follow accepts the helper CARET lines")
AssertContains(imeHudClientSource, "ProcessNoWindow.Run(command, false, outputFile)", "follow watcher does not block the AHK hot path")
AssertNotContains(imeHudClientSource, "InputAnchor.Get(&x, &y, targetHwnd)", "IME HUD no longer silently degrades through InputAnchor.Get")
AssertEqual("STATE|CN|820|642|0|0", ImeHud.BuildStateCommand("CN", 820, 642, 0, 0), "STATE without source stays backward compatible")
AssertEqual("STATE|CN|820|642|0|0||text-caret", ImeHud.BuildStateCommand("CN", 820, 642, 0, 0, 0, "text-caret"), "STATE keeps a source even without a target hwnd")
AssertEqual("STATE|CN|10|20|0|0|12345|text-caret", ImeHud.BuildStateCommand("CN", 10, 20, 0, 0, 12345, "text-caret"), "STATE carries the anchor source")
AssertEqual("STATE|EN|10|20|0|0|12345|target-window-bottom", ImeHud.BuildStateCommand("EN", 10, 20, 0, 0, 12345, "target-window-bottom"), "STATE keeps degraded sources visible")
AssertEqual("unknown", ImeHud.NormalizeSource(""), "empty anchor source is unknown")
AssertEqual("text-caret", ImeHud.NormalizeSource("text-caret"), "anchor source keeps safe characters")
AssertEqual("win32caret", ImeHud.NormalizeSource("win32|caret"), "anchor source drops protocol separators")
AssertEqual(true, InputAnchor.IsRealCaretSource("text-caret"), "text-caret counts as a real caret")
AssertEqual(true, InputAnchor.IsRealCaretSource("win32-caret"), "win32-caret counts as a real caret")
AssertEqual(true, InputAnchor.IsRealCaretSource("imm-caret"), "imm-caret counts as a real caret")
AssertEqual(false, InputAnchor.IsRealCaretSource("focus-bounds"), "focus-bounds is not a real caret")
AssertEqual(false, InputAnchor.IsRealCaretSource("focus-text"), "focus-text is not a real caret")
AssertEqual(false, InputAnchor.IsRealCaretSource("target-window-bottom"), "window-bottom is not a real caret")
AssertEqual(false, InputAnchor.IsRealCaretSource(""), "empty source is not a real caret")
for realSourceName in InputAnchor.RealCaretSources {
    needle := '"' realSourceName '"'
    if !InStr(locatorSource, needle) {
        AssertEqual(true, false, realSourceName " must also be a real caret source in the locator")
        break
    }
}
AssertEqual(true, true, "locator real caret source list matches anchor.ahk")
AssertContains(imeHudClientSource, "static Warm()", "IME HUD warms the resident WinUI process")
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
AssertContains(anchorSource, "NotifyPaths.LocatorExe()", "anchor resolves locator without assuming the entry directory")
AssertContains(anchorSource, "GetRootHwnd", "anchor separates control HWND from root HWND")
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
AssertContains(capsLockSource, "_imeTargetControlHwnd", "Caps snapshots the control HWND on key down")
AssertContains(capsLockSource, "GetRootHwnd", "Caps also snapshots the root HWND")
AssertContains(capsLockSource, "TapMaxMs", "Caps state machine owns short-press ceiling")
AssertContains(capsLockSource, "AbortCapsModeForChord", "Caps state machine can undo late caps-mode")
AssertContains(capsLockSource, "_exitingCaps", "Caps state machine blocks chords while exiting caps")
AssertContains(capsLockSource, "ChordImeLockoutMs", "Caps state machine owns post-chord IME lockout")
AssertContains(capsLockSource, "PersistImeAcrossWindows", "Caps can persist IME across windows")
AssertContains(capsLockSource, "RememberImeState", "Caps records last explicit IME state")
AssertContains(capsLockSource, "WatchForeground", "Caps restores IME after focus change")
AssertContains(capsLockSource, "static UseImeHud := true", "Caps can roll back to AHK HUD with one switch")
AssertContains(capsLockSource, "生产路径发送失败不再叠 AHK 芯片", "production ImeHud failure does not stack an AHK chip")
AssertContains(capsLockSource, 'this.ShowImeHud("CN", targetHwnd)', "Caps shows CN through ImeHud")
AssertContains(capsLockSource, 'this.ShowImeHud("EN", targetHwnd)', "Caps shows EN through ImeHud")
AssertContains(capsLockSource, 'this.ShowImeHud("CAPS", targetHwnd)', "Caps shows CAPS through ImeHud")
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
AssertContains(mainSource, "ImeHud.Warm()", "main warms WinUI HUD before the first CapsLock")
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
AssertContains(mainSource, "#Include features\find-mouse.ahk", "main loads shake-to-find mouse")
AssertContains(mainSource, "#Include features\thinkpad-backlight.ahk", "main loads thinkpad-backlight")
thinkpadBacklightSource := FileRead(A_ScriptDir "\..\features\thinkpad-backlight.ahk", "UTF-8")
AssertContains(thinkpadBacklightSource, "class ThinkPadBacklight", "defines ThinkPadBacklight class")
AssertContains(thinkpadBacklightSource, "IsThinkPad", "checks ThinkPad hardware")
AssertContains(thinkpadBacklightSource, "GetLastInputInfo", "uses GetLastInputInfo for session input tracking")
AssertContains(thinkpadBacklightSource, "GetCursorPos", "uses GetCursorPos to filter pure mouse movement")
AssertEqual(false, ThinkPadBacklight.IsActive, "test mode does not start backlight timer")
findMouseSource := FileRead(A_ScriptDir "\..\features\find-mouse.ahk", "UTF-8")
AssertContains(findMouseSource, "GetCursorPos", "shake-to-find polls cursor position")
AssertContains(findMouseSource, "SetTimer(this.StartCallback, -1)", "shake-to-find starts after the script is idle")
AssertContains(findMouseSource, "RequestEnlarge", "shake-to-find defers sizing out of the poll")
AssertContains(findMouseSource, "cursor-size.cs", "shake-to-find delegates sizing to a DPI-aware helper")
AssertContains(findMouseSource, "cursor-size.ps1", "shake-to-find documents the retired PowerShell helper")
AssertContains(findMouseSource, "ProcessNoWindow.Run", "shake-to-find launches the helper without a console")
AssertContains(findMouseSource, "WSAStartup", "shake-to-find initializes Winsock before connecting")
AssertNotContains(findMouseSource, "DllCall(`"SetSystemCursor`"", "shake-to-find does not resize cursors from the DPI-unaware host")
AssertNotContains(findMouseSource, "RegWrite", "shake-to-find does not persist cursor settings")
AssertContains(findMouseSource, "LegMaxMs", "shake-to-find limits how long one leg may take")
AssertContains(findMouseSource, "IdleResetMs", "shake-to-find drops stale travel after a pause")
AssertContains(findMouseSource, "MaxSpanPx", "shake-to-find caps the arena of one streak")
AssertContains(findMouseSource, "GetAsyncKeyState", "shake-to-find suppresses detection while a mouse button is held")
AssertContains(findMouseSource, "static IsMouseButtonDown", "shake-to-find checks button state outside the sample loop")
AssertContains(findMouseSource, "MinStreakSpeedPxPerMs", "shake-to-find rejects slow aim corrections over the whole gesture")
AssertContains(findMouseSource, "MinSpanPx", "shake-to-find rejects small-amplitude jitter")
AssertContains(findMouseSource, "MaxStreakMs", "shake-to-find bounds the whole gesture duration")
AssertContains(findMouseSource, "WriteTriggerTrace", "shake-to-find records each trigger geometry")
AssertContains(findMouseSource, "LastButtonUpTick", "shake-to-find notes when the last click ended")
AssertContains(findMouseSource, "ApplySocketTimeout", "shake-to-find bounds helper socket waits")
AssertContains(findMouseSource, "ReapOrphanSizer", "shake-to-find reclaims an orphaned helper")
AssertContains(findMouseSource, "GetCurrentProcessId", "shake-to-find hands its pid to the helper")
AssertContains(findMouseSource, "EnsureParentMutex", "shake-to-find owns a parent liveness mutex")
AssertContains(findMouseSource, "CreateMutexW", "shake-to-find creates the mutex as its owner")
cursorSizeSource := FileRead(A_ScriptDir "\..\features\find-mouse\cursor-size.cs", "UTF-8")
AssertContains(cursorSizeSource, "GetProcessById", "cursor helper watches its parent process")
AssertContains(cursorSizeSource, "StartTime", "cursor helper detects a recycled parent pid")
AssertContains(cursorSizeSource, "SPI_SETCURSORS", "cursor helper reloads the scheme when a restore fails")
AssertContains(cursorSizeSource, "ReceiveTimeout", "cursor helper survives a dead client")
AssertContains(cursorSizeSource, "OpenMutex", "cursor helper watches the parent mutex")
AssertEqual(3, FindMouse.ReverseCount, "shake-to-find needs three reversals")
AssertEqual(40, FindMouse.MinDistance, "shake-to-find needs a real leg length")
AssertEqual(320, FindMouse.LegMaxMs, "shake-to-find requires a fast leg")
AssertEqual(500, FindMouse.IdleResetMs, "shake-to-find treats a pause as the end of a gesture")
AssertEqual(400, FindMouse.MaxIntervalMs, "shake-to-find allows a natural shake cadence")
AssertEqual(600, FindMouse.MaxSpanPx, "shake-to-find rejects cross-screen travel")
AssertEqual(100, FindMouse.MinSpanPx, "shake-to-find requires a real shake amplitude")
AssertEqual(8, FindMouse.AxisMinPx, "shake-to-find classifies the axis from the whole leg")
AssertEqual(0.75, FindMouse.MaxNetRatio, "shake-to-find tolerates drifting toward the target")
AssertEqual(0.5, FindMouse.MinStreakSpeedPxPerMs, "shake-to-find requires the whole gesture to be fast")
AssertEqual(1000, FindMouse.MaxStreakMs, "shake-to-find must finish the shake quickly")
AssertEqual(false, FindMouse.Hook != 0, "test mode does not install the mouse hook")
savedFindMouse := {
    enabled: FindMouse.Enabled,
    hasAnchor: FindMouse.HasAnchor,
    lastX: FindMouse.LastX,
    lastY: FindMouse.LastY,
    lastMoveTick: FindMouse.LastMoveTick,
    legAxis: FindMouse.LegAxis,
    legSign: FindMouse.LegSign,
    legStartX: FindMouse.LegStartX,
    legStartY: FindMouse.LegStartY,
    legStartTick: FindMouse.LegStartTick,
    legTravel: FindMouse.LegTravel,
    legPeakX: FindMouse.LegPeakX,
    legPeakY: FindMouse.LegPeakY,
    streak: FindMouse.ReverseStreak,
    lastReverseTick: FindMouse.LastReverseTick,
    streakStartX: FindMouse.StreakStartX,
    streakStartY: FindMouse.StreakStartY,
    streakTravel: FindMouse.StreakTravel,
    streakMinX: FindMouse.StreakMinX,
    streakMinY: FindMouse.StreakMinY,
    streakMaxX: FindMouse.StreakMaxX,
    streakMaxY: FindMouse.StreakMaxY
}
try {
    FindMouse.Enabled := false

    ; 真摇动：带垂直漂移的水平甩动，两个来回必须触发。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 1000), "shake starts a fresh sample")
    AssertEqual(false, FindMouse.Observe(110, 5, 1040), "first leg opens with a diagonal drift")
    AssertEqual(false, FindMouse.Observe(0, 9, 1080), "the first reversal counts")
    AssertEqual(false, FindMouse.Observe(110, 13, 1120), "the second leg opens")
    AssertEqual(false, FindMouse.Observe(0, 17, 1160), "the second reversal counts")
    AssertEqual(2, FindMouse.ReverseStreak, "two reversals are still below the threshold")
    AssertEqual(false, FindMouse.Observe(110, 21, 1200), "the third leg opens")
    AssertEqual(true, FindMouse.Observe(0, 25, 1240), "a deliberate two-cycle shake enlarges the pointer")
    AssertEqual(0, FindMouse.ReverseStreak, "the trigger resets the streak for the next gesture")

    ; 随意一晃：先移到 400px 外，再在旁边抖两下。净位移远大于总行程，不能触发。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 2000), "travel sample starts clean")
    AssertEqual(false, FindMouse.Observe(300, 0, 2040), "a cross-window move opens a long leg")
    AssertEqual(false, FindMouse.Observe(276, 0, 2080), "the first correction counts")
    AssertEqual(false, FindMouse.Observe(380, 0, 2120), "the second correction leg opens")
    AssertEqual(false, FindMouse.Observe(356, 0, 2160), "the second correction counts")
    AssertEqual(false, FindMouse.Observe(460, 0, 2200), "the third correction leg opens")
    AssertEqual(false, FindMouse.Observe(436, 0, 2240), "a move plus jitter must not enlarge")
    AssertEqual(0, FindMouse.ReverseStreak, "the net-displacement guard clears the streak")

    ; 慢速来回是日常瞄准修正，不是甩动。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 3000), "slow sample starts clean")
    AssertEqual(false, FindMouse.Observe(40, 0, 3050), "slow leg opens")
    AssertEqual(false, FindMouse.Observe(-10, 0, 3700), "a slow leg does not reverse")
    AssertEqual(0, FindMouse.ReverseStreak, "a slow leg leaves the streak empty")

    ; 幅度不够的抖动不算。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 4000), "nudge sample starts clean")
    AssertEqual(false, FindMouse.Observe(10, 0, 4050), "a 10px leg is too short")
    AssertEqual(false, FindMouse.Observe(0, 0, 4100), "a 10px return is too short")
    AssertEqual(0, FindMouse.ReverseStreak, "short nudges never build a streak")

    ; 中途停顿会清掉已攒的连击。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 5000), "pause sample starts clean")
    AssertEqual(false, FindMouse.Observe(40, 0, 5040), "a first fast leg opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 5700), "a pause drops the accumulated travel")
    AssertEqual(0, FindMouse.ReverseStreak, "stale travel cannot build a streak")

    ; 跨屏平移不是找指针。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 6000), "wide sample starts clean")
    AssertEqual(false, FindMouse.Observe(300, 0, 6040), "a long sweep opens a leg")
    AssertEqual(false, FindMouse.Observe(0, 0, 6080), "a sweep back reverses once")
    AssertEqual(false, FindMouse.Observe(700, 0, 6120), "cross-screen travel abandons the streak")
    AssertEqual(0, FindMouse.ReverseStreak, "a streak cannot span the whole desktop")

    ; 竖直甩动同样有效：轴不是写死的。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 7000), "vertical sample starts clean")
    AssertEqual(false, FindMouse.Observe(6, 120, 7040), "vertical leg opens")
    AssertEqual(false, FindMouse.Observe(12, -6, 7080), "vertical reversal one")
    AssertEqual(false, FindMouse.Observe(18, 120, 7120), "vertical leg two opens")
    AssertEqual(false, FindMouse.Observe(24, -6, 7160), "vertical reversal two")
    AssertEqual(false, FindMouse.Observe(30, 120, 7200), "vertical leg three opens")
    AssertEqual(true, FindMouse.Observe(36, -6, 7240), "a vertical shake also triggers")

    ; 直线快摇：峰值在两次采样之间被跳过，回程首点已离峰值 20px，
    ; 60px 腿的回摆按峰值算只剩 60+20，按 0.6 折算 30px 门槛仍可满足。
    ; 峰值补偿缺失时（按足额 30px 判），这里只回摆 30px 起步会被吞掉一次反向。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 8000), "fast straight sample starts clean")
    AssertEqual(false, FindMouse.Observe(110, 0, 8032), "a fast leg opens without the far peak being sampled")
    AssertEqual(false, FindMouse.Observe(10, 2, 8064), "the return leg counts despite the skipped peak")
    AssertEqual(1, FindMouse.ReverseStreak, "peak overshoot does not swallow the first reversal")
    AssertEqual(false, FindMouse.Observe(120, 0, 8096), "the second leg opens")
    AssertEqual(false, FindMouse.Observe(20, 2, 8128), "the second reversal counts")
    AssertEqual(2, FindMouse.ReverseStreak, "two reversals survive fast straight shaking")
    AssertEqual(false, FindMouse.Observe(130, 0, 8160), "the third leg opens")
    AssertEqual(true, FindMouse.Observe(30, 2, 8192), "a fast straight shake triggers")

    ; 小幅度快速抖动（手抖/触摸板漂移/犹豫微调）：三次反向都能凑够，
    ; 但峰峰值只有 40px，必须被幅度下限拦下——这是"正常使用中变大"的回归用例。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 13000), "small jitter sample starts clean")
    AssertEqual(false, FindMouse.Observe(40, 0, 13032), "a small fast leg opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 13064), "small jitter reversal one counts")
    AssertEqual(false, FindMouse.Observe(40, 0, 13096), "small jitter leg two opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 13128), "small jitter reversal two counts")
    AssertEqual(false, FindMouse.Observe(40, 0, 13160), "small jitter leg three opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 13192), "small fast jitter must not enlarge")
    AssertEqual(0, FindMouse.ReverseStreak, "the amplitude floor clears the small jitter streak")

    ; 摇动前正常移动过 550px，不该把包围盒预算吃光。旧实现里边界从上次采样
    ; 起算，0..620 直接超窗清空连击；现在只量本次摇动的 400..620。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 9000), "pre-travel sample starts clean")
    AssertEqual(false, FindMouse.Observe(300, 0, 9040), "ordinary move toward the target")
    AssertEqual(false, FindMouse.Observe(550, 0, 9080), "the move ends where the shake begins")
    AssertEqual(false, FindMouse.Observe(520, 0, 9120), "the shake opens at the target")
    AssertEqual(false, FindMouse.Observe(450, 0, 9160), "the shake swings past the target")
    AssertEqual(false, FindMouse.Observe(400, 0, 9200), "the shake reaches its left end")
    AssertEqual(false, FindMouse.Observe(430, 0, 9240), "first reversal after a long pre-move")
    AssertEqual(false, FindMouse.Observe(500, 0, 9280), "the swing returns right")
    AssertEqual(false, FindMouse.Observe(560, 0, 9320), "the swing keeps going right")
    AssertEqual(false, FindMouse.Observe(620, 0, 9360), "the shake reaches its right end")
    AssertEqual(true, FindMouse.Observe(590, 0, 9400), "a shake after ordinary travel still enlarges")

    ; 同样的 40px 幅度，慢慢来回（窗口均速 200 px/s < 500 px/s）：每次反向
    ; 都能攒上（折返减速不再连坐），但整窗速度闸门在触发评估时拦下。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 11000), "hesitant sample starts clean")
    AssertEqual(false, FindMouse.Observe(40, 0, 11100), "a hesitant forward leg opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 11250), "a slow reversal still counts")
    AssertEqual(1, FindMouse.ReverseStreak, "the window gate has not fired yet")
    AssertEqual(false, FindMouse.Observe(40, 0, 11400), "the hesitant leg two opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 11550), "the hesitant reversal two counts")
    AssertEqual(2, FindMouse.ReverseStreak, "two slow reversals build a streak")
    AssertEqual(false, FindMouse.Observe(40, 0, 11700), "the hesitant leg three opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 11850), "a slow gesture must not enlarge")
    AssertEqual(0, FindMouse.ReverseStreak, "the window speed gate clears the slow streak")
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 12000), "fast small shake starts clean")
    AssertEqual(false, FindMouse.Observe(40, 0, 12040), "a fast forward leg opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 12080), "a fast return counts as a reversal")
    AssertEqual(1, FindMouse.ReverseStreak, "a fast 40px leg still counts")

    ; 真摇动里折返点必然减速：一条慢折返腿（150px 走了 320ms）不能把整个
    ; 连击清零——速度判据必须按整个手势窗口算，不按单腿算。
    FindMouse.ResetMotion()
    AssertEqual(false, FindMouse.Observe(0, 0, 14000), "turn-decel sample starts clean")
    AssertEqual(false, FindMouse.Observe(150, 0, 14040), "a fast outbound leg opens")
    AssertEqual(false, FindMouse.Observe(0, 0, 14360), "a slow turn-around leg completes")
    AssertEqual(1, FindMouse.ReverseStreak, "a slow turn-around leg still counts as a reversal")
    AssertEqual(false, FindMouse.Observe(150, 0, 14400), "the swing back is fast")
    AssertEqual(false, FindMouse.Observe(0, 0, 14440), "the second reversal counts")
    AssertEqual(2, FindMouse.ReverseStreak, "the streak survives a decelerated turn")
    AssertEqual(false, FindMouse.Observe(60, 0, 14480), "the third leg opens")
    AssertEqual(true, FindMouse.Observe(0, 0, 14520), "a shake with one slow turn still triggers")
} finally {
    FindMouse.Enabled := savedFindMouse.enabled
    FindMouse.HasAnchor := savedFindMouse.hasAnchor
    FindMouse.LastX := savedFindMouse.lastX
    FindMouse.LastY := savedFindMouse.lastY
    FindMouse.LastMoveTick := savedFindMouse.lastMoveTick
    FindMouse.LegAxis := savedFindMouse.legAxis
    FindMouse.LegSign := savedFindMouse.legSign
    FindMouse.LegStartX := savedFindMouse.legStartX
    FindMouse.LegStartY := savedFindMouse.legStartY
    FindMouse.LegStartTick := savedFindMouse.legStartTick
    FindMouse.LegTravel := savedFindMouse.legTravel
    FindMouse.LegPeakX := savedFindMouse.legPeakX
    FindMouse.LegPeakY := savedFindMouse.legPeakY
    FindMouse.ReverseStreak := savedFindMouse.streak
    FindMouse.LastReverseTick := savedFindMouse.lastReverseTick
    FindMouse.StreakStartX := savedFindMouse.streakStartX
    FindMouse.StreakStartY := savedFindMouse.streakStartY
    FindMouse.StreakTravel := savedFindMouse.streakTravel
    FindMouse.StreakMinX := savedFindMouse.streakMinX
    FindMouse.StreakMinY := savedFindMouse.streakMinY
    FindMouse.StreakMaxX := savedFindMouse.streakMaxX
    FindMouse.StreakMaxY := savedFindMouse.streakMaxY
FindMouse.StreakMaxY := savedFindMouse.streakMaxY
FindMouse.LastMoveTick := savedFindMouse.lastMoveTick
}
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
AssertContains(smartPasteSource, 'RunWait(command, "", this.HelperTimeoutMs)', "smart paste runs the helper with a hard timeout instead of INFINITE")
AssertNotContains(smartPasteSource, 'RunWait(command, , "Hide")', "smart paste no longer uses RunWait Hide")
AssertContains(smartPasteSource, 'Notify.State("✓"', "smart paste uses lightweight state notification")
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

#Include review-regressions.ahk
#Include tts-lifecycle.ahk
TtsLifecycleTests()
#Include text-workflow.ahk
#Include translation-lifecycle.ahk

FileAppend "PASS: core assertions`n", resultFile
ExitApp 0



