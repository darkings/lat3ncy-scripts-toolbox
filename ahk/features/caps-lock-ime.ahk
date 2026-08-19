#Requires AutoHotkey v2.0

; ============================================================
; CapsLock 输入法 / 大写状态机
;
; - 短按 CapsLock：切换中英文。
; - 长按达到 500ms：立即进入英文大写，不等待松键。
; - 大写模式下再次按 CapsLock：立即退出，并优先恢复进入前的 IME 状态。
; - CapsLock 作为 Leader 时，由路由层先调用 MarkCapsChordUsed()。
;
; 本文件只实现功能，不读取 Shortcuts，也不注册热键。
; ============================================================

class CapsLockIme {
    static HoldThreshold := 500
    static TipDuration := 1200
    static MessageTimeout := 80
    static RestoreImeAfterCaps := true

    static _pressed := false
    static _chordUsed := false
    static _longPressTriggered := false
    static _imeBeforeCaps := "unknown"

    static WM_IME_CONTROL := 0x0283
    static IMC_GETOPENSTATUS := 0x0005
    static IMC_SETOPENSTATUS := 0x0006
    static SMTO_ABORTIFHUNG := 0x0002
    static LANG_CHINESE := 0x04

    ; CapsLock key-down 入口。保留 receiverProbe 供测试验证绑定对象。
    static Handle(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        this.OnKeyDown()
    }

    static HandleKeyUp(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        this.OnKeyUp()
    }

    static OnKeyDown() {
        ; 过滤按住 CapsLock 时产生的键盘自动重复。
        if this._pressed
            return

        this._pressed := true
        this._chordUsed := false
        this._longPressTriggered := false

        ; 大写已开启时，再按 CapsLock 立即退出，不参与短按/长按判断。
        if GetKeyState("CapsLock", "T") {
            this._longPressTriggered := true
            this.ExitCapsMode()
            return
        }

        SetTimer this.LongPressCallback, 0
        SetTimer this.LongPressCallback, -this.HoldThreshold
    }

    static OnKeyUp() {
        if !this._pressed
            return

        this._pressed := false
        SetTimer this.LongPressCallback, 0

        shouldToggleIme := !this._chordUsed && !this._longPressTriggered

        this._chordUsed := false
        this._longPressTriggered := false

        if shouldToggleIme {
            this.ToggleIme()
            this.ShowTip("已切换中英文")
        }
    }

    ; 500ms 到点时由 Timer 调用，因此不会等待 CapsLock 松开。
    static HandleLongPress(*) {
        if (
            !this._pressed
            || this._chordUsed
            || this._longPressTriggered
            || !GetKeyState("CapsLock", "P")
        )
            return

        this._longPressTriggered := true
        this.EnterCapsMode()
    }

    ; Router 在执行 CapsLock & key 功能前调用。
    static MarkChordUsed() {
        ; 正常情况下 key-down 已先执行；物理状态兜底可处理极端线程顺序。
        if !this._pressed && GetKeyState("CapsLock", "P")
            this._pressed := true

        if !this._pressed
            return false

        this._chordUsed := true
        SetTimer this.LongPressCallback, 0
        return true
    }

    static EnterCapsMode() {
        this._imeBeforeCaps := this.GetCurrentImeState()

        ; 大写输入必须使用英文；直接 API 失败时 SetImeState 会做受控回退。
        this.SetImeState("english")
        SetCapsLockState "On"
        this.ShowTip("已开启大写")
    }

    static ExitCapsMode() {
        SetCapsLockState "Off"

        desiredState := (
            this.RestoreImeAfterCaps
            && this._imeBeforeCaps != "unknown"
        ) ? this._imeBeforeCaps : "english"

        restored := this.SetImeState(desiredState)

        ; 恢复中文失败时，至少尽力回到英文，避免退出大写后落入未知状态。
        if !restored && desiredState != "english" {
            desiredState := "english"
            restored := this.SetImeState("english")
        }

        if (desiredState = "chinese" && restored)
            this.ShowTip("已关闭大写，恢复中文")
        else if (desiredState = "english" && restored)
            this.ShowTip("已关闭大写，恢复英文")
        else
            this.ShowTip("已关闭大写，已尝试切换英文")

        this._imeBeforeCaps := "unknown"
    }

    static ToggleIme() {
        ; 保留 Microsoft 拼音最自然的 Shift 中英文切换手感。
        Send "{Shift}"
    }

    ; 返回 "chinese"、"english" 或 "unknown"。
    static GetCurrentImeState(hwnd := 0) {
        if !hwnd
            hwnd := this.GetFocusedControlHwnd()
        if !hwnd
            return "unknown"

        if !this.IsChineseKeyboardLayout(hwnd)
            return "english"

        state := this.GetImeStateByImm32(hwnd)
        if (state != "unknown")
            return state

        return this.GetImeStateByWindow(hwnd)
    }

    static SetImeState(desiredState, hwnd := 0) {
        if (desiredState != "chinese" && desiredState != "english")
            throw ValueError("不支持的输入法状态：" desiredState)

        if !hwnd
            hwnd := this.GetFocusedControlHwnd()
        if !hwnd
            return false

        currentState := this.GetCurrentImeState(hwnd)
        if (currentState = desiredState)
            return true

        openIme := desiredState = "chinese"

        if this.SetImeByImm32(hwnd, openIme) {
            Sleep 10
            if (this.GetCurrentImeState(hwnd) = desiredState)
                return true
        }

        if this.SetImeByWindow(hwnd, openIme) {
            Sleep 10
            if (this.GetCurrentImeState(hwnd) = desiredState)
                return true
        }

        ; 仅在已知当前状态与目标相反时发送 Shift，避免 unknown 时反向切换。
        currentState := this.GetCurrentImeState(hwnd)
        if (currentState != "unknown" && currentState != desiredState) {
            Send "{Shift}"
            Sleep 20
            return this.GetCurrentImeState(hwnd) = desiredState
        }

        return false
    }

