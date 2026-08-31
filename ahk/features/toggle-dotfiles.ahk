#Requires AutoHotkey v2.0

; ============================================================
; 切换点文件（. 开头）显示：通过 Hidden 属性实现
; [快捷键: Caps + , (CapsLock & ,)]
;
; Windows 资源管理器没有 macOS 那种“按文件名隐藏点文件”的原生开关。
; 本功能只改当前文件夹【顶层】点文件/点目录的 Hidden 属性：
; - 不递归（.git 隐藏目录本身即可）
; - 当前目录里已经隐藏的点文件也会纳入管理，跟随 Caps + , 隐藏/显示
; - names 记录本工具正在管理的条目，再次按下只恢复这些条目
; ============================================================

class ToggleDotfiles {
    ; 状态文件：%LOCALAPPDATA%\lat3ncy-toolbox\dotfiles-state.ini
    ; 每个文件夹一节：
    ;   names=.git|.gitignore     ; 本工具正在管理、可恢复显示的点文件
    static StateFile := EnvGet("LOCALAPPDATA") "\lat3ncy-toolbox\dotfiles-state.ini"

    ; 纯逻辑：有 names 记录则恢复，否则隐藏。供测试断言，不碰文件系统。
    static Action(stateExists) {
        return {hide: !stateExists}
    }

    ; 点文件判定：必须以 . 开头，且不是 . / ..
    static IsDotName(name) {
        name := Trim(name)
        if (name = "." || name = ".." || name = "")
            return false
        return SubStr(name, 1, 1) = "."
    }

    ; 已经带 Hidden 的条目这次不用再写属性，但仍会纳入 names。
    static ShouldHide(attrib) {
        return !InStr(attrib, "H")
    }

    static IsHiddenAttrib(attrib) {
        return InStr(attrib, "H") != 0
    }

