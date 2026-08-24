#Requires AutoHotkey v2.0

; 无控制台启动子进程。
; Run / -WindowStyle Hidden 会先建窗口再隐藏，首帧会闪黑框。
; CreateProcessW + CREATE_NO_WINDOW 根本不分配控制台。
; 按需调用，不预热、不常驻。
class ProcessNoWindow {
    static CREATE_NO_WINDOW := 0x08000000
    static STARTF_USESHOWWINDOW := 0x00000001
    static STARTF_USESTDHANDLES := 0x00000100
    static GENERIC_WRITE := 0x40000000
    static CREATE_ALWAYS := 2
    static FILE_SHARE_READ := 1
    static FILE_SHARE_WRITE := 2
    static FILE_ATTRIBUTE_NORMAL := 0x80
    static INFINITE := 0xFFFFFFFF
    static INVALID_HANDLE := -1

    ; command: 完整命令行，第一个 token 是可执行文件
    ; wait: true 时等退出并返回退出码；false 时启动成功即返回 0
    ; stdoutFile: 非空则把 stdout/stderr 写到该文件（音频切换读取结果用）
    static Run(command, wait := false, stdoutFile := "") {
        command := Trim(command)
        if (command = "")
            throw Error("ProcessNoWindow 命令不能为空")

        si := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
        pi := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", si.Size, si, 0)

        ; STARTUPINFOW 标准句柄：x64 是 80/88/96，x86 是 56/60/64。
        ; 72 是 x64 的 lpReserved2，不能当成 hStdInput。
        flagsOffset := A_PtrSize = 8 ? 60 : 44
        showOffset := flagsOffset + 4
        stdInputOffset := A_PtrSize = 8 ? 80 : 56
        flags := this.STARTF_USESHOWWINDOW
        NumPut("UShort", 0, si, showOffset)

        stdoutHandle := 0
        if (stdoutFile != "") {
            stdoutHandle := this.CreateInheritWriteHandle(stdoutFile)
            flags |= this.STARTF_USESTDHANDLES
            ; stdin 置空，stdout/stderr 共用同一个可继承写句柄。
            NumPut("Ptr", 0, si, stdInputOffset)
            NumPut("Ptr", stdoutHandle, si, stdInputOffset + A_PtrSize)
            NumPut("Ptr", stdoutHandle, si, stdInputOffset + A_PtrSize * 2)
        }
        NumPut("UInt", flags, si, flagsOffset)

        ; CreateProcessW 会改写命令行缓冲区，必须用可写 UTF-16。
        commandBuf := Buffer(StrPut(command, "UTF-16") * 2, 0)
        StrPut command, commandBuf, "UTF-16"

        inheritHandles := stdoutHandle ? 1 : 0
        ok := DllCall(
            "CreateProcessW",
            "Ptr", 0,
            "Ptr", commandBuf,
            "Ptr", 0,
            "Ptr", 0,
            "Int", inheritHandles,
            "UInt", this.CREATE_NO_WINDOW,
            "Ptr", 0,
            "Ptr", 0,
            "Ptr", si,
            "Ptr", pi,
            "Int"
        )
        lastError := A_LastError
        if stdoutHandle
            DllCall("CloseHandle", "Ptr", stdoutHandle)
        if !ok
            throw Error("CreateProcessW 失败: " lastError)

        hProcess := NumGet(pi, 0, "Ptr")
        hThread := NumGet(pi, A_PtrSize, "Ptr")
        exitCode := 0
        try {
            if wait {
                DllCall("WaitForSingleObject", "Ptr", hProcess, "UInt", this.INFINITE)
                if !DllCall("GetExitCodeProcess", "Ptr", hProcess, "UInt*", &exitCode)
                    throw Error("GetExitCodeProcess 失败: " A_LastError)
            }
        } finally {
            DllCall("CloseHandle", "Ptr", hThread)
            DllCall("CloseHandle", "Ptr", hProcess)
        }
        return exitCode
    }

    static RunWait(command, stdoutFile := "") {
        return this.Run(command, true, stdoutFile)
    }

    ; 创建可被子进程继承的写句柄，父进程在 CreateProcess 后立刻关掉自己的副本。
    static CreateInheritWriteHandle(path) {
        sa := Buffer(A_PtrSize = 8 ? 24 : 12, 0)
        NumPut("UInt", sa.Size, sa, 0)
        NumPut("Int", 1, sa, A_PtrSize = 8 ? 16 : 8)

        ; 先确保目录存在，兼容 Temp 被清理的极端情况
        try {
            SplitPath path, , &dir
            if (dir != "" && !DirExist(dir))
                DirCreate dir
        } catch {
            ; 忽略目录创建失败
        }

        ; 若旧文件被占用导致 CREATE_ALWAYS 失败，先尝试删除
        try FileDelete path

        handle := DllCall(
            "CreateFileW",
            "WStr", path,
            "UInt", this.GENERIC_WRITE,
            "UInt", this.FILE_SHARE_READ | this.FILE_SHARE_WRITE,
            "Ptr", sa,
            "UInt", this.CREATE_ALWAYS,
            "UInt", this.FILE_ATTRIBUTE_NORMAL,
            "Ptr", 0,
            "Ptr"
        )
        err := A_LastError
        if (handle = 0 || handle = this.INVALID_HANDLE)
            throw Error("无法创建输出文件: " path " (CreateFileW err " err ")")
        return handle
    }
}
