#Requires AutoHotkey v2.0

; ============================================================
; ThinkPad 键盘背光自动管理 (Smart Input Polling 架构)
;
; 设计原理：
;   1. 仅在 ThinkPad 且存在 \\.\IBMPmDrv 驱动时激活，非 ThinkPad 设备零负担安全跳过。
;   2. 彻底抛弃易被 Windows 11 静默卸载的底层低级鼠标钩子 (WH_MOUSE_LL)，
;      改用 Windows 内核级 GetLastInputInfo + GetCursorPos + GetAsyncKeyState 协同采样。
;   3. 精准区分「纯鼠标指针晃动」与「按键/点击/滚轮」：
;      - 纯移动鼠标：光标坐标改变但未按下按键 -> 判定为纯移动，直接丢弃，不重置倒计时、不唤醒背光；
;      - 敲击键盘：产生输入且光标不移动 -> 判定为真实输入，立即唤醒；
;      - 鼠标点击：任意按键按下（即使拖拽移动）-> 判定为真实输入，立即唤醒；
;      - 鼠标滚轮：产生输入且光标不移动 -> 判定为真实输入，立即唤醒。
;   4. 毫秒级极速唤醒，零感知延迟；闲置达到设定秒数准时熄灭；绝不干扰 CapsLock 与输入法。
; ============================================================
class ThinkPadBacklight {
    static Enabled := false
    static LightLevel := 0
    static DarkLevel := 1
    static IdleTimeoutSeconds := 30
    static WakeOnMouseClick := true

    static LastRawInputTime := 0
    static LastCursorX := 0
    static LastCursorY := 0
    static LastGenuineActivityTick := 0
    static CurrentLevel := -1
    static TickCallback := 0
    static IsActive := false
    static PollMs := 80
    static SyncCounter := 0

    static __New() {
        if !IsSet(IsToolboxTestMode) || !IsToolboxTestMode()
            SetTimer(ObjBindMethod(this, "Start"), -1)
    }

    static Start() {
        if !this.Init()
            return false

        this.TickCallback := ObjBindMethod(this, "Poll")
        SetTimer(this.TickCallback, this.PollMs)
        this.IsActive := true
        return true
    }

    static Init() {
        if !this.IsThinkPad()
            return false

        this.LoadConfig()
        if !this.Enabled
            return false

        cur := this.GetBacklight()
        if (cur < 0)
            return false

        this.CurrentLevel := cur
        this.LastRawInputTime := this.GetRawInputTime()
        this.GetCursorPos(&x, &y)
        this.LastCursorX := x
        this.LastCursorY := y
        this.LastGenuineActivityTick := A_TickCount
        return true
    }