    ; 盘符根路径必须保留 C:\ ，RTrim 会把它变成无效的 C:
    static NormalizeDir(path) {
        path := Trim(path)
        if (path = "")
            return ""
        if RegExMatch(path, "^[A-Za-z]:\\$")
            return path
        return RTrim(path, "\")
    }

    ; 只接受盘符路径或 UNC，过滤此电脑 / 回收站 / 搜索结果的 ::{CLSID}
    static IsFilesystemPath(path) {
        return path != "" && RegExMatch(path, "i)^(?:[A-Za-z]:\\|\\\\)")
    }

    static JoinDir(dir, name) {
        if (SubStr(dir, -1) = "\")
            return dir name
        return dir "\" name
    }

    static Toggle(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        dir := this.GetActiveExplorerDir()
        if (dir = "") {
            Notify.Error("!", "前台不是资源管理器文件夹")
            return
        }

        action := this.Action(this.LoadState(dir) is Array)
        try {
            if action.hide {
                result := this.HideDotfiles(dir)
                if (result.hidden = 0 && result.managed = 0) {
                    Notify.Info("·", "没有点文件")
                    return
                }
                this.RefreshExplorerWindows()
                if (result.hidden > 0)
                    Notify.Success("✓", "已隐藏 " result.hidden " 个点文件")
                else
                    Notify.Success("✓", "已纳入 " result.managed " 个点文件")
                return
            }

            count := this.RestoreDotfiles(dir)
            this.RefreshExplorerWindows()
            Notify.Success("✓", "已恢复 " count " 个点文件")
        } catch as exc {
            Notify.Error("×", "切换点文件失败: " exc.Message)
        }
    }

    ; 前台是桌面时落到用户桌面目录；否则匹配 Shell.Application 里同 HWND 的窗口。
    static GetActiveExplorerDir() {
        hwnd := WinExist("A")
        if !hwnd
            return ""

        try {
            className := WinGetClass(hwnd)
            if (className = "Progman" || className = "WorkerW")
                return this.NormalizeDir(A_Desktop)
        } catch {
        }

        try {
            for window in ComObject("Shell.Application").Windows {
                try {
                    if (Integer(window.hwnd) != Integer(hwnd))
                        continue
                    path := this.NormalizeDir(window.Document.Folder.Self.Path)
                    if (this.IsFilesystemPath(path) && DirExist(path))
                        return path
                    return ""
                } catch {
                }
            }
        } catch {
        }
        return ""
    }

    ; 收集当前目录顶层点文件。hiddenOnly=true 只要已隐藏的，否则只要还能藏的。
    static CollectDotfiles(dir, hiddenOnly := false) {
        names := []
        Loop Files this.JoinDir(dir, "*"), "DF" {
            if !this.IsDotName(A_LoopFileName)
                continue
            try {
                attrib := FileGetAttrib(A_LoopFileFullPath)
            } catch {
                continue
            }
            isHidden := this.IsHiddenAttrib(attrib)
            if (hiddenOnly ? !isHidden : isHidden)
                continue
            names.Push(A_LoopFileName)
        }
        return names
    }

    static CollectVisibleDotfiles(dir) {
        return this.CollectDotfiles(dir, false)
    }

    static CollectHiddenDotfiles(dir) {
        return this.CollectDotfiles(dir, true)
    }

    ; 数组合并去重，保持先出现的顺序，方便稳定写入 INI。
    static MergeNames(left, right) {
        seen := Map()
        result := []
        for names in [left, right] {
            if !(names is Array)
                continue
            for name in names {
                if (name = "" || seen.Has(name))
                    continue
                seen[name] := true
                result.Push(name)
            }
        }
        return result
    }

    static ArrayHasName(names, needle) {
        if !(names is Array)
            return false
        for name in names {
            if (name = needle)
                return true
        }
        return false
    }

    static HideDotfiles(dir) {
        ; 已经隐藏的点文件也纳入 names，之后才能被 Caps + , 重新显示。
        alreadyHidden := this.CollectHiddenDotfiles(dir)
        newlyHidden := []
        for name in this.CollectVisibleDotfiles(dir) {
            try {
                FileSetAttrib "+H", this.JoinDir(dir, name)
                newlyHidden.Push(name)
            } catch {
            }
        }
        managed := this.MergeNames(alreadyHidden, newlyHidden)
        if managed.Length
            this.SaveState(dir, managed)
        return {hidden: newlyHidden.Length, managed: managed.Length}
    }

    static RestoreDotfiles(dir) {
        names := this.LoadState(dir)
        if !(names is Array)
            return 0

        restored := 0
        for name in names {
            path := this.JoinDir(dir, name)
            if !FileExist(path)
                continue
            try {
                FileSetAttrib "-H", path
                restored += 1
            } catch {
            }
        }
        this.ClearNames(dir)
        return restored
    }

    static EscapeSection(dir) {
        ; INI 节名不能含 [ ]，路径里偶尔出现时改成全角
        return StrReplace(StrReplace(dir, "[", "［"), "]", "］")
    }

    static JoinNames(names) {
        result := ""
        if !(names is Array)
            return result
        for name in names
            result .= (result = "" ? "" : "|") name
        return result
    }

    static SplitNames(value) {
        names := []
        if (value = "" || value = "ERROR")
            return names
        for name in StrSplit(value, "|") {
            if (name != "")
                names.Push(name)
        }
        return names
    }

    static EnsureStateDir() {
        SplitPath this.StateFile, , &stateDir
        if (stateDir != "" && !DirExist(stateDir))
            DirCreate stateDir
    }

    static WriteNamesKey(dir, key, names) {
        this.EnsureStateDir()
        section := this.EscapeSection(dir)
        if (names is Array && names.Length)
            IniWrite this.JoinNames(names), this.StateFile, section, key
        else if FileExist(this.StateFile)
            IniDelete this.StateFile, section, key
    }

    static SaveState(dir, names) {
        this.WriteNamesKey(dir, "names", names)
    }

    static LoadKeyNames(dir, key) {
        if !FileExist(this.StateFile)
            return false
        names := this.SplitNames(IniRead(this.StateFile, this.EscapeSection(dir), key, ""))
        return names.Length ? names : false
    }

    static LoadState(dir) {
        return this.LoadKeyNames(dir, "names")
    }

    static ClearNames(dir) {
        if FileExist(this.StateFile)
            IniDelete this.StateFile, this.EscapeSection(dir), "names"
    }

    static ClearState(dir) {
        if FileExist(this.StateFile)
            IniDelete this.StateFile, this.EscapeSection(dir)
    }

    ; 与 toggle-hidden-files / toggle-file-extensions 相同的刷新逻辑
    static RefreshExplorerWindows() {
        for window in ComObject("Shell.Application").Windows {
            try {
                SplitPath window.FullName, &executableName
                if (StrLower(executableName) = "explorer.exe")
                    window.Refresh()
            }
        }

        settingPath := "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        settingBuffer := Buffer(StrPut(settingPath, "UTF-16") * 2)
        StrPut settingPath, settingBuffer, "UTF-16"
        DllCall("User32\SendMessageTimeoutW"
            , "Ptr", 0xFFFF
            , "UInt", 0x001A
            , "Ptr", 0
            , "Ptr", settingBuffer.Ptr
            , "UInt", 0x0002
            , "UInt", 1000
            , "Ptr*", 0)
    }
}

ToggleDotfiles.HotkeyCallback := ObjBindMethod(ToggleDotfiles, "Toggle")
