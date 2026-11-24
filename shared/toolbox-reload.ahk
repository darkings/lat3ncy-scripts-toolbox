#Requires AutoHotkey v2.0

; Fixed IPC wakeup only. The medium worker revalidates the request, owner and task
; checkout before performing an action. No command or path comes from JSON.
class ToolboxReload {
    static LastId := ""
    static Poll(*) {
        if IsToolboxTestMode()
            return
        SplitPath A_LineFile, , &sharedDir
        SplitPath sharedDir, , &repo
        path := repo "\.toolbox-state\reload-request.json"
        try {
            if !FileExist(path)
                return
            file := FileOpen(path, "r", "UTF-8")
            try {
                if file.Length > 8192
                    return
                text := file.Read(8193)
            } finally file.Close()
            if !RegExMatch(text, '"id"\s*:\s*"([0-9a-f]{32})"', &match)
                return
            id := match[1]
            if id = this.LastId
                return
            this.LastId := id
            worker := repo "\tools\settings\Reload-Settings.ps1"
            command := '"' A_WinDir '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' worker '" -RequestId ' id
            proc := ProcessNoWindow.StartProcess(command)
            ; Do not terminate an in-flight restart when the settings/HUD closes.
            DllCall("CloseHandle", "Ptr", proc.hThread)
            DllCall("CloseHandle", "Ptr", proc.hProcess)
        } catch {
            ; Native settings reports a bounded timeout; never show system toast.
        }
    }
}
