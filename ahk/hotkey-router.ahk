#Requires AutoHotkey v2.0

; ============================================================
; 快捷键路由层
;
; Shortcuts 只保存按键配置；
; feature 只保存功能实现；
; 本文件负责校验、注册和 Caps Leader 的组合键标记。
; ============================================================

class HotkeyRouter {
    static Registry := Map()
    static RoutedCallbacks := []
    static Registered := []
    static Defaults := Map()
    static NativeRegister := 0

    static SetHotkey(shortcut, callback := 0, options := "On") {
        if this.NativeRegister
            return this.NativeRegister.Call(shortcut, callback, options)
        if options = "Off"
            Hotkey shortcut, "Off"
        else
            Hotkey shortcut, callback, options
    }
    static FeatureIds := Map("Caps Lock / 输入法", "CapsLockIme", "Caps Lock / 输入法（松开）", "CapsLockIme",
        "朗读选中文字", "SpeakSelectedText", "划词翻译", "TranslateSelectedText", "截图翻译", "ScreenshotTranslate",
        "搜索选中文字", "SearchSelectedText", "打开选中目标", "OpenSelectedTarget", "定位选中目标", "LocateSelectedTarget",
        "窗口置顶", "AlwaysOnTop", "隐藏当前窗口", "HideActiveWindow", "显示隐藏文件", "ToggleHiddenFiles",
        "切换点文件", "ToggleDotfiles", "显示文件扩展名", "ToggleFileExtensions", "音频输出切换", "AudioSwitcher",
        "结束前台进程", "KillForegroundProcess", "重启前台进程", "RestartForegroundProcess", "智能粘贴", "SmartPaste",
        "同应用下一窗口", "SwitchAppWindowNext", "同应用上一窗口", "SwitchAppWindowPrevious",
        "同应用窗口切换重置", "SwitchAppWindowReset")

    static Normalize(shortcut) {
        shortcut := Trim(shortcut)
        prefixFlags := Map("*", false)
        modifiers := Map(
            "^", Map("", false, "<", false, ">", false),
            "!", Map("", false, "<", false, ">", false),
            "+", Map("", false, "<", false, ">", false),
            "#", Map("", false, "<", false, ">", false)
        )
        position := 1

        while (position <= StrLen(shortcut)) {
            token := SubStr(shortcut, position, 1)
            if (token = "~" || token = "$") {
                position += 1
                continue
            }
            if prefixFlags.Has(token) {
                prefixFlags[token] := true
                position += 1
                continue
            }

            if (token = "<" || token = ">") {
                modifier := SubStr(shortcut, position + 1, 1)
                if modifiers.Has(modifier) {
                    modifiers[modifier][token] := true
                    position += 2
                    continue
                }
            }

            if modifiers.Has(token) {
                modifiers[token][""] := true
                position += 1
                continue
            }
            break
        }

        normalized := prefixFlags["*"] ? "*" : ""
        for modifier in ["^", "!", "+", "#"] {
            if modifiers[modifier][""]
                normalized .= modifier
            if modifiers[modifier]["<"]
                normalized .= "<" modifier
            if modifiers[modifier][">"]
                normalized .= ">" modifier
        }

        return normalized StrLower(SubStr(shortcut, position))
    }

    static Validate(featureName, shortcut, registry := unset) {
        if !IsSet(registry)
            registry := this.Registry

        normalized := this.Normalize(shortcut)
        if (normalized = "")
            throw Error(featureName " 的快捷键不能为空")

        if registry.Has(normalized)
            throw Error("快捷键冲突：" featureName " 与 " registry[normalized])

        registry[normalized] := featureName
        return normalized
    }

