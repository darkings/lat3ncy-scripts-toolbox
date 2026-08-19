#Requires AutoHotkey v2.0

class Shortcuts {
    ; 【输入】
    static CapsLockIme := "*$CapsLock"

    ; 【AHK 工具层 (Caps 组合键)】
    ; ~ 让 CapsLock 自身的 key-down 回调立即执行；原生 CapsLock 仍由上方热键抑制。
    static SpeakSelectedText := "~CapsLock & s"
    static SearchSelectedText := "~CapsLock & g"
    static OpenSelectedTarget := "~CapsLock & o"
    static LocateSelectedTarget := "~CapsLock & e"
    static AlwaysOnTop := "~CapsLock & t"
    static ToggleHiddenFiles := "~CapsLock & h"

    ; 【系统级特殊功能】
    static SmartPaste := "$^v"
    static VsCodeCopyPath := "+!c"
    static ZedCopyPath := "+!c"

    ; 【窗口导航】
    static SwitchAppWindowNext := "!sc029"
    static SwitchAppWindowPrevious := "+!sc029"
    static SwitchAppWindowReset := "~Alt Up"
}
