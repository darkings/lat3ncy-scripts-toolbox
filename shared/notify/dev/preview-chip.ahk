#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; 第 0 步壳体目视：依次弹出 中 / A / ⇪，对照系统选字框看阴影、描边、圆角。
#Include ..\renderer.ahk
#Include ..\notify.ahk

Notify.State("中", "", 1800)
Sleep 2000
Notify.State("A", "", 1800)
Sleep 2000
Notify.State("⇪", "", 1800)
Sleep 2200
ExitApp 0
