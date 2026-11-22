#Requires AutoHotkey v2.0

; Flat, non-secret per-checkout policy. No config text is evaluated as code.
class ToolboxControls {
    static Active := Map()
    static Loaded := false
    static LastText := ""
    static Timer := 0
    static TestPath := ""
    static LastFailureTick := -60000
    static FeatureNames := ["CapsLockIme", "SpeakSelectedText", "TranslateSelectedText", "ScreenshotTranslate",
        "SearchSelectedText", "OpenSelectedTarget", "LocateSelectedTarget", "AlwaysOnTop", "HideActiveWindow",
        "ToggleHiddenFiles", "ToggleDotfiles", "ToggleFileExtensions", "AudioSwitcher", "KillForegroundProcess",
        "RestartForegroundProcess", "SmartPaste", "SwitchAppWindowNext", "SwitchAppWindowPrevious",
        "VsCodeCopyPath", "ZedCopyPath", "ThinkPadBacklight", "CaffeineIndicator", "FindMouse"]
    static Modules := Map("SpeakSelectedText", "tts", "TranslateSelectedText", "translate", "ScreenshotTranslate", "ocr",
        "AudioSwitcher", "audio", "ThinkPadBacklight", "theme")

    static ProfilePath() {
        if this.TestPath != ""
            return this.TestPath
        SplitPath A_LineFile, , &sharedDir
        SplitPath sharedDir, , &repoDir
        return repoDir "\.toolbox-controls.json"
    }

    static ReadText() {
        path := this.ProfilePath()
        if !FileExist(path)
            return ""
        file := FileOpen(path, "r", "UTF-8")
        try {
            if file.Length > 16384
                throw Error("controls-size")
            return file.Read(16385)
        } finally file.Close()
    }

    static Parse(text) {
        if text = ""
            return Map()
        values := CaffeineIndicator.ReadState(text)
        if !values.Has("version") || values["version"] != "1" || !RegExMatch(text, '"version"\s*:\s*1\s*[,}]')
            throw Error("controls-version")
        allowed := Map("version", "number", "tray_visible", "bool")
        for module in ["translate", "tts", "ocr", "audio", "theme", "power", "rgb", "capture"]
            allowed["module_" module "_enabled"] := "bool"
        for name in this.FeatureNames {
            allowed["feature_" name "_enabled"] := "bool"
            if Shortcuts.HasOwnProp(name) {
                allowed["hotkey_" name "_enabled"] := "bool"
                allowed["binding_" name] := "binding"
            }
        }
        result := Map()
        for key, value in values {
            if !allowed.Has(key)
                throw Error("controls-field")
            if allowed[key] = "bool" {
                if (value != "true" && value != "false") || !RegExMatch(text, '"' key '"\s*:\s*(?:true|false)\s*[,}]')
                    throw Error("controls-type")
                result[key] := value = "true"
            } else if allowed[key] = "binding" {
                if !RegExMatch(text, '"' key '"\s*:\s*"')
                    throw Error("controls-type")
                if key = "binding_CapsLockIme" {
                    if value != "*$CapsLock"
                        throw Error("caps-base-fixed")
                } else if StrLen(value) > 80 || !RegExMatch(value,
                    "i)^(?:~?CapsLock\s*&\s*)?[~$]*[!^+#]*(?:[a-z0-9.,/;=\[\]-]|F(?:[1-9]|1\d|2[0-4])|sc[0-9a-f]{3}|vk[0-9a-f]{2}|Tab|Space|Enter|Esc|Escape|Backspace|Delete|Insert|Home|End|PgUp|PgDn|Up|Down|Left|Right|AppsKey|PrintScreen|Pause|ScrollLock|NumLock|Numpad(?:[0-9]|Add|Sub|Mult|Div|Dot|Enter))$")
                    throw Error("controls-binding")
                result[key] := value
            }
        }
        return result
    }