    static Register(featureName, shortcut, callback) {
        id := this.FeatureIds.Has(featureName) ? this.FeatureIds[featureName] : ""
        if id = "SwitchAppWindowReset" {
            if !ToolboxControls.ShortcutEnabled("SwitchAppWindowNext") && !ToolboxControls.ShortcutEnabled("SwitchAppWindowPrevious")
                return
        } else if id != "" && id != "CapsLockIme" && !ToolboxControls.ShortcutEnabled(id)
            return
        ; Physical-only hook callbacks prevent a custom Ctrl+C/V binding from
        ; recursively receiving the feature's own synthetic clipboard keys.
        if id != "" && id != "CapsLockIme" && id != "SwitchAppWindowReset" {
            if InStr(StrLower(shortcut), "capslock") && InStr(shortcut, "&")
                shortcut := "~" LTrim(shortcut, "~$")
            else if !InStr(shortcut, "$")
                shortcut := "$" shortcut
        }
        this.Validate(featureName, shortcut)
        if id != "" && id != "CapsLockIme" && id != "SwitchAppWindowReset" {
            callback := ObjBindMethod(this, "DispatchControlled", id, callback)
            this.RoutedCallbacks.Push(callback)
        }
        this.SetHotkey(shortcut, callback)
        this.Registered.Push({name: featureName, id: id, shortcut: shortcut, callback: callback})
    }

    static DispatchControlled(id, callback, hotkeyName) {
        if ToolboxControls.ShortcutEnabled(id)
            return callback.Call(hotkeyName)
    }

    static RegisterCapsChord(featureName, shortcut, callback) {
        routedCallback := InStr(StrLower(shortcut), "capslock") && InStr(shortcut, "&")
            ? ObjBindMethod(this, "DispatchCapsChord", callback) : callback
        this.RoutedCallbacks.Push(routedCallback)
        this.Register(featureName, shortcut, routedCallback)
    }

    static DispatchCapsChord(callback, hotkeyName) {
        ; 退出大写或没有有效按住时，状态机拒绝本次组合，不能再派发工具。
        if !MarkCapsChordUsed()
            return
        return callback.Call(hotkeyName)
    }

    static RegisterAll() {
        if this.Defaults.Count = 0 {
            for name, value in Shortcuts.OwnProps() {
                if Type(value) = "String"
                    this.Defaults[name] := value
            }
        }
        ToolboxControls.EnsureLoaded()
        for name, value in this.Defaults
            Shortcuts.%name% := ToolboxControls.Binding(name, value)
        CapsLockIme.SetFeatureEnabled(ToolboxControls.ShortcutEnabled("CapsLockIme"))
        this.Registry := Map()
        this.RoutedCallbacks := []
        this.Registered := []

        ; 输入层：keydown 启动状态机，keyup 完成短按判定。
        this.Register(
            "Caps Lock / 输入法",
            Shortcuts.CapsLockIme,
            CapsLockIme.HotkeyCallback
        )
        this.Register(
            "Caps Lock / 输入法（松开）",
            Shortcuts.CapsLockIme " Up",
            CapsLockIme.KeyUpCallback
        )

        ; Leader 层：先标记 chord，再调用互不依赖的 feature。
        this.RegisterCapsChord(
            "朗读选中文字",
            Shortcuts.SpeakSelectedText,
            SpeakSelectedText.HotkeyCallback
        )
        this.RegisterCapsChord(
            "划词翻译",
            Shortcuts.TranslateSelectedText,
            TranslateSelectedText.HotkeyCallback
        )
        this.RegisterCapsChord(
            "搜索选中文字",
            Shortcuts.SearchSelectedText,
            SearchSelectedText.HotkeyCallback
        )
        this.RegisterCapsChord("截图翻译", Shortcuts.ScreenshotTranslate, TextWorkflow.HotkeyCallback)
        this.RegisterCapsChord(
            "打开选中目标",
            Shortcuts.OpenSelectedTarget,
            OpenSelectedTarget.HotkeyCallback
        )
        this.RegisterCapsChord(
            "定位选中目标",
            Shortcuts.LocateSelectedTarget,
            LocateSelectedTarget.HotkeyCallback
        )
        this.RegisterCapsChord(
            "窗口置顶",
            Shortcuts.AlwaysOnTop,
            AlwaysOnTop.HotkeyCallback
        )
        this.RegisterCapsChord(
            "隐藏当前窗口",
            Shortcuts.HideActiveWindow,
            HideActiveWindow.HotkeyCallback
        )
        this.RegisterCapsChord(
            "显示隐藏文件",
            Shortcuts.ToggleHiddenFiles,
            ToggleHiddenFiles.HotkeyCallback
        )
        this.RegisterCapsChord(
            "切换点文件",
            Shortcuts.ToggleDotfiles,
            ToggleDotfiles.HotkeyCallback
        )
        this.RegisterCapsChord(
            "显示文件扩展名",
            Shortcuts.ToggleFileExtensions,
            ToggleFileExtensions.HotkeyCallback
        )
        this.RegisterCapsChord(
            "音频输出切换",
            Shortcuts.AudioSwitcher,
            AudioSwitcher.HotkeyCallback
        )
        this.RegisterCapsChord(
            "结束前台进程",
            Shortcuts.KillForegroundProcess,
            ForegroundProcess.KillCallback
        )
        this.RegisterCapsChord(
            "重启前台进程",
            Shortcuts.RestartForegroundProcess,
            ForegroundProcess.RestartCallback
        )

        ; 普通系统级快捷键。
        SmartPaste.Configure(
            ToolboxControls.ShortcutEnabled("VsCodeCopyPath") ? Shortcuts.VsCodeCopyPath : "",
            ToolboxControls.ShortcutEnabled("ZedCopyPath") ? Shortcuts.ZedCopyPath : ""
        )
        if ToolboxControls.ShortcutEnabled("SmartPaste")
            SmartPaste.EnsureHelperAvailable()
        this.Register(
            "智能粘贴",
            Shortcuts.SmartPaste,
            SmartPaste.HotkeyCallback
        )
        this.Register(
            "同应用下一窗口",
            Shortcuts.SwitchAppWindowNext,
            SwitchAppWindow.ForwardCallback
        )
        this.Register(
            "同应用上一窗口",
            Shortcuts.SwitchAppWindowPrevious,
            SwitchAppWindow.BackwardCallback
        )
        this.Register(
            "同应用窗口切换重置",
            Shortcuts.SwitchAppWindowReset,
            SwitchAppWindow.ResetCallback
        )
    }

