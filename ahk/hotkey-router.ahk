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
        this.Validate(featureName, shortcut)
        Hotkey shortcut, callback
    }

    static RegisterCapsChord(featureName, shortcut, callback) {
        routedCallback := ObjBindMethod(this, "DispatchCapsChord", callback)
        this.RoutedCallbacks.Push(routedCallback)
        this.Register(featureName, shortcut, routedCallback)
    }

    static DispatchCapsChord(callback, hotkeyName) {
        MarkCapsChordUsed()
        return callback.Call(hotkeyName)
    }

    static RegisterAll() {
        this.Registry := Map()
        this.RoutedCallbacks := []

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
            "搜索选中文字",
            Shortcuts.SearchSelectedText,
            SearchSelectedText.HotkeyCallback
        )
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
            "显示隐藏文件",
            Shortcuts.ToggleHiddenFiles,
            ToggleHiddenFiles.HotkeyCallback
        )

        ; 普通系统级快捷键。
        SmartPaste.Configure(
            Shortcuts.VsCodeCopyPath,
            Shortcuts.ZedCopyPath
        )
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

if !IsToolboxTestMode()
    HotkeyRouter.RegisterAll()
