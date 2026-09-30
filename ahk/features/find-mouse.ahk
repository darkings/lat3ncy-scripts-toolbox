#Requires AutoHotkey v2.0

; macOS「摇一下指针变大」的 Windows 版。
; 低级鼠标钩子在这台机器上会被静默卸掉，所以这里轮询光标位置。
; 换尺寸交给常驻、DPI 感知的 C# 辅助进程，避免每次摇动都启动 PowerShell。
; cursor-size.ps1 只改 Arrow 且使用另一套命名管道，已不再被调用。
class FindMouse {
    static Enabled := true
    static ReverseCount := 3
    static MinDistance := 48
    static MaxIntervalMs := 450
    static HoldMs := 1400
    static SampleMinPx := 2
    static AxisRatio := 2
    static PollMs := 16
    static Hook := 0
    static HookProc := 0
    static ExitBound := 0
    static StartCallback := 0
    static PollCallback := 0
    static EnlargeCallback := 0
    static HelperPid := 0
    static WinsockReady := false
    static Enlarged := false
    static EnlargePending := false
    static HasAnchor := false
    static LastX := 0
    static LastY := 0
    static Travel := 0
    static Direction := 0
    static ReverseStreak := 0
    static LastReverseTick := 0
    static RestoreCallback := 0
    static StatusCallback := 0
    static HookMoves := 0
    static LastError := 0
    static LastTriggerTick := 0
    static LastSizerResult := "idle"
    static StatusPath := A_Temp "\lat3ncy-find-mouse-status.txt"

    static __New() {
        this.RestoreCallback := ObjBindMethod(this, "Restore")
        this.StartCallback := ObjBindMethod(this, "Start")
        this.PollCallback := ObjBindMethod(this, "Poll")
        this.EnlargeCallback := ObjBindMethod(this, "Enlarge")
        this.StatusCallback := ObjBindMethod(this, "WriteStatus")
        if !IsSet(IsToolboxTestMode) || !IsToolboxTestMode()
            SetTimer(this.StartCallback, -1)
    }

    static Start(*) {
        SetTimer(this.StartCallback, 0)
        if !this.Enabled || this.Hook
            return false
        this.Hook := 1
        this.LastError := 0
        if !this.ExitBound {
            this.ExitBound := ObjBindMethod(this, "OnExit")
            OnExit(this.ExitBound)
        }
        SetTimer(this.PollCallback, this.PollMs)
        SetTimer(this.StatusCallback, 1000)
        this.WriteStatus()
        return true
    }

    static Stop() {
        SetTimer(this.StartCallback, 0)
        SetTimer(this.PollCallback, 0)
        SetTimer(this.EnlargeCallback, 0)
        SetTimer(this.RestoreCallback, 0)
        SetTimer(this.StatusCallback, 0)
        this.EnlargePending := false
        this.Hook := 0
        if this.Enlarged
            this.SendSizer("rest")
        this.SendSizer("stop")
        this.Enlarged := false
        this.WriteStatus()
    }

    static OnExit(*) {
        this.Stop()
    }

    static ResetMotion() {
        this.HasAnchor := false
        this.LastX := 0
        this.LastY := 0
        this.Travel := 0
        this.Direction := 0
        this.ReverseStreak := 0
        this.LastReverseTick := 0
    }

    ; 只认同一轴上的连续反向。拐弯时的垂直抖动不能把正在累计的一段清掉。
    static Observe(x, y, tick) {
        if !this.HasAnchor {
            this.HasAnchor := true
            this.LastX := x
            this.LastY := y
            return false
        }

        dx := x - this.LastX
        dy := y - this.LastY
        adx := Abs(dx)
        ady := Abs(dy)
        if (Max(adx, ady) < this.SampleMinPx)
            return false
        this.LastX := x
        this.LastY := y

        axis := 0
        sign := 0
        step := 0
        if (adx >= ady * this.AxisRatio) {
            axis := 1
            sign := dx > 0 ? 1 : -1
            step := adx
        } else if (ady >= adx * this.AxisRatio) {
            axis := 2
            sign := dy > 0 ? 1 : -1
            step := ady
        }
        if !axis
            return false

        direction := axis = 1 ? sign : sign * 2
        if (this.Direction = 0 || direction = this.Direction) {
            if (this.Direction = 0)
                this.Direction := direction
            this.Travel += step
            return false
        }
        if ((this.Direction = 1 || this.Direction = -1) != (axis = 1)) {
            this.Direction := direction
            this.Travel := step
            this.ReverseStreak := 0
            this.LastReverseTick := 0
            return false
        }

        completed := this.Travel
        this.Direction := direction
        this.Travel := step
        if (completed < this.MinDistance) {
            this.ReverseStreak := 0
            this.LastReverseTick := 0
            return false
        }

        gap := this.LastReverseTick ? tick - this.LastReverseTick : 0
        this.LastReverseTick := tick
        if (this.ReverseStreak > 0 && (gap > this.MaxIntervalMs || gap < 0))
            this.ReverseStreak := 0
        this.ReverseStreak += 1
        return this.ReverseStreak >= this.ReverseCount
    }

    static Poll(*) {
        point := Buffer(8, 0)
        if !DllCall("GetCursorPos", "Ptr", point)
            return
        this.HookMoves += 1
        this.HandleMove(NumGet(point, 0, "Int"), NumGet(point, 4, "Int"), A_TickCount)
    }

    static HandleMove(x, y, tick) {
        if this.Enabled && this.Observe(x, y, tick) {
            this.ReverseStreak := 0
            this.LastReverseTick := 0
            this.LastTriggerTick := tick
            this.RequestEnlarge()
        }
    }

