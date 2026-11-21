#Requires AutoHotkey v2.0

; 本仓库工具箱实例标记。
;
; main.ahk 正常启动后在 Local\ 命名空间创建一个命名互斥体，并持有句柄直到进程退出。
; 启动看护只把「这个互斥体存在 + 路径匹配」当成工具箱存活；相对路径、命令行不可读
; 等无法证明归属的情况不再直接判 running。
;
; 互斥体名由仓库根目录小写化后的 UTF-8 字节做 FNV-1a 32 位哈希得到。
; PowerShell 侧 tools/startup/ToolboxProcess.ps1 的 Get-ToolboxInstanceHash /
; Get-ToolboxInstanceName 必须使用完全相同的算法，测试会做跨语言结果对比。
class ToolboxInstance {
    static Handle := 0

    static Hash(text) {
        normalized := StrLower(RTrim(text, "\/"))
        size := StrPut(normalized, "UTF-8")
        buf := Buffer(size, 0)
        StrPut normalized, buf, "UTF-8"
        hash := 2166136261
        Loop size - 1 {
            hash := ((hash ^ NumGet(buf, A_Index - 1, "UChar")) * 16777619) & 0xFFFFFFFF
        }
        return Format("{:08x}", hash)
    }

    static MutexName(repoRoot) {
        return "Local\Lat3ncyToolboxInstance-" this.Hash(repoRoot)
    }

    static Init(repoRoot) {
        if this.Handle
            return this.Handle
        name := this.MutexName(repoRoot)
        handle := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "WStr", name, "Ptr")
        if handle
            this.Handle := handle
        return this.Handle
    }
}
