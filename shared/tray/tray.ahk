#Requires AutoHotkey v2.0

; ============================================================
; 多托盘图标宿主
;
; 为什么需要它：AutoHotkey 一个脚本只有【一个】原生托盘图标
; （TraySetIcon / A_TrayMenu 都只作用于那一个），没有多图标 API。
; 但托盘图标本质上只是 Shell_NotifyIcon 的一条注册记录，任何窗口都能注册多条，
; 只要 uID 不同。所以这里用一个隐藏窗口作宿主，手工注册任意多个图标。
;
; 用法：
;   TrayHost.Init()
;   TrayHost.Add("caffeine", A_ScriptDir "\..\resources\icons\coffee_power_black.ico", "Caffeine 开")
;   TrayHost.SetTip("caffeine", "新提示")
;   TrayHost.Remove("caffeine")
;
; 注意：x64 下 NOTIFYICONDATAW 是 976 字节，cbSize 填错 API 会静默失败。
; ============================================================

class TrayHost {
    static WM_TRAYICON := 0x8000 + 44          ; WM_APP + 44
    static NIM_ADD := 0
    static NIM_MODIFY := 1
    static NIM_DELETE := 2
    static NIF_MESSAGE := 0x01
    static NIF_ICON := 0x02
    static NIF_TIP := 0x04
    static NID_SIZE := 976                     ; x64 NOTIFYICONDATAW
    static WM_LBUTTONUP := 0x202
    static WM_RBUTTONUP := 0x205
    static WM_LBUTTONDBLCLK := 0x203

    static Items := Map()                      ; id -> {uid, hIcon, path, tip, onClick}
    static Gui := 0
    static Hwnd := 0
    static Inited := false
    static NextUid := 1
    static TaskbarCreatedMsg := 0
    static SendIconOverride := 0  ; isolated test seam

    ; ---------------- 初始化 ----------------
    static Init() {
        if this.Inited
            return

        g := Gui("-Caption +ToolWindow")
        try g.Show("Hide w1 h1")
        catch
            g.Show()

        this.Gui := g
        this.Hwnd := g.Hwnd
        if (!this.Hwnd)
            throw Error("TrayHost: 无法创建宿主窗口")

        this.TaskbarCreatedMsg := DllCall("user32\RegisterWindowMessageW", "Str", "TaskbarCreated", "UInt")
        OnMessage(this.WM_TRAYICON, ObjBindMethod(this, "OnTrayMessage"))
        OnMessage(this.TaskbarCreatedMsg, ObjBindMethod(this, "OnTaskbarCreated"))
        OnExit(ObjBindMethod(this, "Shutdown"))
        this.Inited := true
    }

    ; ---------------- 新增 ----------------
    static Add(id, iconPath, tip := "", onClick := 0) {
        this.Init()

        if (this.Items.Has(id))
            this.Remove(id)

        hIcon := this.LoadIcon(iconPath)
        if (!hIcon) {
            this.Log("LoadIcon 失败: " iconPath)
            return false
        }

        uid := this.NextUid++
        ok := this.SendIcon(this.NIM_ADD, uid, hIcon, tip)
        if (!ok) {
            DllCall("user32\DestroyIcon", "Ptr", hIcon)
            this.Log("NIM_ADD 失败 (uid=" uid ")")
            return false
        }

        this.Items[id] := { uid: uid, hIcon: hIcon, path: iconPath, tip: tip, onClick: onClick }
        return true
    }

    ; ---------------- 换图标 ----------------
    static SetIcon(id, iconPath) {
        if (!this.Items.Has(id))
            return this.Add(id, iconPath, "", 0)

        it := this.Items[id]
        if (it.path = iconPath)
            return true

        hNew := this.LoadIcon(iconPath)
        if (!hNew) {
            this.Log("SetIcon LoadIcon 失败: " iconPath)
            return false
        }

        if (!this.SendIcon(this.NIM_MODIFY, it.uid, hNew, it.tip)) {
            DllCall("user32\DestroyIcon", "Ptr", hNew)
            this.Log("NIM_MODIFY 失败 (uid=" it.uid ")")
            return false
        }

        old := it.hIcon
        it.hIcon := hNew
        it.path := iconPath
        if (old)
            DllCall("user32\DestroyIcon", "Ptr", old)
        return true
    }

