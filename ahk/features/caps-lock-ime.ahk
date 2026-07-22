#Requires AutoHotkey v2.0

class CapsLockIme {
    static Action(wasLocked, heldMilliseconds) {
        if wasLocked
            return "disable-caps-force-english"
        return heldMilliseconds >= 500 ? "enable-caps" : "toggle-input"
    }

    static Handle(*) {
        wasLocked := GetKeyState("CapsLock", "T")
        pressedAt := A_TickCount
        KeyWait "CapsLock"
        action := this.Action(wasLocked, A_TickCount - pressedAt)

        if (action = "disable-caps-force-english") {
            SetCapsLockState "Off"
            imeResult := this.ForceEnglishIme()
            if (imeResult = "fallback") {
                Send "{Shift}"
                this.ShowTip("已关闭大写，输入法使用 Shift 回退")
            } else if (imeResult = "forced")
                this.ShowTip("已关闭大写并切换到英文")
            else
                this.ShowTip("已关闭大写，当前已是英文")
        } else if (action = "enable-caps") {
            SetCapsLockState "On"
            this.ShowTip("已开启大写锁定")
        } else {
            Send "{Shift}"
            this.ShowTip("已切换中英文")
        }
    }

    static ForceEnglishIme() {
        focusedHwnd := this.GetFocusedControlHwnd()
        if !focusedHwnd
            return "fallback"

        processId := 0
        threadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", focusedHwnd, "UInt*", &processId, "UInt")
        keyboardLayout := DllCall("User32\GetKeyboardLayout", "UInt", threadId, "Ptr")
        languageId := keyboardLayout & 0xFFFF

        if ((languageId & 0x03FF) != 0x04)
            return "already-english"

        inputContext := DllCall("Imm32\ImmGetContext", "Ptr", focusedHwnd, "Ptr")
        if !inputContext
            return "fallback"

        try {
            isOpen := DllCall("Imm32\ImmGetOpenStatus", "Ptr", inputContext, "Int")
            if !isOpen
                return "already-english"

            setSucceeded := DllCall("Imm32\ImmSetOpenStatus", "Ptr", inputContext, "Int", false, "Int")
            if !setSucceeded
                return "fallback"

            isStillOpen := DllCall("Imm32\ImmGetOpenStatus", "Ptr", inputContext, "Int")
            return isStillOpen ? "fallback" : "forced"
        } finally {
            DllCall("Imm32\ImmReleaseContext", "Ptr", focusedHwnd, "Ptr", inputContext, "Int")
        }
    }

    static GetFocusedControlHwnd() {
        activeHwnd := WinExist("A")
        if !activeHwnd
            return 0

        processId := 0
        threadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", activeHwnd, "UInt*", &processId, "UInt")
        guiInfo := Buffer(8 + (6 * A_PtrSize) + 16, 0)
        NumPut("UInt", guiInfo.Size, guiInfo, 0)

        if !DllCall("User32\GetGUIThreadInfo", "UInt", threadId, "Ptr", guiInfo.Ptr, "Int")
            return activeHwnd

        focusedHwnd := NumGet(guiInfo, 8 + A_PtrSize, "Ptr")
        return focusedHwnd || activeHwnd
    }

    static ShowTip(message) {
        ToolTip message
        SetTimer (*) => ToolTip(), -1500
    }
}

if !IsToolboxTestMode()
    RegisterFeatureHotkey("Caps Lock / 输入法", Shortcuts.CapsLockIme, CapsLockIme.Handle)