    static RequestEnlarge() {
        if this.EnlargePending
            return false
        this.EnlargePending := true
        SetTimer(this.EnlargeCallback, -1)
        return true
    }

    static Enlarge(*) {
        SetTimer(this.EnlargeCallback, 0)
        this.EnlargePending := false
        if this.Enlarged
            return this.ScheduleRestore()
        this.LastSizerResult := this.SendSizer("large")
        if (this.LastSizerResult != "ok") {
            this.WriteStatus()
            return false
        }
        this.Enlarged := true
        this.WriteStatus()
        return this.ScheduleRestore()
    }

    static ScheduleRestore() {
        SetTimer(this.RestoreCallback, 0)
        SetTimer(this.RestoreCallback, -this.HoldMs)
        return true
    }

    static Restore(*) {
        SetTimer(this.RestoreCallback, 0)
        if !this.Enlarged
            return
        this.Enlarged := false
        this.LastSizerResult := this.SendSizer("rest")
        this.WriteStatus()
    }

    static SizerDir() {
        return A_ScriptDir "\features\find-mouse"
    }

    static SizerSource() {
        return this.SizerDir() "\cursor-size.cs"
    }

    static SizerExe() {
        return this.SizerDir() "\cursor-size.exe"
    }

    static EnsureSizerExe() {
        source := this.SizerSource()
        exe := this.SizerExe()
        if !FileExist(source)
            return false
        if FileExist(exe) && FileGetTime(exe, "M") >= FileGetTime(source, "M")
            return true
        compiler := A_WinDir "\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if !FileExist(compiler)
            compiler := A_WinDir "\Microsoft.NET\Framework\v4.0.30319\csc.exe"
        if !FileExist(compiler)
            return false
        command := Format('"{1}" /nologo /optimize+ /out:"{2}" "{3}"', compiler, exe, source)
        try {
            return ProcessNoWindow.RunWait(command) = 0 && FileExist(exe)
        } catch {
            return false
        }
    }

    static EnsureSizer() {
        if (this.HelperPid && ProcessExist(this.HelperPid))
            return true
        if !this.EnsureSizerExe()
            return false
        try {
            this.HelperPid := ProcessNoWindow.Run(Format('"{1}" serve', this.SizerExe()))
        } catch {
            this.HelperPid := 0
            return false
        }
        deadline := A_TickCount + 2000
        while (A_TickCount < deadline) {
            if this.PortOpen()
                return true
            Sleep 20
        }
        return this.PortOpen()
    }

    static EnsureWinsock() {
        if this.WinsockReady
            return true
        data := Buffer(408, 0)
        if DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", data, "Int")
            return false
        this.WinsockReady := true
        return true
    }

    static PortOpen() {
        if !this.EnsureWinsock()
            return false
        socket := DllCall("ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
        if (socket = -1)
            return false
        addr := Buffer(16, 0)
        NumPut("UShort", 2, addr, 0)
        NumPut("UShort", DllCall("ws2_32\htons", "UShort", 47631, "UShort"), addr, 2)
        NumPut("UInt", 0x0100007F, addr, 4)
        ok := DllCall("ws2_32\connect", "Ptr", socket, "Ptr", addr, "Int", 16, "Int") = 0
        DllCall("ws2_32\closesocket", "Ptr", socket)
        return ok
    }

    static SendSizer(command) {
        if !this.EnsureWinsock()
            return "winsock"
        if (command != "stop" && !this.EnsureSizer())
            return "unavailable"
        socket := DllCall("ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
        if (socket = -1)
            return "socket"
        addr := Buffer(16, 0)
        NumPut("UShort", 2, addr, 0)
        NumPut("UShort", DllCall("ws2_32\htons", "UShort", 47631, "UShort"), addr, 2)
        NumPut("UInt", 0x0100007F, addr, 4)
        if DllCall("ws2_32\connect", "Ptr", socket, "Ptr", addr, "Int", 16, "Int") {
            this.LastError := DllCall("ws2_32\WSAGetLastError", "Int")
            DllCall("ws2_32\closesocket", "Ptr", socket)
            return "connect"
        }
        payload := Buffer(StrPut(command "`n", "UTF-8") - 1)
        StrPut(command "`n", payload, "UTF-8")
        if (DllCall("ws2_32\send", "Ptr", socket, "Ptr", payload, "Int", payload.Size, "Int", 0, "Int") <= 0) {
            DllCall("ws2_32\closesocket", "Ptr", socket)
            return "fail"
        }
        reply := Buffer(16, 0)
        read := DllCall("ws2_32\recv", "Ptr", socket, "Ptr", reply, "Int", reply.Size - 1, "Int", 0, "Int")
        DllCall("ws2_32\closesocket", "Ptr", socket)
        if (read <= 0)
            return "empty"
        text := Trim(StrGet(reply, read, "UTF-8"), " `t`r`n")
        if (command = "stop")
            this.HelperPid := 0
        return text = "" ? "empty" : text
    }

    static WriteStatus(*) {
        try {
            content := "Hook=" (this.Hook ? 1 : 0)
                . "`nHookMoves=" this.HookMoves
                . "`nReverseStreak=" this.ReverseStreak
                . "`nTravel=" this.Travel
                . "`nDirection=" this.Direction
                . "`nEnlarged=" (this.Enlarged ? 1 : 0)
                . "`nEnlargePending=" (this.EnlargePending ? 1 : 0)
                . "`nLastError=" this.LastError
                . "`nLastTriggerTick=" this.LastTriggerTick
                . "`nLastSizerResult=" this.LastSizerResult
            temp := this.StatusPath ".tmp"
            try FileDelete(temp)
            FileAppend(content, temp, "UTF-8")
            FileMove(temp, this.StatusPath, true)
        }
    }
}
