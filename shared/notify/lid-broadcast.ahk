#Requires AutoHotkey v2.0

; ============================================================
; 盖子状态广播（写入 state 文件，供 PowerPolicy 读取）
;
; 为什么需要它：
;   PowerPolicy 用 LIDACTION=0（合盖不操作）来避免系统被显式睡眠指令推进 S0，
;   从而不锁屏。但 LIDACTION=0 时合盖【不产生】Kernel-Power 506/507 事件，
;   PowerPolicy 无法知道自己该不该主动关屏。
;
;   Windows 在盖子开合时一定会广播 PBT_POWERSETTINGCHANGE
;   （GUID_LIDSWITCH_STATE_CHANGE），这与 LIDACTION 取值无关。
;   这里监听该广播，把状态写到 %LOCALAPPDATA%\lat3ncy-toolbox\lid-state.json。
;
; 【2026-11-12 关键修正】之前收不到任何事件，原因是两个常量写错了：
;   GUID_LIDSWITCH_STATE_CHANGE 必须是 BA3E0F4D-B817-4094-A2D1-D56379E6A0F3
;     （曾误写为 BA3E0F7F-B817-4513-89E7-1B7E9F8D7B50）
;   PBT_POWERSETTINGCHANGE     必须是 0x8013
;     （曾误写为 0x8017）
;   CLSIDFromString 与 RegisterPowerSettingNotification 对错误 GUID 都返回成功，
;   所以错误是静默的——注册了不存在的设置，自然永远收不到回调。
;   参考：https://stackoverflow.com/questions/3355606/detect-laptop-lid-closure-and-opening
; ============================================================

class LidStateBroadcast {
    static WM_POWERBROADCAST      := 0x0218
    static PBT_POWERSETTINGCHANGE := 0x8013

    static GUID_LIDSWITCH_STATE_CHANGE := "{BA3E0F4D-B817-4094-A2D1-D56379E6A0F3}"

    static StateFile    := ""
    static GuidBuf      := 0
    static NotifyHandle := 0
    static HostHwnd     := 0
    static Started      := false
    static LastOpen     := ""
    static LastError    := 0
    static EventsSeen   := 0

    static Start() {
        if this.Started
            return

        dir := EnvGet("LOCALAPPDATA") "\lat3ncy-toolbox"
        if !DirExist(dir)
            DirCreate dir
        this.StateFile := dir "\lid-state.json"

        hwnd := this.EnsureHostWindow()
        if !hwnd {
            this.Log("宿主窗口创建失败")
            return
        }

        if !this.Register(hwnd, this.GUID_LIDSWITCH_STATE_CHANGE) {
            this.Log("RegisterPowerSettingNotification 失败 (err=" this.LastError ")")
            return
        }

        OnMessage(this.WM_POWERBROADCAST, ObjBindMethod(this, "OnPowerBroadcast"))
        this.Started := true
        this.Log("started, guid=" this.GUID_LIDSWITCH_STATE_CHANGE
               . ", PBT=0x" Format("{:X}", this.PBT_POWERSETTINGCHANGE)
               . ", notifyHandle=" this.NotifyHandle)
    }

    ; ---------------- 宿主窗口 ----------------
    static EnsureHostWindow() {
        if (this.HostHwnd && DllCall("IsWindow", "Ptr", this.HostHwnd))
            return this.HostHwnd
        g := Gui("-Caption +ToolWindow")
        try g.Show("Hide w1 h1")
        this.HostHwnd := g.Hwnd
        return this.HostHwnd
    }

    ; ---------------- 注册通知 ----------------
    static Register(hwnd, guid) {
        ; GUID 缓冲区存类成员，生命周期覆盖整个消息期
        this.GuidBuf := Buffer(16, 0)
        hr := DllCall("ole32\CLSIDFromString", "Str", guid, "Ptr", this.GuidBuf, "Int")
        if (hr != 0) {
            this.LastError := hr
            return false
        }

        ; DEVICE_NOTIFY_WINDOW_HANDLE = 0
        p := DllCall("RegisterPowerSettingNotification"
                     , "Ptr", hwnd
                     , "Ptr", this.GuidBuf
                     , "UInt", 0
                     , "Ptr")
        this.NotifyHandle := p
        if (p = 0) {
            this.LastError := A_LastError
            return false
        }
        return true
    }

    static Stop() {
        if (this.NotifyHandle) {
            DllCall("UnregisterPowerSettingNotification", "Ptr", this.NotifyHandle)
            this.NotifyHandle := 0
        }
        this.Started := false
    }

    ; ---------------- 收到广播 ----------------
    static OnPowerBroadcast(wParam, lParam, msg, hwnd) {
        if (wParam != this.PBT_POWERSETTINGCHANGE)
            return 0
        if !lParam
            return 0

        this.EventsSeen += 1

        ; POWERBROADCAST_SETTING:
        ;   GUID PowerSetting (16) + DWORD DataLength (4) + BYTE Data[]
        ; 盖子状态为 1 字节：0=关闭 非0=打开
        try {
            if !this.IsLidGuid(lParam)
                return 0

            len := NumGet(lParam, 16, "UInt")
            if (len < 1)
                return 0
            val := NumGet(lParam, 20, "UChar")
            this.WriteState(val != 0, "broadcast")
        } catch as e {
            this.Log("OnPowerBroadcast 异常: " e.Message " @ " e.Line)
        }
        return 0
    }

    static IsLidGuid(lParam) {
        if (!this.GuidBuf)
            return false
        return DllCall("ntdll\RtlCompareMemory"
                       , "Ptr", lParam
                       , "Ptr", this.GuidBuf
                       , "UPtr", 16
                       , "UPtr") = 16
    }

    ; ---------------- 写状态文件 ----------------
    static WriteState(isOpen, source) {
        key := isOpen ? "open" : "closed"
        if (this.LastOpen = key)
            return

        this.LastOpen := key
        json := '{"open":' (isOpen ? "true" : "false")
              . ',"source":"' source '"'
              . ',"ts":"' FormatTime(, "yyyy-MM-dd HH:mm:ss") '"}'

        try {
            f := FileOpen(this.StateFile, "w", "UTF-8")
            if f {
                f.Write(json)
                f.Close()
            }
        } catch as e {
            this.Log("写 state 失败: " e.Message)
        }
        this.Log("state=" key " (" source ")")
    }

    static Log(msg) {
        try {
            p := EnvGet("TEMP") "\lat3ncy-lid-broadcast.log"
            FileAppend Format("[{1}] {2}`n", FormatTime(, "yyyy-MM-dd HH:mm:ss"), msg), p, "UTF-8"
        }
    }
}
