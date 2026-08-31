#Requires AutoHotkey v2.0

; ============================================================
; CapsLock 输入法 / 大写状态机
;
; - 短按 CapsLock（≤ TapMaxMs）：切换中英文。
; - 按住超过短按、但未到长按就松开：视为取消组合，不切输入法。
; - 长按达到 HoldThreshold：立即进入英文大写，不等待松键。
; - 大写模式下再次按 CapsLock：立即退出，并优先恢复进入前的 IME 状态。
; - 本次按住期间若已进入大写，再按下组合键：撤回大写，只执行工具。
; - 退出大写的那一次按住，不把同时按下的字母当成工具组合。
; - 组合键松开后短暂锁定输入法切换，避免连带再点一次 Caps。
; - CapsLock 作为 Leader 时，由路由层先调用 MarkCapsChordUsed()。
; - 短按记住最近一次「中/英」。未开「每个窗口不同输入法」时，
;   切窗口会把全局微软拼音打回中文；前台变化后按记忆静默恢复。
;
; 可改开关（只改 class 里这 5 个 static，改完重载 main.ahk）：
;   PersistImeAcrossWindows  false = 关闭跨窗口恢复，只保留短按切换
;   ImeWatchIntervalMs       前台窗口轮询间隔
;   ImeRestoreDelayMs        切窗口后第一次恢复前等待（IME 还没就绪就加大）
;   ImeRestorePollMs         恢复失败后的重试间隔
;   ImeRestoreAttempts       最多尝试次数
;
; 预设（整段替换那 5 行）：
;   关闭     false / 任意 / 任意 / 任意 / 任意
;   默认     true / 100 / 80 / 50 / 4
;   更稳     true / 120 / 150 / 80 / 6   ← 当前
;   更激进   true / 80 / 40 / 30 / 3
;
; 本文件只实现功能，不读取 Shortcuts，也不注册热键。
; ============================================================

class CapsLockIme {
    static HoldThreshold := 500
    static TapMaxMs := 250
    static ChordImeLockoutMs := 180
    static MessageTimeout := 80
    static RestoreImeAfterCaps := true
    ; --- 跨窗口恢复：改这里 ---
    static PersistImeAcrossWindows := true
    static ImeWatchIntervalMs := 120
    static ImeRestoreDelayMs := 150
    static ImeRestorePollMs := 80
    static ImeRestoreAttempts := 6

    static _pressed := false
    static _chordUsed := false
    static _longPressTriggered := false
    static _exitingCaps := false
    static _downTick := 0
    static _imeLockoutUntil := 0
    static _lastReleaseAction := ""
    static _imeBeforeCaps := "unknown"
    static RememberedImeState := "unknown"
    static _lastForegroundHwnd := 0
    static _watcherStarted := false
    static _restoreAttemptsLeft := 0

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
        this._exitingCaps := false
        this._downTick := A_TickCount
        this._lastReleaseAction := ""

        ; 大写已开启时，再按 CapsLock 立即退出，不参与短按/长按判断。
        ; 这一次按住期间的字母不当组合键，避免退出大写时误触发工具。
        if GetKeyState("CapsLock", "T") {
            this._longPressTriggered := true
            this._exitingCaps := true
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

        holdMs := Max(0, A_TickCount - this._downTick)
        shouldToggleIme := (
            !this._chordUsed
            && !this._longPressTriggered
            && !this._exitingCaps
            && holdMs <= this.TapMaxMs
            && A_TickCount >= this._imeLockoutUntil
        )

        this._lastReleaseAction := shouldToggleIme ? "ime" : "idle"
        this._chordUsed := false
        this._longPressTriggered := false
        this._exitingCaps := false
        this._downTick := 0

        if shouldToggleIme {
            newState := this.ToggleIme()
            if (newState = "chinese")
                Notify.State("中", "中")
            else if (newState = "english")
                Notify.State("A", "A")
            else
                Notify.State("↔", "已切换")
        }
    }

    ; 500ms 到点时由 Timer 调用，因此不会等待 CapsLock 松开。
    static HandleLongPress(*) {
        if (
            !this._pressed
            || this._chordUsed
            || this._longPressTriggered
            || this._exitingCaps
            || !GetKeyState("CapsLock", "P")
        )
            return

        this._longPressTriggered := true
        this.EnterCapsMode()
    }

    ; Router 在执行 CapsLock & key 功能前调用。
    static MarkChordUsed() {
        ; 正常情况下 key-down 已先执行；物理状态兜底可处理极端线程顺序。
        if !this._pressed && GetKeyState("CapsLock", "P") {
            this._pressed := true
            this._downTick := A_TickCount
        }

        if !this._pressed
            return false

        ; 退出大写的这一按，不把同时按下的字母当工具组合。
        if this._exitingCaps
            return false

        this._chordUsed := true
        SetTimer this.LongPressCallback, 0
        this._imeLockoutUntil := A_TickCount + this.ChordImeLockoutMs

        ; 犹豫太久才按下字母：长按定时器可能已经进了大写。先撤掉，只执行工具。
        if this._longPressTriggered && GetKeyState("CapsLock", "T")
            this.AbortCapsModeForChord()

        return true
    }

