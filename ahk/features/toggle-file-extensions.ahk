#Requires AutoHotkey v2.0

class ToggleFileExtensions {
    static Action(currentValue) {
        if (currentValue = 0)
            return {value: 1, visible: false}
        return {value: 0, visible: true}
    }

    static Toggle(_hotkeyName := "", receiverProbe := unset) {
        if IsSet(receiverProbe)
            return receiverProbe.Call(this)

        registryKey := "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

        try {
            currentValue := RegRead(registryKey, "HideFileExt", 1)
            action := this.Action(currentValue)
            RegWrite action.value, "REG_DWORD", registryKey, "HideFileExt"
            this.RefreshExplorerWindows()
        } catch {
            Notify.Error("×", "切换扩展名失败")
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

}

ToggleFileExtensions.HotkeyCallback := ObjBindMethod(ToggleFileExtensions, "Toggle")
