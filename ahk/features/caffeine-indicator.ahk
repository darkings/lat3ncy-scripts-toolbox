#Requires AutoHotkey v2.0

; ============================================================
; Caffeine 状态托盘指示
;
; 需求：只有 Raycast Coffee 扩展激活时才在托盘显示咖啡杯；未激活时彻底移除，
;       不占托盘位、不留幽灵图标。
;
; 判定方式与 tools/power-policy/PowerPolicy.ps1 完全一致：
;   使用 PowerPolicy 配置的目录；校验 PID + FILETIME、到期时间和停止信号。
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
    static ConfigPath := ""
    static PollCallback := 0
    static SettingCallback := 0

    ; ---------------- 生命周期 ----------------
    static Start() {
        if this.Started
            return
        this.Started := true

        this.Poll()
        this.PollCallback := ObjBindMethod(this, "Poll")
        SetTimer(this.PollCallback, this.PollMs)
        ; WM_SETTINGCHANGE：主题/个性化变化后换图标
        this.SettingCallback := ObjBindMethod(this, "OnSettingChange")
        OnMessage(0x001A, this.SettingCallback)
        this.Log("started (active=" (this.Showing ? "1" : "0") ")")
    }

    static Stop() {
        if !this.Started
            return
        SetTimer(this.PollCallback, 0)
        OnMessage(0x001A, this.SettingCallback, 0)
        if this.Showing
            this.Hide()
        this.Showing := false
        this.Started := false
    }

    ; ---------------- 状态判定 ----------------
    static CoffeeDirectory() {
        dir := EnvGet("LOCALAPPDATA") "\coffee"
        path := this.ConfigPath
        if (path = "") {
            SplitPath A_LineFile, , &featureDir
            path := featureDir "\..\..\tools\power-policy\config.toml"
        }
        try {
            section := ""
            for raw in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
                line := Trim(raw)
                if RegExMatch(line, "^\[(.+)\]$", &m)
                    section := m[1]
                else if (section = "caffeine") {
                    if RegExMatch(line, '^coffee_dir\s*=\s*"([^"]*)"\s*(?:#.*)?$', &m)
                        || RegExMatch(line, "^coffee_dir\s*=\s*'([^']*)'\s*(?:#.*)?$", &m)
                        dir := m[1]
                }
            }
        }
        size := DllCall("ExpandEnvironmentStringsW", "WStr", dir, "Ptr", 0, "UInt", 0, "UInt")
        expanded := Buffer(size * 2, 0)
        if !size || !DllCall("ExpandEnvironmentStringsW", "WStr", dir, "Ptr", expanded, "UInt", size, "UInt")
            return dir
        return StrGet(expanded, "UTF-16")
    }

    static StateFile() {
        return this.CoffeeDirectory() "\state.json"
    }

    ; Coffee's state is a flat JSON object of scalar fields. Validate the whole
    ; document before using any field, so a partial write cannot look active.
    static ReadState(text) {
        values := Map()
        text := Trim(text, " `t`r`n" Chr(0xFEFF))
        if (SubStr(text, 1, 1) != "{" || SubStr(text, -1) != "}")
            throw Error("Invalid Coffee state")
        rest := Trim(SubStr(text, 2, -1))
        pattern := '^"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*("(?:[^"\\\x00-\x1F]|\\["\\/bfnrt]|\\u[0-9A-Fa-f]{4})*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)\s*(,|$)'
        while (rest != "") {
            if !RegExMatch(rest, pattern, &m) || values.Has(m[1])
                throw Error("Invalid Coffee state")
            values[m[1]] := Trim(m[2], '"')
            rest := LTrim(SubStr(rest, m.Len + 1))
            if (m[3] = "," && rest = "")
                throw Error("Invalid Coffee state")
        }
        return values
    }

    static ProcessStartTicks(pid) {
        process := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")
        if !process
            return 0
        try {
            created := Buffer(8), exited := Buffer(8), kernel := Buffer(8), user := Buffer(8)
            if !DllCall("GetProcessTimes", "Ptr", process, "Ptr", created, "Ptr", exited, "Ptr", kernel, "Ptr", user)
                return 0
            return NumGet(created, 0, "Int64")
        } finally {
            DllCall("CloseHandle", "Ptr", process)
        }
    }

    static IsActive() {
        try {
            dir := this.CoffeeDirectory()
            if FileExist(dir "\stop.flag") || !FileExist(dir "\state.json")
                return false
            state := this.ReadState(FileRead(dir "\state.json", "UTF-8"))
            pid := Integer(state["pid"])
            started := this.ProcessStartTicks(pid)
            if !started || !ProcessExist(pid) || Abs(started - Integer(state["startTicks"])) > 10000
                return false
            if state.Has("durationSeconds") && state["durationSeconds"] != "null" && Number(state["durationSeconds"]) > 0 {
                now := Buffer(8)
                DllCall("GetSystemTimeAsFileTime", "Ptr", now)
                unixSeconds := (NumGet(now, 0, "Int64") - 116444736000000000) / 10000000
                if unixSeconds >= Number(state["startTime"]) + Number(state["durationSeconds"])
                    return false
            }
            return true
        } catch {
            return false
        }
    }

    ; ---------------- 轮询 ----------------
    static Poll() {
        active := this.IsActive()
        if (active = this.Showing)
            return
        if (active) {
            ok := this.Show()
            this.Showing := ok
            this.Log("show -> " (ok ? "OK" : "FAIL"))
        } else {
            ok := this.Hide()
            this.Showing := false
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
        return "Caffeine 已启用"
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
