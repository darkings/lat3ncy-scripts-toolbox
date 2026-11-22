; The registrar validates real AHK syntax with every native key kept OFF. No
; synthetic key input, foreground actions, production policy or hardware writes.
class ControlsTestRegistrar {
    Entries := Map()
    FailShortcut := ""
    Calls := 0

    Call(shortcut, callback, options) {
        if shortcut = this.FailShortcut && options = "On"
            throw Error("injected-bind-failure")
        if options = "On" {
            Hotkey shortcut, callback, "Off"
            this.Entries[shortcut] := {enabled: true, callback: callback}
        } else {
            if this.Entries.Has(shortcut)
                this.Entries[shortcut].enabled := false
            try Hotkey shortcut, "Off"
        }
    }

    Probe(*) {
        this.Calls += 1
    }
}

class DisabledCapsControlsProbe extends CapsLockIme {
    static NativeToggles := 0
    static ImeToggles := 0
    static ToggleNativeCaps() => this.NativeToggles += 1
    static ToggleIme() => this.ImeToggles += 1
    static CaptureImeTarget() => 0
}

class DisabledAudioWarmupProbe extends SpeakSelectedText {
    static Generation := 55
    static PendingText := ""
    static WarmupJob := ""
    static WarmupTimer := ""
    static LastText := ""
    static LaunchTts(raw, generation) {
        AssertEqual(55, generation, "disabled warmup preserves speech request generation")
        this.LastText := raw
    }
}

class DisabledAudioWarmupJob {
    Disposed := false
    Dispose() => this.Disposed := true
}

