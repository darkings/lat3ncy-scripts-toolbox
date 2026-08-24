#Requires AutoHotkey v2.0
#Include ..\renderer.ahk
#Include ..\notify.ahk

; 强制深色
class FakeDark {
    static Call() {
        ; 直接调用 Show 但替换 GetCurrentTheme
        orig := NotifyRenderer.GetCurrentTheme
        NotifyRenderer.GetCurrentTheme := (*) => NotifyRenderer.DarkTheme
        Notify.Success("✓", "成功", 2500)
        Sleep 2600
        Notify.Error("×", "失败", 2500)
        Sleep 2600
        Notify.State("●", "状态", 2500)
        Sleep 2600
    }
}
FakeDark.Call()
ExitApp 0
