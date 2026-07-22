#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

#Include shortcuts.ahk

global RegisteredFeatureHotkeys := Map()

IsToolboxTestMode() {
    return A_Args.Length >= 1 && A_Args[1] = "--test"
}

ValidateFeatureHotkey(featureName, shortcut, registry) {
    if (shortcut = "")
        throw Error(featureName " 的快捷键不能为空")

    normalized := StrLower(shortcut)
    if registry.Has(normalized)
        throw Error("快捷键冲突：" featureName " 与 " registry[normalized])

    registry[normalized] := featureName
    return normalized
}

RegisterFeatureHotkey(featureName, shortcut, callback) {
    global RegisteredFeatureHotkeys
    ValidateFeatureHotkey(featureName, shortcut, RegisteredFeatureHotkeys)
    Hotkey shortcut, callback
}

#Include features\caps-lock-ime.ahk
#Include features\always-on-top.ahk
#Include features\search-selected-text.ahk
#Include features\smart-paste\smart-paste.ahk
#Include features\open-selected-target.ahk
#Include features\locate-selected-target.ahk
#Include features\toggle-hidden-files.ahk
