#Requires AutoHotkey v2.0

; ============================================================
; Caffeine 状态托盘指示
;
; 需求：只有 Raycast Coffee 扩展激活时才在托盘显示咖啡杯；未激活时彻底移除，
;       不占托盘位、不留幽灵图标。
;
; 判定方式与 tools/power-policy/PowerPolicy.ps1 完全一致：
;   %LOCALAPPDATA%\coffee\state.json 存在，且其中 pid 指向的进程仍存活。
;   （Coffee 扩展 worker 启动时写该文件，停止时删除；pid 校验防 PID 复用误判）
;
; 图标来源 resources/icons：
;   coffee_power_black.ico —— 放浅色任务栏
;   coffee_power_white.ico —— 放深色任务栏
; 主题切换（WM_SETTINGCHANGE / ImmersiveColorSet）时自动换图。
;
; 由 main.ahk 在启动阶段调用 CaffeineIndicator.Start()，本文件不自动启动，
; 以免测试模式（--test）也去注册托盘图标。
; ============================================================

class CaffeineIndicator {
    static IconId := "caffeine"
    static PollMs := 2000
    static Showing := false
    static Started := false

    ; ---------------- 生命周期 ----------------
    static Start() {
        if this.Started
            return
        this.Started := true

        this.Poll()
        SetTimer(ObjBindMethod(this, "Poll"), this.PollMs)
        ; WM_SETTINGCHANGE：主题/个性化变化后换图标
        OnMessage(0x001A, ObjBindMethod(this, "OnSettingChange"))
        this.Log("started (active=" (this.Showing ? "1" : "0") ")")
    }

    static Stop() {
        if !this.Started
            return
        SetTimer(ObjBindMethod(this, "Poll"), 0)
        if this.Showing
            this.Hide()
        this.Started := false
    }

    ; ---------------- 状态判定 ----------------
    static StateFile() {
        return EnvGet("LOCALAPPDATA") "\coffee\state.json"
    }

    static IsActive() {
        f := this.StateFile()
        if !FileExist(f)
            return false
        try {
            txt := FileRead(f, "UTF-8")
        } catch {
            return false
        }
        if !RegExMatch(txt, '"pid"\s*:\s*(\d+)', &m)
            return false
        return ProcessExist(Integer(m[1])) != 0
    }

    ; ---------------- 轮询 ----------------
    static Poll() {
        active := this.IsActive()
        if (active = this.Showing)
            return
        this.Showing := active
        if (active) {
            ok := this.Show()
            this.Log("show -> " (ok ? "OK" : "FAIL"))
        } else {
            ok := this.Hide()
            this.Log("hide -> " (ok ? "OK" : "FAIL"))
        }
    }

    ; ---------------- 显示 / 隐藏 ----------------
    static Show() {
        return TrayHost.Add(this.IconId, this.IconPath(), this.TipText())
    }

    static Hide() {
        return TrayHost.Remove(this.IconId)
    }

    static TipText() {
        return "Caffeine 开 · 合盖不会睡眠"
    }

    ; ---------------- 图标与主题 ----------------
    static IconPath() {
        name := this.TaskbarIsLight() ? "coffee_power_black.ico" : "coffee_power_white.ico"
        ; A_ScriptDir 是 main.ahk 所在目录（ahk\），resources 在仓库根
        return A_ScriptDir "\..\resources\icons\" name
    }

    static TaskbarIsLight() {
        try {
            v := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                         "SystemUsesLightTheme", 1)
            return v = 1
        } catch {
            return true
        }
    }

    static OnSettingChange(wParam, lParam, msg, hwnd) {
        if (!this.Started || !this.Showing)
            return 0
        if (!lParam)
            return 0
        try {
            area := StrGet(lParam, "UTF-16")
        } catch {
            return 0
        }
        if (area = "ImmersiveColorSet") {
            ok := TrayHost.SetIcon(this.IconId, this.IconPath())
            this.Log("theme swap -> " (ok ? "OK" : "FAIL"))
        }
        return 0
    }

    ; ---------------- 诊断 ----------------
    static Log(msg) {
        try {
            p := EnvGet("TEMP") "\lat3ncy-caffeine-tray.log"
            FileAppend Format("[{1}] {2}`n", FormatTime(, "yyyy-MM-dd HH:mm:ss"), msg), p, "UTF-8"
        }
    }
}