ToolboxControlTests() {
    parsed := ToolboxControls.Parse('{"version":1,"module_translate_enabled":false,"binding_AlwaysOnTop":"^!F23","hotkey_AlwaysOnTop_enabled":true}')
    AssertEqual(false, ToolboxControls.ModuleEnabled("translate", parsed), "controls disable translation module")
    AssertEqual("^!F23", ToolboxControls.Binding("AlwaysOnTop", "~CapsLock & t", parsed), "controls preserve custom binding")
    AssertEqual(false, ToolboxControls.ShortcutEnabled("TranslateSelectedText", parsed), "module gate also disables its shortcut")
    AssertThrows(() => ToolboxControls.Parse('{"version":1,"tray_visible":"false"}'), "controls-type", "string boolean is not accepted by AHK policy")
    AssertThrows(() => ToolboxControls.Parse('{"version":"1"}'), "controls-version", "control version must be numeric")
    AssertThrows(() => ToolboxControls.Parse('{"version":1,"binding_AlwaysOnTop":1}'), "controls-type", "numeric key binding is not accepted")
    AssertThrows(() => ToolboxControls.Parse('{"version":1,"binding_CapsLockIme":"F12"}'), "caps-base-fixed", "CapsLock base remains fixed")
    AssertThrows(() => ToolboxControls.Parse('{"version":1,"unknown":true}'), "controls-field", "unknown policy fields are rejected")

    old := {active: ToolboxControls.Active, loaded: ToolboxControls.Loaded,
        registry: HotkeyRouter.Registry, callbacks: HotkeyRouter.RoutedCallbacks, registered: HotkeyRouter.Registered,
        defaults: HotkeyRouter.Defaults, registrar: HotkeyRouter.NativeRegister, caps: CapsLockIme.FeatureEnabled,
        vscode: SmartPaste.VsCodeCopyPathShortcut, zed: SmartPaste.ZedCopyPathShortcut}
    originalShortcuts := Map()
    for name, value in Shortcuts.OwnProps() {
        if Type(value) = "String"
            originalShortcuts[name] := value
    }
    registrar := ControlsTestRegistrar()
    try {
        policy := Map()
        for name in ToolboxControls.FeatureNames
            policy["feature_" name "_enabled"] := false
        ToolboxControls.Active := policy
        policy["module_audio_enabled"] := false
        AssertEqual(false, DisabledAudioWarmupProbe.IsAutoSwitchEnabled(), "disabled audio skips automatic headset switching")
        DisabledAudioWarmupProbe.StartHeadsetWarmup("fixed warmup probe")
        AssertEqual("fixed warmup probe", DisabledAudioWarmupProbe.LastText, "disabled audio continues speech without a child")
        warmupJob := DisabledAudioWarmupJob()
        DisabledAudioWarmupProbe.WarmupJob := {job: warmupJob, outputFile: "", generation: 55}
        DisabledAudioWarmupProbe.PendingText := "fixed interrupted warmup"
        DisabledAudioWarmupProbe.PollWarmup()
        AssertEqual(true, warmupJob.Disposed, "disabling audio disposes an in-progress warmup child")
        AssertEqual("fixed interrupted warmup", DisabledAudioWarmupProbe.LastText, "cancelled warmup still continues speech")
        AssertEqual("", DisabledAudioWarmupProbe.PendingText, "cancelled warmup releases its pending input")
        HotkeyRouter.NativeRegister := registrar
        HotkeyRouter.RegisterAll()
        AssertEqual(2, HotkeyRouter.Registered.Length, "disabled actions leave only fixed leader tracking")

        policy["feature_AlwaysOnTop_enabled"] := true
        HotkeyRouter.RegisterCapsChord("窗口置顶", "^!F23", ObjBindMethod(registrar, "Probe"))
        item := HotkeyRouter.Registered[-1]
        AssertEqual("$^!F23", item.shortcut, "custom normal bindings force physical-only hook")
        item.callback.Call(item.shortcut)
        AssertEqual(1, registrar.Calls, "custom non-Caps shortcut does not require Caps state")
        policy["hotkey_AlwaysOnTop_enabled"] := false
        item.callback.Call(item.shortcut)
        AssertEqual(1, registrar.Calls, "disabled shortcut rejects already queued callback")
        policy["hotkey_AlwaysOnTop_enabled"] := true
        policy["binding_AlwaysOnTop"] := "^!F23"
        AssertEqual(true, HotkeyRouter.Rebind(), "valid profile can rebind routes")
        AssertEqual(3, HotkeyRouter.Registered.Length, "custom action plus fixed leader pair")

        registrar.FailShortcut := "$^!F24"
        policy["binding_AlwaysOnTop"] := "^!F24"
        AssertEqual(false, HotkeyRouter.Rebind(), "native registration failure retains prior valid routes")
        AssertEqual(true, registrar.Entries["$^!F23"].enabled, "prior valid binding restored after failure")
        AssertEqual("^!F23", Shortcuts.AlwaysOnTop, "failed registration restores effective shortcut value")
        policy["feature_AlwaysOnTop_enabled"] := false
        AssertEqual(true, HotkeyRouter.Rebind(), "disabled function unregisters its shortcut")
        AssertEqual(false, registrar.Entries["$^!F23"].enabled, "disabled function releases prior key")

        DisabledCapsControlsProbe.SetFeatureEnabled(false)
        DisabledCapsControlsProbe.OnKeyDown()
        DisabledCapsControlsProbe.OnKeyUp()
        AssertEqual(1, DisabledCapsControlsProbe.NativeToggles, "disabled input enhancement preserves plain Caps behavior")
        DisabledCapsControlsProbe.OnKeyDown()
        AssertEqual(true, DisabledCapsControlsProbe.MarkChordUsed(), "fixed leader still tracks tools with enhancement disabled")
        DisabledCapsControlsProbe.OnKeyUp()
        AssertEqual(1, DisabledCapsControlsProbe.NativeToggles, "leader chord does not toggle native Caps")
        AssertEqual(0, DisabledCapsControlsProbe.ImeToggles, "disabled enhancement does not alter IME")
    } finally {
        for shortcut in registrar.Entries
            try Hotkey shortcut, "Off"
        for name, value in originalShortcuts
            Shortcuts.%name% := value
        ToolboxControls.Active := old.active
        ToolboxControls.Loaded := old.loaded
        HotkeyRouter.Registry := old.registry
        HotkeyRouter.RoutedCallbacks := old.callbacks
        HotkeyRouter.Registered := old.registered
        HotkeyRouter.Defaults := old.defaults
        HotkeyRouter.NativeRegister := old.registrar
        CapsLockIme.SetFeatureEnabled(old.caps)
        SmartPaste.Configure(old.vscode, old.zed)
    }
}

ToolboxControlTests()