    static AbortCapsModeForChord() {
        SetCapsLockState "Off"

        desiredState := (
            this.RestoreImeAfterCaps
            && this._imeBeforeCaps != "unknown"
        ) ? this._imeBeforeCaps : "english"

        this.SetImeState(desiredState)
        this.RememberImeState(desiredState)
        this._imeBeforeCaps := "unknown"
        this._longPressTriggered := false
    }

    static EnterCapsMode() {
        this._imeBeforeCaps := this.GetCurrentImeState()

        ; 大写输入必须使用英文；直接 API 失败时 SetImeState 会做受控回退。
        this.SetImeState("english")
        SetCapsLockState "On"
        Notify.State("⇪", "⇪")
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
            Notify.State("中", "中")
        else if (desiredState = "english" && restored)
            Notify.State("A", "A")
        else
            Notify.Error("!", "输入法恢复失败")

        if restored
            this.RememberImeState(desiredState)
        this._imeBeforeCaps := "unknown"
    }

    static ToggleIme() {
        ; 先读当前中/英，再设成相反状态。
        ; 不能只靠模拟 Shift：Win11 微软拼音经常吃掉 SendInput 的 Shift，
        ; 而且 40ms 后读到的仍是旧状态，会把英文记成中文，切窗口后又被打回去。
        current := this.GetCurrentImeState()
        if (current = "english")
            desired := "chinese"
        else if (current = "chinese")
            desired := "english"
        else if (this.RememberedImeState = "english")
            desired := "chinese"
        else
            desired := "english"

        if this.SetImeState(desired) {
            this.RememberImeState(desired)
            return desired
        }

        newState := this.GetCurrentImeState()
        this.RememberImeState(newState)
        return newState
    }

    ; 只记住明确的中/英。unknown 不能覆盖，避免误把下次恢复打反。
    static RememberImeState(state) {
        if (state != "chinese" && state != "english")
            return
        this.RememberedImeState := state
        this.EnsureWindowWatcher()
    }

    static EnsureWindowWatcher() {
        if this._watcherStarted || !this.PersistImeAcrossWindows
            return
        ; 只在生产入口 main.ahk 挂监视。契约测试、独立加载 stub
        ; 的 A_ScriptName 都不是 main.ahk；写死调用 IsToolboxTestMode()
        ; 会在独立加载时被当成未赋值变量并弹窗，把 runner 卡死。
        if (A_ScriptName != "main.ahk")
            return
        for arg in A_Args {
            if (arg = "--test")
                return
        }

        this._watcherStarted := true
        this._lastForegroundHwnd := WinExist("A")
        SetTimer this.WindowWatchCallback, this.ImeWatchIntervalMs
    }

    static WatchForeground(*) {
        if !this.PersistImeAcrossWindows
            return
        if this.ShouldSkipImeRestore()
            return
        if (this.RememberedImeState != "chinese" && this.RememberedImeState != "english")
            return

        hwnd := WinExist("A")
        if !hwnd || hwnd = this._lastForegroundHwnd
            return

        this._lastForegroundHwnd := hwnd
        this._restoreAttemptsLeft := this.ImeRestoreAttempts
        SetTimer this.RestoreCallback, -this.ImeRestoreDelayMs
    }

    static RestoreRememberedIme(*) {
        if !this.PersistImeAcrossWindows
            return
        if this.ShouldSkipImeRestore()
            return

        desired := this.RememberedImeState
        if (desired != "chinese" && desired != "english")
            return
        if (this.GetCurrentImeState() = desired)
            return

        ; 静默恢复，不再弹「中/A」。用户已经用 Caps 选过一次。
        this.SetImeState(desired)
        if (this.GetCurrentImeState() = desired)
            return
        if (this._restoreAttemptsLeft <= 1)
            return

        this._restoreAttemptsLeft -= 1
        SetTimer this.RestoreCallback, -this.ImeRestorePollMs
    }