    static EnsureLoaded() {
        if this.Loaded
            return
        try {
            this.LastText := this.ReadText()
            this.Active := this.Parse(this.LastText)
        } catch {
            ; An invalid initial policy cannot silently enable actions.
            for name in this.FeatureNames
                this.Active["feature_" name "_enabled"] := false
            this.Log("initial-rejected")
        }
        this.Loaded := true
    }

    static Flag(key, fallback := true, values := unset) {
        if !IsSet(values) {
            this.EnsureLoaded()
            values := this.Active
        }
        return values.Has(key) ? values[key] : fallback
    }

    static ModuleEnabled(name, values := unset) {
        return IsSet(values) ? this.Flag("module_" name "_enabled", true, values) : this.Flag("module_" name "_enabled")
    }

    static FeatureEnabled(name, values := unset) {
        if !IsSet(values) {
            this.EnsureLoaded()
            values := this.Active
        }
        if !this.Flag("feature_" name "_enabled", true, values)
            return false
        if this.Modules.Has(name) && !this.ModuleEnabled(this.Modules[name], values)
            return false
        return name != "ScreenshotTranslate" || this.ModuleEnabled("translate", values)
    }

    static ShortcutEnabled(name, values := unset) {
        if !IsSet(values) {
            this.EnsureLoaded()
            values := this.Active
        }
        return this.FeatureEnabled(name, values) && this.Flag("hotkey_" name "_enabled", true, values)
    }

    static Binding(name, original, values := unset) {
        if !IsSet(values) {
            this.EnsureLoaded()
            values := this.Active
        }
        key := "binding_" name
        return values.Has(key) ? values[key] : original
    }

    static Start() {
        this.EnsureLoaded()
        if this.Timer
            return
        this.Timer := ObjBindMethod(this, "Poll")
        SetTimer(this.Timer, 500)
        OnExit(ObjBindMethod(this, "Stop"))
    }

    static Stop(*) {
        if this.Timer
            SetTimer(this.Timer, 0)
        this.Timer := 0
    }

    static Poll(*) {
        ToolboxReload.Poll()
        if GetKeyState("CapsLock", "P")
            return
        try {
            text := this.ReadText()
            if text = this.LastText
                return
            candidate := this.Parse(text)
            this.Active := candidate
            this.LastText := text
            applied := HotkeyRouter.Rebind()
            this.ApplyResidents()
            this.Log(applied ? "applied" : "bindings-retained")
        } catch {
            if A_TickCount - this.LastFailureTick >= 60000 {
                this.Log("apply-rejected")
                this.LastFailureTick := A_TickCount
            }
        }
    }

    static ApplyResidents() {
        CapsLockIme.SetFeatureEnabled(this.ShortcutEnabled("CapsLockIme"))
        if !this.ModuleEnabled("tts")
            SpeakSelectedText.StopCurrent()
        if !this.ModuleEnabled("translate")
            TranslateSelectedText.CancelCurrent()
        if !this.FeatureEnabled("ScreenshotTranslate")
            TextWorkflow.CancelCapture()
        if !this.FeatureEnabled("AudioSwitcher")
            AudioSwitcher.Finish()
        if this.FeatureEnabled("CaffeineIndicator")
            CaffeineIndicator.Start()
        else
            CaffeineIndicator.Stop()
        if this.FeatureEnabled("ThinkPadBacklight") {
            if !ThinkPadBacklight.IsActive
                ThinkPadBacklight.Start()
        } else
            ThinkPadBacklight.Stop()
        wanted := this.FeatureEnabled("FindMouse")
        FindMouse.Enabled := wanted
        if wanted {
            if !FindMouse.Hook
                FindMouse.Start()
        } else if FindMouse.Hook
            FindMouse.Stop()
    }

    static Log(event) {
        try FileAppend("[" A_Now "] controls=" event "`n", A_Temp "\lat3ncy-controls.log", "UTF-8")
    }
}
