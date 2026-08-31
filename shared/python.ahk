#Requires AutoHotkey v2.0

; 解析本机 pythonw，换机不用改脚本。
; 顺序：PATH -> 官方 Local\Programs\Python -> Scoop(SCOOP / %USERPROFILE%\scoop) -> 本机历史路径兜底。
class ToolboxPython {
    static ResolveW() {
        for dir in StrSplit(EnvGet("PATH"), ";") {
            candidate := RTrim(dir, "\") "\pythonw.exe"
            if (candidate != "\pythonw.exe" && FileExist(candidate))
                return candidate
        }

        localAppData := EnvGet("LOCALAPPDATA")
        if (localAppData = "")
            localAppData := A_AppData "\..\Local"
        official312 := localAppData "\Programs\Python\Python312\pythonw.exe"
        if FileExist(official312)
            return official312
        ; 官方安装器可能是 Python311 / Python313，按目录名扫一遍。
        loop files localAppData "\Programs\Python\Python3*\pythonw.exe", "F" {
            return A_LoopFileFullPath
        }

        scoopRoots := []
        scoopEnv := EnvGet("SCOOP")
        if (scoopEnv != "")
            scoopRoots.Push(RTrim(scoopEnv, "\"))
        userProfile := EnvGet("USERPROFILE")
        if (userProfile != "")
            scoopRoots.Push(userProfile "\scoop")
        ; 本机历史安装位置，只作最后兜底，不能当唯一路径。
        scoopRoots.Push("D:\Applications\Scoop")

        seen := Map()
        for root in scoopRoots {
            if (root = "" || seen.Has(StrLower(root)))
                continue
            seen[StrLower(root)] := true
            for rel in ["apps\python312\current\pythonw.exe", "apps\python\current\pythonw.exe"] {
                candidate := root "\" rel
                if FileExist(candidate)
                    return candidate
            }
        }
        return "pythonw.exe"
    }
}