    static GetImeStateByImm32(hwnd) {
        inputContext := 0
        try {
            inputContext := DllCall(
                "Imm32\ImmGetContext",
                "Ptr", hwnd,
                "Ptr"
            )
            if !inputContext
                return "unknown"

            isOpen := DllCall(
                "Imm32\ImmGetOpenStatus",
                "Ptr", inputContext,
                "Int"
            )
            return isOpen ? "chinese" : "english"
        } catch {
            return "unknown"
        } finally {
            if inputContext {
                try DllCall(
                    "Imm32\ImmReleaseContext",
                    "Ptr", hwnd,
                    "Ptr", inputContext,
                    "Int"
                )
            }
        }
    }

    static SetImeByImm32(hwnd, openIme) {
        inputContext := 0
        try {
            inputContext := DllCall(
                "Imm32\ImmGetContext",
                "Ptr", hwnd,
                "Ptr"
            )
            if !inputContext
                return false

            return !!DllCall(
                "Imm32\ImmSetOpenStatus",
                "Ptr", inputContext,
                "Int", openIme,
                "Int"
            )
        } catch {
            return false
        } finally {
            if inputContext {
                try DllCall(
                    "Imm32\ImmReleaseContext",
                    "Ptr", hwnd,
                    "Ptr", inputContext,
                    "Int"
                )
            }
        }
    }

    static GetImeStateByWindow(hwnd) {
        try {
            imeHwnd := DllCall(
                "Imm32\ImmGetDefaultIMEWnd",
                "Ptr", hwnd,
                "Ptr"
            )
            if !imeHwnd
                return "unknown"

            result := 0
            succeeded := DllCall(
                "User32\SendMessageTimeoutW",
                "Ptr", imeHwnd,
                "UInt", this.WM_IME_CONTROL,
                "Ptr", this.IMC_GETOPENSTATUS,
                "Ptr", 0,
                "UInt", this.SMTO_ABORTIFHUNG,
                "UInt", this.MessageTimeout,
                "UPtr*", &result,
                "Ptr"
            )
            if !succeeded
                return "unknown"

            return result ? "chinese" : "english"
        } catch {
            return "unknown"
        }
    }

    static SetImeByWindow(hwnd, openIme) {
        try {
            imeHwnd := DllCall(
                "Imm32\ImmGetDefaultIMEWnd",
                "Ptr", hwnd,
                "Ptr"
            )
            if !imeHwnd
                return false

            result := 0
            succeeded := DllCall(
                "User32\SendMessageTimeoutW",
                "Ptr", imeHwnd,
                "UInt", this.WM_IME_CONTROL,
                "Ptr", this.IMC_SETOPENSTATUS,
                "Ptr", openIme ? 1 : 0,
                "UInt", this.SMTO_ABORTIFHUNG,
                "UInt", this.MessageTimeout,
                "UPtr*", &result,
                "Ptr"
            )
            return !!succeeded
        } catch {
            return false
        }
    }

    static IsChineseKeyboardLayout(hwnd) {
        try {
            processId := 0
            threadId := DllCall(
                "User32\GetWindowThreadProcessId",
                "Ptr", hwnd,
                "UInt*", &processId,
                "UInt"
            )
            if !threadId
                return false

            keyboardLayout := DllCall(
                "User32\GetKeyboardLayout",
                "UInt", threadId,
                "Ptr"
            )
            if !keyboardLayout
                return false

            languageId := keyboardLayout & 0xFFFF
            return (languageId & 0x03FF) = this.LANG_CHINESE
        } catch {
            return false
        }
    }

    static GetFocusedControlHwnd() {
        activeHwnd := WinExist("A")
        if !activeHwnd
            return 0

        try {
            processId := 0
            threadId := DllCall(
                "User32\GetWindowThreadProcessId",
                "Ptr", activeHwnd,
                "UInt*", &processId,
                "UInt"
            )
            if !threadId
                return activeHwnd

            guiInfo := Buffer(8 + (6 * A_PtrSize) + 16, 0)
            NumPut("UInt", guiInfo.Size, guiInfo, 0)

            succeeded := DllCall(
                "User32\GetGUIThreadInfo",
                "UInt", threadId,
                "Ptr", guiInfo.Ptr,
                "Int"
            )
            if !succeeded
                return activeHwnd

            focusedHwnd := NumGet(guiInfo, 8 + A_PtrSize, "Ptr")
            return focusedHwnd ? focusedHwnd : activeHwnd
        } catch {
            return activeHwnd
        }
    }

    static ShowTip(message) {
        ToolTip message
        SetTimer this.HideTipCallback, 0
        SetTimer this.HideTipCallback, -this.TipDuration
    }

    static HideTip() {
        ToolTip
    }
}

; 给 Router 或其他统一接线模块使用的稳定公共接口。
MarkCapsChordUsed(*) {
    return CapsLockIme.MarkChordUsed()
}

CapsLockIme.HotkeyCallback := ObjBindMethod(CapsLockIme, "Handle")
CapsLockIme.KeyUpCallback := ObjBindMethod(CapsLockIme, "HandleKeyUp")
CapsLockIme.LongPressCallback := ObjBindMethod(CapsLockIme, "HandleLongPress")
CapsLockIme.HideTipCallback := ObjBindMethod(CapsLockIme, "HideTip")
