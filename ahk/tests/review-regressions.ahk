; Injected tray backend: records visual operations without registering shell icons.
class FakeCaffeineTray {
    static Added := [], Removed := [], Swapped := []
    static Reset() {
        this.Added := []
        this.Removed := []
        this.Swapped := []
    }
    static Add(id, path, tip) {
        this.Added.Push([id, path, tip])
        return true
    }
    static Remove(id) {
        this.Removed.Push(id)
        return true
    }
    static SetIcon(id, path) {
        this.Swapped.Push([id, path])
        return true
    }
}

global TrayIconActions := []
TrayRecordIcon(action, uid, hIcon, tip) {
    TrayIconActions.Push(action)
    return true
}

; Included by run-tests.ahk after its assertion helpers; production startup is disabled.
ReviewRegressions() {
    global TrayIconActions
    ; Exercise the actual renderer/anchor call chain, not just source strings.
    try {
        AssertEqual(true, NotifyRenderer.Show("popup", "", "Anchor contract regression", 100), "popup renders through anchor adapter")
        NotifyRenderer.Hide()
        AssertEqual(true, NotifyRenderer.Show("state", "中", "", 100), "state renders through anchor adapter")
    } finally {
        NotifyRenderer.Hide()
    }

    root := A_Temp "\toolbox-review-" SmartPaste.NewGuid()
    DirCreate root
    oldConfig := CaffeineIndicator.ConfigPath
    oldClockFile := ImeHud._caretServerFile
    oldEnv := EnvGet("LAT3NCY_COFFEE_TEST_DIR")
    try {
        EnvSet "LAT3NCY_COFFEE_TEST_DIR", root
        config := root "\config.toml"
        FileAppend '[caffeine]`ncoffee_dir = "%LAT3NCY_COFFEE_TEST_DIR%" # test`n', config, "UTF-8-RAW"
        CaffeineIndicator.ConfigPath := config
        AssertEqual(root, CaffeineIndicator.CoffeeDirectory(), "indicator honors configured directory and environment expansion")
        pid := DllCall("GetCurrentProcessId", "UInt")
        ticks := CaffeineIndicator.ProcessStartTicks(pid)
        AssertEqual(true, ticks > 0, "indicator reads process creation FILETIME")
        stateFile := root "\state.json"
        good := '{"pid":' pid ',"startTicks":' ticks ',"startTime":1,"durationSeconds":null}'
        pretty := "{`r`n`t" SubStr(good, 2, -1) "`r`n}"
        pretty := StrReplace(pretty, ",", ",`r`n`t")
        AssertEqual(String(pid), CaffeineIndicator.ReadState(pretty)["pid"], "Coffee parser accepts JSON CRLF and tabs")
        AssertThrows(() => CaffeineIndicator.ReadState("{`n" Chr(34) "pid" Chr(34) ":1,`n}"), "Invalid Coffee state", "multiline trailing comma remains rejected")
        controls := "{`r`n  " Chr(34) "version" Chr(34) ": 1,`r`n  " Chr(34) "feature_CaffeineIndicator_enabled" Chr(34) ": true`r`n}"
        AssertEqual(true, ToolboxControls.FeatureEnabled("CaffeineIndicator", ToolboxControls.Parse(controls)), "pretty settings preserve enabled Caffeine indicator")
        controls := StrReplace(controls, ": true", ": false")
        AssertEqual(false, ToolboxControls.FeatureEnabled("CaffeineIndicator", ToolboxControls.Parse(controls)), "pretty settings preserve disabled Caffeine indicator")
        FileAppend good, stateFile, "UTF-8-RAW"
        AssertEqual(true, CaffeineIndicator.IsActive(), "valid Coffee state is active")
        FileAppend "stop", root "\stop.flag"
        AssertEqual(false, CaffeineIndicator.IsActive(), "Coffee stop flag overrides live process")
        FileDelete root "\stop.flag"
        FileDelete stateFile
        FileAppend StrReplace(good, '"durationSeconds":null', '"durationSeconds":1'), stateFile, "UTF-8-RAW"
        AssertEqual(false, CaffeineIndicator.IsActive(), "expired timed Coffee state is inactive")
        FileDelete stateFile
        FileAppend StrReplace(good, '"startTicks":' ticks, '"startTicks":1'), stateFile, "UTF-8-RAW"
        AssertEqual(false, CaffeineIndicator.IsActive(), "Coffee PID reuse is rejected")
        FileDelete stateFile
        FileAppend SubStr(good, 1, -1), stateFile, "UTF-8-RAW"
        AssertEqual(false, CaffeineIndicator.IsActive(), "partial Coffee state is inactive")

        ; Tray icon state must follow the same Coffee state as the power policy.
        oldHost := CaffeineIndicator.Host
        oldShowing := CaffeineIndicator.Showing
        oldStarted := CaffeineIndicator.Started
        try {
            FakeCaffeineTray.Reset()
            CaffeineIndicator.Host := FakeCaffeineTray
            CaffeineIndicator.Started := true
            CaffeineIndicator.Showing := false
            FileDelete stateFile
            FileAppend good, stateFile, "UTF-8-RAW"
            CaffeineIndicator.Poll()
            AssertEqual(true, CaffeineIndicator.Showing, "active Coffee shows tray icon")
            AssertEqual(1, FakeCaffeineTray.Added.Length, "active poll adds one icon")
            AssertEqual(CaffeineIndicator.IconId, FakeCaffeineTray.Added[1][1], "tray icon uses caffeine id")
            AssertEqual(CaffeineIndicator.IconPath(), FakeCaffeineTray.Added[1][2], "tray icon matches current theme")
            CaffeineIndicator.Poll()
            AssertEqual(1, FakeCaffeineTray.Added.Length, "steady active state does not re-add icon")
            colorBuf := Buffer(40, 0)
            StrPut("ImmersiveColorSet", colorBuf, "UTF-16")
            CaffeineIndicator.OnSettingChange(0, colorBuf.Ptr, 0x001A, 0)
            AssertEqual(1, FakeCaffeineTray.Swapped.Length, "theme change swaps tray icon")
            AssertEqual(CaffeineIndicator.IconPath(), FakeCaffeineTray.Swapped[1][2], "theme swap uses current icon path")
            FileAppend "stop", root "\stop.flag", "UTF-8-RAW"
            CaffeineIndicator.Poll()
            AssertEqual(false, CaffeineIndicator.Showing, "stopped Coffee hides tray icon")
            AssertEqual(1, FakeCaffeineTray.Removed.Length, "inactive poll removes icon")
            FileDelete root "\stop.flag"
        } finally {
            CaffeineIndicator.Host := oldHost
            CaffeineIndicator.Showing := oldShowing
            CaffeineIndicator.Started := oldStarted
        }

        ; Explorer restart: TrayHost re-registers existing icons with NIM_ADD.
        oldItems := TrayHost.Items
        oldOverride := TrayHost.SendIconOverride
        oldActions := TrayIconActions
        try {
            TrayIconActions := []
            TrayHost.Items := Map()
            TrayHost.Items["caffeine"] := {uid: 7, hIcon: 0, path: "x", tip: "t"}
            TrayHost.SendIconOverride := TrayRecordIcon
            TrayHost.OnTaskbarCreated()
            AssertEqual(1, TrayIconActions.Length, "explorer restart re-registers tray icon")
            AssertEqual(TrayHost.NIM_ADD, TrayIconActions[1], "explorer restart uses NIM_ADD")
        } finally {
            TrayHost.Items := oldItems
            TrayHost.SendIconOverride := oldOverride
            TrayIconActions := oldActions
        }

        clockFile := root "\caret.txt"
        ImeHud._caretServerFile := clockFile
        FileAppend "T|-2147483648|CARET|123|456|20|text-caret`n", clockFile, "UTF-8-RAW"
        caret := ImeHud.ReadCaretServer(2147483650)
        AssertEqual(true, caret.Known && caret.Ok, "signed legacy helper stamp is accepted")
        AssertEqual(2, caret.AgeMs, "signed tick boundary has correct age")
        FileDelete clockFile
        FileAppend "T|4294967290|NOCARET|none`n", clockFile, "UTF-8-RAW"
        caret := ImeHud.ReadCaretServer(5)
        AssertEqual(true, caret.Known, "tick wrap preserves fresh NOCARET")
        AssertEqual(11, caret.AgeMs, "tick wrap age is unsigned modular difference")
        AssertEqual(false, ImeHud.ReadCaretServer(5000).Known, "stale helper stamp is rejected")
    } finally {
        CaffeineIndicator.ConfigPath := oldConfig
        ImeHud._caretServerFile := oldClockFile
        EnvSet "LAT3NCY_COFFEE_TEST_DIR", oldEnv
        loop files root "\*", "F"
            FileDelete A_LoopFileFullPath
        DirDelete root
    }
}

ReviewRegressions()