    static ShouldSkipImeRestore() {
        return this._pressed || this._exitingCaps || GetKeyState("CapsLock", "T")
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

        ; 仅在已知当前状态与目标相反时发送左 Shift。
        ; 必须用 SendEvent：微软拼音常常忽略 SendInput 的 Shift。
        currentState := this.GetCurrentImeState(hwnd)
        if (currentState != "unknown" && currentState != desiredState) {
            this.SendImeToggleShift()
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
            if !isOpen
                return "english"

            convMode := 0
            sentMode := 0
            DllCall(
                "Imm32\ImmGetConversionStatus",
                "Ptr", inputContext,
                "UInt*", &convMode,
                "UInt*", &sentMode
            )
            return (convMode & 1) ? "chinese" : "english"
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

    ; 左 Shift 点按。SendEvent 才能进到 IME 消息队列。
    static SendImeToggleShift() {
        SendEvent "{LShift down}"
        Sleep 30
        SendEvent "{LShift up}"
        Sleep 40
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

            ; Win11 微软拼音的中/英首先是 IME 开/关，其次才是 native conversion bit。
            ; 只改 conversion、不 ImmSetOpenStatus，英文经常切不进去。
            DllCall(
                "Imm32\ImmSetOpenStatus",
                "Ptr", inputContext,
                "Int", openIme ? 1 : 0,
                "Int"
            )

            convMode := 0
            sentMode := 0
            DllCall(
                "Imm32\ImmGetConversionStatus",
                "Ptr", inputContext,
                "UInt*", &convMode,
                "UInt*", &sentMode
            )
            newConvMode := openIme ? (convMode | 1) : (convMode & ~1)
            DllCall(
                "Imm32\ImmSetConversionStatus",
                "Ptr", inputContext,
                "UInt", newConvMode,
                "UInt", sentMode
            )
            return true
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

            openStatus := 0
            succeeded := DllCall(
                "User32\SendMessageTimeoutW",
                "Ptr", imeHwnd,
                "UInt", this.WM_IME_CONTROL,
                "Ptr", this.IMC_GETOPENSTATUS,
                "Ptr", 0,
                "UInt", this.SMTO_ABORTIFHUNG,
                "UInt", this.MessageTimeout,
                "UPtr*", &openStatus,
                "Ptr"
            )
            if (!succeeded || !openStatus)
                return succeeded ? "english" : "unknown"

            convMode := 0
            succeeded := DllCall(
                "User32\SendMessageTimeoutW",
                "Ptr", imeHwnd,
                "UInt", this.WM_IME_CONTROL,
                "Ptr", 0x0001, ; IMC_GETCONVERSIONMODE
                "Ptr", 0,
                "UInt", this.SMTO_ABORTIFHUNG,
                "UInt", this.MessageTimeout,
                "UPtr*", &convMode,
                "Ptr"
            )
            if !succeeded
                return "unknown"

            return (convMode & 1) ? "chinese" : "english"
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

            ; IMC_SETOPENSTATUS：关 IME = 英文，开 IME = 中文。
            openResult := 0
            opened := DllCall(
                "User32\SendMessageTimeoutW",
                "Ptr", imeHwnd,
                "UInt", this.WM_IME_CONTROL,
                "Ptr", this.IMC_SETOPENSTATUS,
                "Ptr", openIme ? 1 : 0,
                "UInt", this.SMTO_ABORTIFHUNG,
                "UInt", this.MessageTimeout,
                "UPtr*", &openResult,
                "Ptr"
            )

            convMode := 0
            succeeded := DllCall(
                "User32\SendMessageTimeoutW",
                "Ptr", imeHwnd,
                "UInt", this.WM_IME_CONTROL,
                "Ptr", 0x0001, ; IMC_GETCONVERSIONMODE
                "Ptr", 0,
                "UInt", this.SMTO_ABORTIFHUNG,
                "UInt", this.MessageTimeout,
                "UPtr*", &convMode,
                "Ptr"
            )
            if !succeeded
                return !!opened

            newConvMode := openIme ? (convMode | 1) : (convMode & ~1)
            result := 0
            succeeded := DllCall(
                "User32\SendMessageTimeoutW",
                "Ptr", imeHwnd,
                "UInt", this.WM_IME_CONTROL,
                "Ptr", 0x0002, ; IMC_SETCONVERSIONMODE
                "Ptr", newConvMode,
                "UInt", this.SMTO_ABORTIFHUNG,
                "UInt", this.MessageTimeout,
                "UPtr*", &result,
                "Ptr"
            )
            return !!opened || !!succeeded
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

}

; 给 Router 或其他统一接线模块使用的稳定公共接口。
MarkCapsChordUsed(*) {
    return CapsLockIme.MarkChordUsed()
}

CapsLockIme.HotkeyCallback := ObjBindMethod(CapsLockIme, "Handle")
CapsLockIme.KeyUpCallback := ObjBindMethod(CapsLockIme, "HandleKeyUp")
CapsLockIme.LongPressCallback := ObjBindMethod(CapsLockIme, "HandleLongPress")
CapsLockIme.WindowWatchCallback := ObjBindMethod(CapsLockIme, "WatchForeground")
CapsLockIme.RestoreCallback := ObjBindMethod(CapsLockIme, "RestoreRememberedIme")

