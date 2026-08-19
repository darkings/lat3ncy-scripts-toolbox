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

IsToolboxTestMode() {
    return A_Args.Length >= 1 && A_Args[1] = "--test"
}

; ============================================================
; 功能实现层：只加载功能，不在模块内部注册快捷键
; ============================================================

; CapsLock 增强输入法切换：短按切换中英文，长按 >= 500ms 启用大写，再按一次退出 [快捷键: CapsLock]
#Include features\caps-lock-ime.ahk

; 窗口置顶：将当前活动窗口置顶或取消置顶 [快捷键: Caps + T (CapsLock & t)]
#Include features\always-on-top.ahk

; 划词搜索：使用默认浏览器 Google 搜索选中文本 [快捷键: Caps + G (CapsLock & g)]
#Include features\search-selected-text.ahk

; 智能粘贴：在文件资源管理器/编辑器中粘贴图片时自动保存为本地 PNG 文件 [快捷键: Ctrl + V ($^v)]
#Include features\smart-paste\smart-paste.ahk

; 打开选中目标：快速打开选中的文件路径或网址 URL [快捷键: Caps + O (CapsLock & o)]
#Include features\open-selected-target.ahk

; 定位选中目标：在资源管理器中选中并高亮显示目标文件/目录 [快捷键: Caps + E (CapsLock & e)]
#Include features\locate-selected-target.ahk

; 切换隐藏文件：一键切换资源管理器中隐藏文件的显示/隐藏状态 [快捷键: Caps + H (CapsLock & h)]
#Include features\toggle-hidden-files.ahk

; 朗读选中文字：智能中英文双语音色极速发音，再次按下即时打断 [快捷键: Caps + S (CapsLock & s)]
#Include features\speak-selected-text.ahk

; 同应用窗口切换：在同一应用程序的多个窗口之间前后循环切换 [快捷键: Alt + ` (!sc029) / Shift + Alt + ` (+!sc029)]
#Include features\switch-app-window.ahk

; 统一路由层必须在全部 feature 之后加载。
#Include hotkey-router.ahk

ToolboxStarting := false