    ; ---------------- 改提示 ----------------
    static SetTip(id, tip) {
        if (!this.Items.Has(id))
            return false
        it := this.Items[id]
        if (!this.SendIcon(this.NIM_MODIFY, it.uid, it.hIcon, tip))
            return false
        it.tip := tip
        return true
    }

    ; ---------------- 移除 ----------------
    static Remove(id) {
        if (!this.Items.Has(id))
            return false

        it := this.Items[id]
        nid := this.MakeNid(it.uid, 0, 0)
        DllCall("shell32\Shell_NotifyIconW", "UInt", this.NIM_DELETE, "Ptr", nid, "Int")

        if (it.hIcon)
            DllCall("user32\DestroyIcon", "Ptr", it.hIcon)
        this.Items.Delete(id)
        return true
    }

    ; ---------------- 全部移除（退出时）----------------
    static Shutdown(*) {
        try {
            for id in this.Items.Clone() {
                this.Remove(id)
            }
        }
    }

    ; ---------------- explorer 重启后重建 ----------------
    static OnTaskbarCreated(*) {
        for id, it in this.Items {
            this.SendIcon(this.NIM_ADD, it.uid, it.hIcon, it.tip)
        }
        return 0
    }

    ; ---------------- 鼠标回调 ----------------
    static OnTrayMessage(uid, lParam, msg, hwnd) {
        ev := lParam & 0xFFFF
        if (ev = this.WM_LBUTTONUP || ev = this.WM_LBUTTONDBLCLK || ev = this.WM_RBUTTONUP) {
            for id, it in this.Items {
                if (it.uid != uid)
                    continue
                if (ev = this.WM_RBUTTONUP)
                    return 0
                cb := it.onClick
                if (cb)
                    cb.Call()
                return 0
            }
        }
        return 0
    }

    ; ---------------- 内部工具 ----------------
    static LoadIcon(path) {
        if (!FileExist(path))
            return 0
        cx := DllCall("user32\GetSystemMetrics", "Int", 49, "Int")   ; SM_CXSMICON
        cy := DllCall("user32\GetSystemMetrics", "Int", 50, "Int")   ; SM_CYSMICON
        return DllCall("user32\LoadImageW", "Ptr", 0, "Str", path, "UInt", 1,
                       "Int", cx, "Int", cy, "UInt", 0x10, "Ptr")   ; IMAGE_ICON, LR_LOADFROMFILE
    }

    static MakeNid(uid, hIcon, tip) {
        nid := Buffer(this.NID_SIZE, 0)
        NumPut("UInt", this.NID_SIZE, nid, 0)              ; cbSize
        NumPut("Ptr", this.Hwnd, nid, 8)                   ; hWnd
        NumPut("UInt", uid, nid, 16)                       ; uID
        flags := this.NIF_MESSAGE | (hIcon ? this.NIF_ICON : 0) | (tip != "" ? this.NIF_TIP : 0)
        NumPut("UInt", flags, nid, 20)                     ; uFlags
        NumPut("UInt", this.WM_TRAYICON, nid, 24)          ; uCallbackMessage
        NumPut("Ptr", hIcon, nid, 32)                      ; hIcon
        if (tip != "")
            StrPut(tip, nid.Ptr + 40, 128, "UTF-16")       ; szTip[128]
        return nid
    }

    static SendIcon(action, uid, hIcon, tip) {
        if (this.SendIconOverride)
            return this.SendIconOverride.Call(action, uid, hIcon, tip)
        nid := this.MakeNid(uid, hIcon, tip)
        return DllCall("shell32\Shell_NotifyIconW", "UInt", action, "Ptr", nid, "Int") != 0
    }

    static Log(msg) {
        try {
            p := EnvGet("TEMP") "\lat3ncy-tray.log"
            FileAppend Format("[{1}] {2}`n", A_Now, msg), p, "UTF-8"
        }
    }
}