    static Rebind() {
        old := this.Registered.Clone()
        oldShortcuts := Map()
        for name, value in this.Defaults
            oldShortcuts[name] := Shortcuts.%name%
        Critical "On"
        try {
            for item in old
                this.SetHotkey(item.shortcut, 0, "Off")
            try {
                this.RegisterAll()
                return true
            } catch {
                for item in this.Registered
                    try this.SetHotkey(item.shortcut, 0, "Off")
                this.Registered := []
                this.Registry := Map()
                for name, value in oldShortcuts
                    Shortcuts.%name% := value
                SmartPaste.Configure(
                    ToolboxControls.ShortcutEnabled("VsCodeCopyPath") ? Shortcuts.VsCodeCopyPath : "",
                    ToolboxControls.ShortcutEnabled("ZedCopyPath") ? Shortcuts.ZedCopyPath : ""
                )
                for item in old {
                    if item.id = "SwitchAppWindowReset" && !ToolboxControls.ShortcutEnabled("SwitchAppWindowNext") && !ToolboxControls.ShortcutEnabled("SwitchAppWindowPrevious")
                        continue
                    if item.id != "" && item.id != "CapsLockIme" && item.id != "SwitchAppWindowReset"
                        && !ToolboxControls.ShortcutEnabled(item.id)
                        continue
                    try {
                        this.SetHotkey(item.shortcut, item.callback)
                        this.Registered.Push(item)
                        this.Registry[this.Normalize(item.shortcut)] := item.name
                    }
                }
                ToolboxControls.Log("bindings-retained")
                return false
            }
        } finally Critical "Off"
    }
}

; 兼容现有测试和可能的外部调用；feature 本身不再使用这些函数。
NormalizeFeatureHotkey(shortcut) {
    return HotkeyRouter.Normalize(shortcut)
}

ValidateFeatureHotkey(featureName, shortcut, registry) {
    return HotkeyRouter.Validate(featureName, shortcut, registry)
}

RegisterFeatureHotkey(featureName, shortcut, callback) {
    return HotkeyRouter.Register(featureName, shortcut, callback)
}

if !IsToolboxTestMode() {
    try HotkeyRouter.RegisterAll()
    catch {
        for item in HotkeyRouter.Registered
            try HotkeyRouter.SetHotkey(item.shortcut, 0, "Off")
        for key in ToolboxControls.Active.Clone() {
            if InStr(key, "binding_") = 1
                ToolboxControls.Active.Delete(key)
        }
        HotkeyRouter.RegisterAll()
        ToolboxControls.Log("startup-bindings-defaulted")
    }
}
