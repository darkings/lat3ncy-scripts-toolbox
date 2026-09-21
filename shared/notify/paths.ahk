#Requires AutoHotkey v2.0

; 共享通知资源路径。
; A_ScriptDir 永远是入口脚本目录，不是被 include 的本文件目录：
;   ahk\main.ahk            -> ...\ahk
;   ahk\tests\run-tests.ahk -> ...\ahk\tests
class NotifyPaths {
    static Resolve(fileName) {
        fileName := Trim(fileName)
        if (fileName = "")
            return ""

        ; A_ScriptDir 覆盖生产入口；A_WorkingDir 覆盖测试 runner 在 %TEMP% 里生成的 stub。
        candidates := [
            A_ScriptDir "\" fileName,
            A_ScriptDir "\shared\notify\" fileName,
            A_ScriptDir "\..\shared\notify\" fileName,
            A_ScriptDir "\..\..\shared\notify\" fileName,
            A_WorkingDir "\" fileName,
            A_WorkingDir "\shared\notify\" fileName,
            A_WorkingDir "\..\shared\notify\" fileName,
            A_WorkingDir "\..\..\shared\notify\" fileName
        ]
        seen := Map()
        for candidate in candidates {
            full := this.Expand(candidate)
            if (full = "" || seen.Has(StrLower(full)))
                continue
            seen[StrLower(full)] := true
            if FileExist(full)
                return full
        }
        return ""
    }

    static LocatorExe() {
        return this.Resolve("anchor-locator.exe")
    }

    static ToastScript() {
        return this.Resolve("toast.ps1")
    }

    ; WinUI Renderer：唯一 IME HUD。CapsLock 状态芯片 + Caps+F 翻译面板。
    static ImeHudWinUiExe() {
        candidates := [
            A_ScriptDir "\..\tools\ime-hud-winui\out\ImeHudWinUi.exe",
            A_ScriptDir "\..\..\tools\ime-hud-winui\out\ImeHudWinUi.exe",
            A_ScriptDir "\..\..\..\tools\ime-hud-winui\out\ImeHudWinUi.exe",
            A_WorkingDir "\tools\ime-hud-winui\out\ImeHudWinUi.exe",
            A_WorkingDir "\..\tools\ime-hud-winui\out\ImeHudWinUi.exe",
            A_WorkingDir "\..\..\tools\ime-hud-winui\out\ImeHudWinUi.exe"
        ]
        seen := Map()
        for candidate in candidates {
            full := this.Expand(candidate)
            if (full = "" || seen.Has(StrLower(full)))
                continue
            seen[StrLower(full)] := true
            if FileExist(full)
                return full
        }
        return ""
    }

    ; 相对路径转绝对路径，避免 Run/RunWait 依赖工作目录。
    static Expand(path) {
        chars := DllCall(
            "GetFullPathNameW",
            "WStr", path,
            "UInt", 0,
            "Ptr", 0,
            "Ptr", 0,
            "UInt"
        )
        if !chars
            return path
        buf := Buffer(chars * 2, 0)
        written := DllCall(
            "GetFullPathNameW",
            "WStr", path,
            "UInt", chars,
            "Ptr", buf,
            "Ptr", 0,
            "UInt"
        )
        if !written
            return path
        return StrGet(buf, "UTF-16")
    }
}
