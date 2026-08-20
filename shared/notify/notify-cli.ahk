#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

#Include renderer.ahk
#Include notify.ahk

if (A_Args.Length < 2)
    ExitApp 1

notificationType := StrLower(A_Args[1])
icon := A_Args[2]
text := A_Args.Length >= 3 ? A_Args[3] : ""
duration := 0

if (A_Args.Length >= 4) {
    try duration := Integer(A_Args[4])
    catch
        ExitApp 2
}

switch notificationType {
    case "state":
        duration := duration > 0 ? duration : 550
        Notify.State(icon, text, duration)
    case "success":
        duration := duration > 0 ? duration : 900
        Notify.Success(icon, text, duration)
    case "info":
        duration := duration > 0 ? duration : 750
        Notify.Info(icon, text, duration)
    case "error":
        duration := duration > 0 ? duration : 1400
        Notify.Error(icon, text, duration)
    default:
        ExitApp 2
}

; CLI 是临时进程，必须覆盖完整 HUD 生命周期。
Sleep duration + 120
ExitApp 0
