#Requires AutoHotkey v2.0

class ToggleHiddenFiles {
    static Action(currentValue) {
        if (currentValue = 1)
            return {value: 2, visible: false}
        return {value: 1, visible: true}
    }

    static Toggle(*) {
        registryKey := "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

        try {
            currentValue := RegRead(registryKey, "Hidden", 2)
            action := this.Action(currentValue)
            RegWrite action.value, "REG_DWORD", registryKey, "Hidden"
            this.RefreshExplorerWindows()
            this.ShowTip(action.visible ? "已显示隐藏文件" : "已隐藏隐藏文件")
        } catch {
            this.ShowTip("切换隐藏文件失败")
        }
    }

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

    static ShowTip(message) {
        ToolTip message
        SetTimer ToggleHiddenFiles.HideTip, 0
        SetTimer ToggleHiddenFiles.HideTip, -1500
    }

    static HideTip() {
        ToolTip
    }
}

if !IsToolboxTestMode()
    RegisterFeatureHotkey("显示隐藏文件", Shortcuts.ToggleHiddenFiles, ToggleHiddenFiles.Toggle)
