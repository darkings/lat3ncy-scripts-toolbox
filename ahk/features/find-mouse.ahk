#Requires AutoHotkey v2.0

; macOS「摇一下指针变大」的 Windows 版。
; 低级鼠标钩子在这台机器上会被静默卸掉，所以这里轮询光标位置。
; 换尺寸交给常驻、DPI 感知的 C# 辅助进程，避免每次摇动都启动 PowerShell。
; cursor-size.ps1 只改 Arrow 且使用另一套命名管道，已不再被调用。
class FindMouse {
    static Enabled := true
    ; 三次反向（四条腿 ≈ 两个来回）。轴判定修好之后，真摇一次就能稳定攒够；
    ; 日常瞄准的"过头再修正"通常只有一次反向，够不到三次。
    static ReverseCount := 3
    ; 一条腿至少要走这么远才算"在找指针"而不是手抖/瞄准修正。
    static MinDistance := 40
    ; 整个手势窗口的平均速度下限（像素/毫秒），参考 0cch/ShakeToFindCursor：
    ; 速度按整个窗口算，不按单腿算——真摇动在折返点必然减速，一条慢的
    ; 折返腿会把整个连击清零（和"越直线越难触发"同病根）。
    static MinStreakSpeedPxPerMs := 0.5
    ; 三次反向必须在这个总时长内完成，防止慢慢蹭也能攒够次数。
    static MaxStreakMs := 1000
    ; 单条腿的时限：超过就是日常慢速修正，不计反向。
    static LegMaxMs := 320
    static MaxIntervalMs := 400
    ; 超过 IdleResetMs 没有有效位移，丢掉之前攒的连击。真的摇晃是连着来的。
    ; 轮询点稀疏，慢一点的摇动单腿就接近 400ms，太紧会把正常摇动掐在半途。
    static IdleResetMs := 500
    ; 净位移 / 累计腿长 的上限：真摇动绕着自己起点来回，比值很小；
    ; 移到别处顺手抖两下会离起点很远，比值接近 1。这是"随意一晃就放大"的判据。
    ; 0.6 会把"边朝目标漂移边摇"的合法动作（比值 0.4~0.7）一起毙掉，实测
    ; 到了触发线的摇动有 55% 死在这里；0.75 仍能挡住比值≈1 的假摇动。
    static MaxNetRatio := 0.75
    ; 连击期间包围盒任一轴超过该值，视为跨屏正常移动，不触发。
    static MaxSpanPx := 600
    ; 连击峰峰值的下限。手抖、触摸板/小红点漂移、犹豫式微调都是小幅度高频抖动；
    ; 刻意找指针会明显扫过一段距离。这条是"正常使用中时不时变大"的主拦网。
    static MinSpanPx := 100
    ; 方向未定时累计到这个位移再定轴。逐样本判轴会把带弧度的甩动全部丢掉。
    static AxisMinPx := 8
    static SampleMinPx := 2
    static PollMs := 16
    static HoldMs := 1400
    ; 助手端口与请求超时。没有超时的话，助手一旦卡住，本脚本的线程会永久堵在
    ; recv 上：热键全失效，外部看起来就是「AHK 没启动」。
    static SizerPort := 47631
    static SizerRecvTimeoutMs := 600
    ; 回收孤儿助手时等端口释放的上限。
    static ReapWaitMs := 800
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
    static LastMoveTick := 0
    ; 当前这条腿：轴、方向、起点、已经走过的行程、最远点。
    static LegAxis := 0
    static LegSign := 0
    static LegStartX := 0
    static LegStartY := 0
    static LegStartTick := 0
    static LegTravel := 0
    static LegPeakX := 0
    static LegPeakY := 0
    static ReverseStreak := 0
    static LastReverseTick := 0
    ; 连击起点与累计腿长：用来区分"原地摇"和"移到别处顺手抖了一下"。
    static StreakStartX := 0
    static StreakStartY := 0
    static StreakTravel := 0
    static StreakMinX := 0
    static StreakMinY := 0
    static StreakMaxX := 0
    static StreakMaxY := 0
    ; 本次连击的轨迹留痕：每条腿的行程/耗时；触发时连同幅度、净位移一起记账。
    static StreakFirstTick := 0
    static TraceLegs := ""
    ; 最近一次松开鼠标键的时刻，用来判断触发是不是紧跟在点击之后。
    static LastButtonUpTick := 0
    ; 现场计数：状态文件里能看出到底是哪一道闸门把它拦了。
    static CountButtonBlocks := 0
    static CountIdleResets := 0
    static CountSpanResets := 0
    static CountShortLegs := 0
    static CountSlowLegs := 0
    static CountSlowStreaks := 0
    static CountReversals := 0
    static CountTriggers := 0
    static CountNetRejects := 0
    static CountSmallSpanRejects := 0
    ; 连击最高攒到几次：判断摇动是死在第一次反向还是差一点点。
    static MaxStreakReached := 0
    static ButtonHeld := false
    static RestoreCallback := 0
    static StatusCallback := 0
    static HookMoves := 0
    static LastError := 0
    static LastTriggerTick := 0
    static LastSizerResult := "idle"
    static LastReapResult := "none"
    static MutexName := ""
    static MutexHandle := 0
    static StatusPath := A_Temp "\lat3ncy-find-mouse-status.txt"
    static TriggerTracePath := A_Temp "\lat3ncy-find-mouse-triggers.txt"

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
        ; 上一次被硬杀时可能留下放大态的光标和无主助手，先把它们收干净。
        this.ReapOrphanSizer()
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
        this.ReleaseParentMutex()
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
        this.LastMoveTick := 0
        this.ReverseStreak := 0
        this.LastReverseTick := 0
        this.StreakMinX := 0
        this.StreakMinY := 0
        this.StreakMaxX := 0
        this.StreakMaxY := 0
        this.StreakStartX := 0
        this.StreakStartY := 0
        this.StreakTravel := 0
        this.TraceLegs := ""
        this.StreakFirstTick := 0
        this.StartLeg(0, 0, 0)
    }

    ; 一条新腿从当前位置起算。
    static StartLeg(x, y, tick) {
        this.LegAxis := 0
        this.LegSign := 0
        this.LegStartX := x
        this.LegStartY := y
        this.LegStartTick := tick
        this.LegTravel := 0
        this.LegPeakX := x
        this.LegPeakY := y
    }

    ; 从当前位置重新采样：丢掉行程，把锚点、腿和包围盒都挪过来。
    static StartSample(x, y, tick) {
        this.HasAnchor := true
        this.LastX := x
        this.LastY := y
        this.ReverseStreak := 0
        this.LastReverseTick := 0
        this.StreakMinX := x
        this.StreakMinY := y
        this.StreakMaxX := x
        this.StreakMaxY := y
        this.StreakStartX := x
        this.StreakStartY := y
        this.StreakTravel := 0
        this.LastMoveTick := tick
        this.TraceLegs := ""
        this.StreakFirstTick := 0
        this.StartLeg(x, y, tick)
    }

    ; 光标停了一会儿说明这一轮动作已经结束，之前攒的行程不能跨过去复用。
    static IdleExpired(tick) {
        return this.LastMoveTick && (tick - this.LastMoveTick > this.IdleResetMs || tick < this.LastMoveTick)
    }

    ; 连击窗口内允许的活动范围。跨屏平移、长距离拖选都不是"在原地找指针"。
    static OutOfWindow() {
        spanX := this.StreakMaxX - this.StreakMinX
        spanY := this.StreakMaxY - this.StreakMinY
        return spanX > this.MaxSpanPx || spanY > this.MaxSpanPx
    }

    static TrackSpan(x, y) {
        this.StreakMinX := Min(this.StreakMinX, x)
        this.StreakMinY := Min(this.StreakMinY, y)
        this.StreakMaxX := Max(this.StreakMaxX, x)
        this.StreakMaxY := Max(this.StreakMaxY, y)
    }

    ; 包围盒只量"这一次摇动"的范围。若从上次采样起算，摇动前走的几百像素
    ; 会吃掉窗口预算，一摇就判成跨屏移动，越干净的直线摇越容易被它清掉。
    static ResetStreakBox(x, y) {
        this.StreakMinX := x
        this.StreakMinY := y
        this.StreakMaxX := x
        this.StreakMaxY := y
    }

    ; 一次"转折"= 当前这条腿先沿某轴走够 MinDistance，再往回走过 MinDistance。
    ; 轴由这条腿的净位移决定（不是单个采样点），所以带弧度、略斜的甩动照样算数；
    ; 走得太慢（日常瞄准修正）或太短（手抖）的腿不计数。
    static Observe(x, y, tick) {
        if !this.HasAnchor {
            this.StartSample(x, y, tick)
            return false
        }
        if this.IdleExpired(tick) {
            ; 只有真的丢了进度才算一次拦截，否则空闲时每 500ms 涨一次，数字没意义。
            if (this.ReverseStreak > 0 || this.LegTravel >= this.AxisMinPx)
                this.CountIdleResets += 1
            this.StartSample(x, y, tick)
            return false
        }

        dx := x - this.LastX
        dy := y - this.LastY
        if (Max(Abs(dx), Abs(dy)) < this.SampleMinPx)
            return false
        this.LastX := x
        this.LastY := y
        this.LastMoveTick := tick

        this.TrackSpan(x, y)
        if this.OutOfWindow() {
            ; 同样只统计真的被丢弃的进度，日常跨屏移动不刷这个计数。
            if (this.ReverseStreak > 0 || this.LegTravel >= this.AxisMinPx)
                this.CountSpanResets += 1
            this.StartSample(x, y, tick)
            return false
        }

        if !this.LegAxis {
            legX := x - this.LegStartX
            legY := y - this.LegStartY
            if (Max(Abs(legX), Abs(legY)) < this.AxisMinPx)
                return false
            this.LegAxis := Abs(legX) >= Abs(legY) ? 1 : 2
            this.LegSign := this.LegAxis = 1 ? (legX > 0 ? 1 : -1) : (legY > 0 ? 1 : -1)
            this.LegStartTick := tick
            this.LegTravel := Abs(this.LegAxis = 1 ? legX : legY)
            this.LegPeakX := x
            this.LegPeakY := y
            return false
        }

        ; 沿本腿方向的投影：变大为继续走，变小为往回走。
        projected := (this.LegAxis = 1 ? (x - this.LegStartX) : (y - this.LegStartY)) * this.LegSign
        if (projected > this.LegTravel) {
            this.LegTravel := projected
            this.LegPeakX := x
            this.LegPeakY := y
            return false
        }

        ; 相对最远点往回走了多远。轮询点稀疏时，手在两次采样之间可能已经
        ; 往回走过一段才被采到，峰值捕捉偏晚；给回摆判定打 6 折补偿，
        ; 否则越直越快的甩动，端点回摆被吞得越多，越难凑满反向。
        returned := (this.LegAxis = 1 ? (this.LegPeakX - x) : (this.LegPeakY - y)) * this.LegSign
        if (returned < this.MinDistance * 0.6)
            return false

        legMs := tick - this.LegStartTick
        if (this.LegTravel < this.MinDistance) {
            this.CountShortLegs += 1
            this.ReverseStreak := 0
            this.LastReverseTick := 0
            this.StartLeg(x, y, tick)
            return false
        }
        ; 太慢的腿：超过单腿时限（日常瞄准修正）。速度判据挪到整个手势上。
        if (legMs > this.LegMaxMs || legMs < 0) {
            this.CountSlowLegs += 1
            this.ReverseStreak := 0
            this.LastReverseTick := 0
            this.StartLeg(x, y, tick)
            return false
        }

        gap := this.LastReverseTick ? tick - this.LastReverseTick : 0
        this.LastReverseTick := tick
        if (this.ReverseStreak > 0 && (gap > this.MaxIntervalMs || gap < 0))
            this.ReverseStreak := 0
        ; 三次反向要连着完成：拖太久说明是在慢慢蹭，不是摇动。
        if (this.ReverseStreak > 0 && tick - this.StreakFirstTick > this.MaxStreakMs)
            this.ReverseStreak := 0
        ; 连击从这里起算时，包围盒也重新量：只衡量本次摇动的幅度。
        if (this.ReverseStreak = 0) {
            this.ResetStreakBox(x, y)
            this.TraceLegs := ""
            this.StreakFirstTick := tick
        }
        this.ReverseStreak += 1
        this.TraceLegs .= Format("{1}/{2} ", Round(this.LegTravel), legMs)
        if (this.ReverseStreak > this.MaxStreakReached)
            this.MaxStreakReached := this.ReverseStreak
        this.CountReversals += 1
        this.StreakTravel += this.LegTravel
        this.StartLeg(x, y, tick)
        if (this.ReverseStreak < this.ReverseCount)
            return false
        ; 整窗平均速度：犹豫式慢来回（有反向但整体很慢）在这里拦下，
        ; 而折返点的自然减速不再连坐整条连击。
        streakMs := tick - this.StreakFirstTick
        if (streakMs > 0 && this.StreakTravel / streakMs < this.MinStreakSpeedPxPerMs) {
            this.CountSlowStreaks += 1
            this.WriteTriggerTrace(tick, "slow", 0, this.StreakFirstTick)
            this.StartSample(x, y, tick)
            return false
        }
        ; "原地摇"绕着自己的起点来回，净位移远小于总行程；移到别处顺手抖两下
        ; 则离起点很远。这条判据专门掐掉"随意一晃就放大"。
        netRatio := 0
        if (this.StreakTravel > 0) {
            netX := x - this.StreakStartX
            netY := y - this.StreakStartY
            net := Sqrt(netX * netX + netY * netY)
            netRatio := net / this.StreakTravel
        }
        span := Max(this.StreakMaxX - this.StreakMinX, this.StreakMaxY - this.StreakMinY)
        if (span < this.MinSpanPx) {
            this.CountSmallSpanRejects += 1
            this.WriteTriggerTrace(tick, "small", netRatio, this.StreakFirstTick)
            this.StartSample(x, y, tick)
            return false
        }
        if (netRatio > this.MaxNetRatio) {
            this.CountNetRejects += 1
            this.WriteTriggerTrace(tick, "net", netRatio, this.StreakFirstTick)
            this.StartSample(x, y, tick)
            return false
        }
        this.CountTriggers += 1
        this.WriteTriggerTrace(tick, "hit", netRatio, this.StreakFirstTick)
        this.StartSample(x, y, tick)
        return true
    }

    ; 按住鼠标键时的来回移动是拖拽 / 框选 / 拖滑动条，不是"找不到指针"。
    static IsMouseButtonDown() {
        return (DllCall("GetAsyncKeyState", "Int", 1, "Short") & 0x8000)
            || (DllCall("GetAsyncKeyState", "Int", 2, "Short") & 0x8000)
            || (DllCall("GetAsyncKeyState", "Int", 4, "Short") & 0x8000)
            || (DllCall("GetAsyncKeyState", "Int", 5, "Short") & 0x8000)
            || (DllCall("GetAsyncKeyState", "Int", 6, "Short") & 0x8000)
    }

    static Poll(*) {
        point := Buffer(8, 0)
        if !DllCall("GetCursorPos", "Ptr", point)
            return
        this.HookMoves += 1
        if (this.Enabled && this.IsMouseButtonDown()) {
            ; 只在"从没按到按住"的那一刻计一次，避免每 16ms 刷爆计数。
            if !this.ButtonHeld {
                this.CountButtonBlocks += 1
                this.ButtonHeld := true
            }
            this.ResetMotion()
            return
        }
        ; 记下松键时刻：触发若紧跟点击，说明是点选后的移动，不是找指针。
        if (this.ButtonHeld)
            this.LastButtonUpTick := A_TickCount
        this.ButtonHeld := false
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
        ; 编译卡住不能把脚本线程一起拖死，超时就杀进程树。
        try {
            return ProcessNoWindow.RunWait(command, "", 15000) = 0 && FileExist(exe)
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
            ; PID 只作诊断；存活判定交给命名互斥体——脚本被强杀时它变成 abandoned，
            ; 助手能确定地发现自己成了孤儿并还原光标。查 PID 会被权限差异静默挡住。
            this.EnsureParentMutex()
            this.HelperPid := ProcessNoWindow.Run(Format('"{1}" serve {2} "{3}"', this.SizerExe(), DllCall("GetCurrentProcessId", "UInt"), this.MutexName))
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

    ; 自己持有父进程信号。bInitialOwner=TRUE：句柄随进程一起消失，互斥体即被放弃。
    static EnsureParentMutex() {
        if this.MutexHandle
            return true
        this.MutexName := "DSH-CursorSizer-" DllCall("GetCurrentProcessId", "UInt") "-" A_TickCount
        this.MutexHandle := DllCall("CreateMutexW", "Ptr", 0, "Int", 1, "WStr", this.MutexName, "Ptr")
        if !this.MutexHandle {
            this.MutexName := ""
            return false
        }
        return true
    }

    ; 正常停机时主动放掉信号，让助手马上收尾；强杀时不做任何事，句柄自动消失。
    static ReleaseParentMutex() {
        if this.MutexHandle {
            DllCall("ReleaseMutex", "Ptr", this.MutexHandle)
            DllCall("CloseHandle", "Ptr", this.MutexHandle)
        }
        this.MutexHandle := 0
        this.MutexName := ""
    }

    ; 上一个 AHK 被硬杀时，助手可能还活着并绑着端口：它不认识新脚本，父进程守护
    ; 也指向已经死掉的进程。先让它把光标还原、退出，之后启动的才是本次脚本的子进程。
    static ReapOrphanSizer() {
        if (this.HelperPid && ProcessExist(this.HelperPid))
            return false
        if !this.EnsureWinsock()
            return false
        if !this.PortOpen()
            return false
        this.SendRaw("rest")
        this.SendRaw("stop")
        deadline := A_TickCount + this.ReapWaitMs
        while (A_TickCount < deadline) {
            if !this.PortOpen() {
                this.LastReapResult := "reaped"
                return true
            }
            Sleep 25
        }
        this.LastReapResult := "stale"
        return false
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
        NumPut("UShort", DllCall("ws2_32\htons", "UShort", this.SizerPort, "UShort"), addr, 2)
        NumPut("UInt", 0x0100007F, addr, 4)
        ok := DllCall("ws2_32\connect", "Ptr", socket, "Ptr", addr, "Int", 16, "Int") = 0
        DllCall("ws2_32\closesocket", "Ptr", socket)
        return ok
    }

    ; recv 没有超时的话，助手一挂（或半开连接）就永久阻塞脚本线程。
    static ApplySocketTimeout(socket) {
        timeout := Buffer(4, 0)
        NumPut("Int", this.SizerRecvTimeoutMs, timeout, 0)
        DllCall("ws2_32\setsockopt", "Ptr", socket, "Int", 0xFFFF, "Int", 0x1006, "Ptr", timeout, "Int", 4)
        DllCall("ws2_32\setsockopt", "Ptr", socket, "Int", 0xFFFF, "Int", 0x1005, "Ptr", timeout, "Int", 4)
    }

    static SendSizer(command) {
        if !this.EnsureWinsock()
            return "winsock"
        if (command != "stop" && !this.EnsureSizer())
            return "unavailable"
        result := this.SendRaw(command)
        if (command = "stop")
            this.HelperPid := 0
        return result
    }

    static SendRaw(command) {
        socket := DllCall("ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
        if (socket = -1)
            return "socket"
        this.ApplySocketTimeout(socket)
        addr := Buffer(16, 0)
        NumPut("UShort", 2, addr, 0)
        NumPut("UShort", DllCall("ws2_32\htons", "UShort", this.SizerPort, "UShort"), addr, 2)
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
        err := (read <= 0) ? DllCall("ws2_32\WSAGetLastError", "Int") : 0
        DllCall("ws2_32\closesocket", "Ptr", socket)
        if (read <= 0) {
            ; 10060 WSAETIMEDOUT：助手收下了请求但没在期限内回话。
            if (err = 10060) {
                this.LastError := err
                return "timeout"
            }
            return "empty"
        }
        text := Trim(StrGet(reply, read, "UTF-8"), " `t`r`n")
        return text = "" ? "empty" : text
    }

    ; 每次触发/拒绝都记一条几何：以后偶发误触发可以直接回看当时的幅度、
    ; 速度、净位移和距上次点击多久，不必靠猜。只保留最近 40 条。
    static WriteTriggerTrace(tick, kind, netRatio, firstTick) {
        if !this.Enabled
            return
        try {
            btnAgo := this.LastButtonUpTick ? tick - this.LastButtonUpTick : -1
            span := Max(this.StreakMaxX - this.StreakMinX, this.StreakMaxY - this.StreakMinY)
            line := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
                . Format(" kind={1} t={2:.1f}s legs=[{3}] span={4} net={5:.2f} btnAgo={6} streakMs={7}"
                    , kind, tick / 1000, this.TraceLegs, Round(span), netRatio, btnAgo, tick - firstTick)
            old := ""
            try old := FileRead(this.TriggerTracePath, "UTF-8")
            out := line
            kept := 0
            if (old != "") {
                for entry in StrSplit(Trim(old, "`r`n"), "`n") {
                    if (entry = "" || kept >= 39)
                        continue
                    out .= "`n" entry
                    kept += 1
                }
            }
            try FileDelete(this.TriggerTracePath)
            FileAppend(out "`n", this.TriggerTracePath, "UTF-8")
        }
    }

    static WriteStatus(*) {
        try {
            content := "Hook=" (this.Hook ? 1 : 0)
                . "`nHookMoves=" this.HookMoves
                . "`nReverseStreak=" this.ReverseStreak
                . "`nLegAxis=" this.LegAxis
                . "`nLegTravel=" this.LegTravel
                . "`nEnlarged=" (this.Enlarged ? 1 : 0)
                . "`nEnlargePending=" (this.EnlargePending ? 1 : 0)
                . "`nHelperPid=" this.HelperPid
                . "`nLastError=" this.LastError
                . "`nLastTriggerTick=" this.LastTriggerTick
                . "`nLastSizerResult=" this.LastSizerResult
                . "`nLastReapResult=" this.LastReapResult
                . "`nButtonBlocks=" this.CountButtonBlocks
                . "`nIdleResets=" this.CountIdleResets
                . "`nSpanResets=" this.CountSpanResets
                . "`nShortLegs=" this.CountShortLegs
                . "`nSlowLegs=" this.CountSlowLegs
                . "`nSlowStreaks=" this.CountSlowStreaks
                . "`nReversals=" this.CountReversals
                . "`nNetRejects=" this.CountNetRejects
                . "`nMaxStreak=" this.MaxStreakReached
                . "`nSmallSpanRejects=" this.CountSmallSpanRejects
                . "`nStreakTravel=" this.StreakTravel
                . "`nTriggers=" this.CountTriggers
            temp := this.StatusPath ".tmp"
            try FileDelete(temp)
            FileAppend(content, temp, "UTF-8")
            FileMove(temp, this.StatusPath, true)
        }
    }
}