    static IsThinkPad() {
        try {
            vendor := RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemManufacturer", "") " "
                   . RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "BaseBoardManufacturer", "") " "
                   . RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "BIOSVendor", "")
            product := RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemFamily", "") " "
                    . RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemProductName", "") " "
                    . RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemVersion", "")
            return InStr(vendor, "LENOVO") && InStr(product, "ThinkPad")
        }
        return false
    }

    static LoadConfig() {
        this.Enabled := true
        this.LightLevel := 0
        this.DarkLevel := 1
        this.IdleTimeoutSeconds := 30
        this.WakeOnMouseClick := true

        cfgPath := ""
        for candidate in [
            A_ScriptDir "\tools\theme-scheduler\config.toml",
            A_ScriptDir "\..\tools\theme-scheduler\config.toml",
            A_ScriptDir "\..\..\tools\theme-scheduler\config.toml"
        ] {
            if FileExist(candidate) {
                cfgPath := candidate
                break
            }
        }
        if !cfgPath
            return

        try {
            content := FileRead(cfgPath, "UTF-8")
            inKbSection := false
            loop parse content, "`n", "`r" {
                line := Trim(A_LoopField)
                if !line || SubStr(line, 1, 1) = "#"
                    continue
                if RegExMatch(line, "^\[([a-zA-Z0-9_\-]+)\]$", &m) {
                    inKbSection := (m[1] = "keyboard_backlight")
                    continue
                }
                if inKbSection && RegExMatch(line, "^([a-zA-Z0-9_\-]+)\s*=\s*(.+)$", &m) {
                    key := m[1]
                    valStr := Trim(RegExReplace(m[2], "\s*#.*$"))
                    if key = "enabled"
                        this.Enabled := (valStr = "true")
                    else if key = "light_level"
                        this.LightLevel := Integer(valStr)
                    else if key = "dark_level"
                        this.DarkLevel := Integer(valStr)
                    else if key = "idle_timeout_seconds"
                        this.IdleTimeoutSeconds := Integer(valStr)
                    else if key = "wake_on_mouse_click"
                        this.WakeOnMouseClick := (valStr = "true")
                }
            }
        } catch {
        }
    }

    static IsDarkMode() {
        try {
            appsLight := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1)
            return (appsLight = 0)
        }
        return false
    }

    static GetRawInputTime() {
        buf := Buffer(8, 0)
        NumPut("UInt", 8, buf, 0)
        DllCall("GetLastInputInfo", "Ptr", buf)
        return NumGet(buf, 4, "UInt")
    }

    static GetCursorPos(&x, &y) {
        pt := Buffer(8, 0)
        DllCall("GetCursorPos", "Ptr", pt)
        x := NumGet(pt, 0, "Int")
        y := NumGet(pt, 4, "Int")
    }

    static IsMouseButtonDown() {
        ; 检测物理鼠标按键是否按下 (左键, 右键, 中键, 侧键1, 侧键2)
        return (DllCall("GetAsyncKeyState", "Int", 1, "Short") & 0x8000)
            || (DllCall("GetAsyncKeyState", "Int", 2, "Short") & 0x8000)
            || (DllCall("GetAsyncKeyState", "Int", 4, "Short") & 0x8000)
            || (DllCall("GetAsyncKeyState", "Int", 5, "Short") & 0x8000)
            || (DllCall("GetAsyncKeyState", "Int", 6, "Short") & 0x8000)
    }

    static Poll() {
        this.SyncCounter++

        ; 浅色模式：强制保持背光关闭
        if !this.IsDarkMode() {
            if (this.CurrentLevel != this.LightLevel) {
                if this.SetBacklight(this.LightLevel)
                    this.CurrentLevel := this.LightLevel
            }
            return
        }

        ; 深色模式常亮配置 (idle_timeout_seconds <= 0)
        if (this.IdleTimeoutSeconds <= 0) {
            if (this.CurrentLevel != this.DarkLevel) {
                if this.SetBacklight(this.DarkLevel)
                    this.CurrentLevel := this.DarkLevel
            }
            return
        }

        ; 采集当前系统级最后输入时间戳与光标位置
        rawInput := this.GetRawInputTime()
        curX := 0
        curY := 0
        this.GetCursorPos(&curX, &curY)

        cursorMoved := (curX != this.LastCursorX || curY != this.LastCursorY)
        btnDown := this.WakeOnMouseClick && this.IsMouseButtonDown()

        if (rawInput != this.LastRawInputTime) {
            this.LastRawInputTime := rawInput

            ; 核心过滤逻辑：
            ; 如果光标没有位移，或者是按下了鼠标按键，代表真实有效的人为交互（打字、点击、滚轮滚屏）；
            ; 若光标移动但没有按键，属于纯鼠标晃动，不更新活跃时间戳。
            if (!cursorMoved || btnDown) {
                this.LastGenuineActivityTick := A_TickCount

                ; 熄灭状态下立即唤醒，最快 0ms，最迟不超过 80ms，瞬间点亮
                if (this.CurrentLevel != this.DarkLevel) {
                    if this.SetBacklight(this.DarkLevel)
                        this.CurrentLevel := this.DarkLevel
                }
            }
        } else if btnDown {
            ; 持续按住鼠标按键（如长拖拽、圈选）
            this.LastGenuineActivityTick := A_TickCount
        }

        this.LastCursorX := curX
        this.LastCursorY := curY

        ; 倒计时判定
        idleElapsedMs := A_TickCount - this.LastGenuineActivityTick
        timeoutMs := this.IdleTimeoutSeconds * 1000

        if (idleElapsedMs >= timeoutMs) {
            ; 超过设定超时 -> 熄灭
            if (this.CurrentLevel != 0) {
                if this.SetBacklight(0)
                    this.CurrentLevel := 0
            }
        } else {
            ; 处于活跃期 -> 确保点亮
            if (this.CurrentLevel != this.DarkLevel) {
                if this.SetBacklight(this.DarkLevel)
                    this.CurrentLevel := this.DarkLevel
            }
        }

        ; 每 25 次采样 (~2 秒) 同步一次硬件物理状态，防止因待机睡眠或手动 Fn+Space 导致的脱节
        if (Mod(this.SyncCounter, 25) = 0) {
            hw := this.GetBacklight()
            if (hw >= 0)
                this.CurrentLevel := hw
        }
    }

    static GetBacklight() {
        h := DllCall("CreateFileW", "Str", "\\.\IBMPmDrv", "UInt", 0xC0000000, "UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
        if (h = -1 || h = 0)
            return -1

        inBuf := Buffer(4, 0)
        outBuf := Buffer(4, 0)
        bytesRet := 0
        ok := DllCall("DeviceIoControl", "Ptr", h, "UInt", 0x00222680, "Ptr", inBuf, "UInt", 4, "Ptr", outBuf, "UInt", 4, "UInt*", &bytesRet, "Ptr", 0)
        DllCall("CloseHandle", "Ptr", h)
        if (!ok || bytesRet < 4)
            return -2
        code := NumGet(outBuf, 0, "Int")
        if ((code & 0x00200000) = 0)
            return -3
        return code & 0xF
    }

    static SetBacklight(targetLevel) {
        if (targetLevel < 0 || targetLevel > 2)
            return false

        h := DllCall("CreateFileW", "Str", "\\.\IBMPmDrv", "UInt", 0xC0000000, "UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
        if (h = -1 || h = 0)
            return false

        inBuf := Buffer(4, 0)
        outBuf := Buffer(4, 0)
        bytesRet := 0
        ok := DllCall("DeviceIoControl", "Ptr", h, "UInt", 0x00222680, "Ptr", inBuf, "UInt", 4, "Ptr", outBuf, "UInt", 4, "UInt*", &bytesRet, "Ptr", 0)
        if (!ok || bytesRet < 4) {
            DllCall("CloseHandle", "Ptr", h)
            return false
        }
        code := NumGet(outBuf, 0, "Int")
        if ((code & 0x00200000) = 0) {
            DllCall("CloseHandle", "Ptr", h)
            return false
        }
        curLevel := code & 0xF
        if (curLevel = targetLevel) {
            DllCall("CloseHandle", "Ptr", h)
            return true
        }

        arg := 0x00000100 | (code & 0xF0) | (targetLevel & 0xF)
        writeIn := Buffer(4, 0)
        NumPut("Int", arg, writeIn, 0)
        writeOut := Buffer(4, 0)
        writeOk := DllCall("DeviceIoControl", "Ptr", h, "UInt", 0x00222684, "Ptr", writeIn, "UInt", 4, "Ptr", writeOut, "UInt", 4, "UInt*", &bytesRet, "Ptr", 0)
        DllCall("CloseHandle", "Ptr", h)
        return writeOk
    }
}
