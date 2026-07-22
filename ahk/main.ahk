#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

global ToolboxStarting := true

HandleToolboxError(exception, mode) {
    global ToolboxStarting
    if !ToolboxStarting
        return false

    MsgBox "工具箱启动失败：`n" exception.Message, "脚本工具箱启动错误", "Iconx"
    ExitApp 1
}

global ToolboxStartupErrorHandler := HandleToolboxError
OnError ToolboxStartupErrorHandler

#Include shortcuts.ahk

global RegisteredFeatureHotkeys := Map()

IsToolboxTestMode() {
    return A_Args.Length >= 1 && A_Args[1] = "--test"
}

NormalizeFeatureHotkey(shortcut) {
    shortcut := Trim(shortcut)
    prefixFlags := Map("*", false)
    modifiers := Map(
        "^", Map("", false, "<", false, ">", false),
        "!", Map("", false, "<", false, ">", false),
        "+", Map("", false, "<", false, ">", false),
        "#", Map("", false, "<", false, ">", false))
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

    normalized := ""
    for prefix in ["*"] {
        if prefixFlags[prefix]
            normalized .= prefix
    }
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

ValidateFeatureHotkey(featureName, shortcut, registry) {
    normalized := NormalizeFeatureHotkey(shortcut)
    if (normalized = "")
        throw Error(featureName " 的快捷键不能为空")

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

ToolboxStarting := false
