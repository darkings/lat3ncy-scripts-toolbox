#Requires AutoHotkey v2.0
#Include toolbox-instance.ahk

; Private translation files live in one leased directory per request. No
; recursive deletion, legacy filename glob or process-name ownership inference.
class TranslationRequestFiles {
    Busy := true
    Holds := 0
    hRoot := 0
    hDirectory := 0
    hLease := 0

    static Canonical(path) {
        pathBuffer := Buffer(65536, 0)
        size := DllCall("GetFullPathNameW", "Str", path, "UInt", 32768, "Ptr", pathBuffer, "Ptr", 0, "UInt")
        if (!size || size >= 32768)
            throw Error("无法确认任务路径")
        full := StrGet(pathBuffer, "UTF-16")
        size := DllCall("GetLongPathNameW", "Str", full, "Ptr", pathBuffer, "UInt", 32768, "UInt")
        if (size && size < 32768)
            full := StrGet(pathBuffer, "UTF-16")
        full := StrLower(RTrim(full, "\/"))
        if (StrLen(full) <= 3 || RegExMatch(full, "[\r\n]") || SubStr(full, 1, 4) = "\\?\" || SubStr(full, 1, 4) = "\\.\")
            throw Error("无法确认任务路径")
        return full
    }

    static Root(repo) => A_Temp "\lat3ncy-translate-" ToolboxInstance.Hash(this.Canonical(repo))

    static OwnerStart(pid) {
        if !ProcessExist(pid)
            return 0
        handle := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")
        if !handle
            return -1
        try {
            created := Buffer(8), exited := Buffer(8), kernel := Buffer(8), user := Buffer(8)
            if !DllCall("GetProcessTimes", "Ptr", handle, "Ptr", created, "Ptr", exited, "Ptr", kernel, "Ptr", user)
                return -1
            return NumGet(created, 0, "Int64")
        } finally DllCall("CloseHandle", "Ptr", handle)
    }

    static Nonce() {
        data := Buffer(16)
        if DllCall("ole32\CoCreateGuid", "Ptr", data, "Int")
            throw Error("无法分配任务编号")
        value := ""
        loop 16
            value .= Format("{:02x}", NumGet(data, A_Index - 1, "UChar"))
        return value
    }

    static GuardDirectory(path) {
        ; No write/delete sharing: do not let a directory be renamed or changed
        ; into a reparse point while its children are being inspected/deleted.
        handle := DllCall("CreateFileW", "Str", path, "UInt", 0x80, "UInt", 1,
            "Ptr", 0, "UInt", 3, "UInt", 0x02200000, "Ptr", 0, "Ptr")
        if (handle = -1 || !handle)
            throw Error("任务目录不可用")
        info := Buffer(52, 0)
        if (!DllCall("GetFileInformationByHandle", "Ptr", handle, "Ptr", info)
            || !(NumGet(info, 0, "UInt") & 0x10) || (NumGet(info, 0, "UInt") & 0x400)) {
            DllCall("CloseHandle", "Ptr", handle)
            throw Error("任务目录类型无效")
        }
        return handle
    }

    __New(root, repo, existingId := "") {
        this.root := TranslationRequestFiles.Canonical(root)
        this.repo := TranslationRequestFiles.Canonical(repo)
        if (existingId = "") {
            this.pid := DllCall("GetCurrentProcessId", "UInt")
            this.created := TranslationRequestFiles.OwnerStart(this.pid)
            if (this.created <= 0)
                throw Error("无法确认翻译任务归属")
            this.nonce := TranslationRequestFiles.Nonce()
            this.id := this.pid "-" this.created "-" this.nonce
            DirCreate this.root
        } else {
            if !RegExMatch(existingId, "^([1-9]\d{0,9})-([1-9]\d{0,18})-([a-f0-9]{32})$", &match)
                throw Error("任务归属格式无效")
            this.pid := Integer(match[1]), this.created := Integer(match[2]), this.nonce := match[3]
            this.id := existingId
            this.Busy := false
        }
        this.directory := this.root "\" this.id
        this.inputFile := this.directory "\input.txt"
        this.outputFile := this.directory "\result.txt"
        this.resumeFile := this.directory "\resume.json"
        try {
            this.hRoot := TranslationRequestFiles.GuardDirectory(this.root)
            if (existingId = "") {
                if FileExist(this.directory)
                    throw Error("任务编号冲突")
                DirCreate this.directory
            }
            this.hDirectory := TranslationRequestFiles.GuardDirectory(this.directory)
            this.hLease := DllCall("CreateFileW", "Str", this.directory "\.lease", "UInt", 0xC0000000,
                "UInt", 0, "Ptr", 0, "UInt", existingId = "" ? 1 : 3, "UInt", 0x00200080, "Ptr", 0, "Ptr")
            if (this.hLease = -1) {
                this.hLease := 0
                throw Error("任务仍在使用")
            }
            if !this.hLease
                throw Error("任务锁不可用")
            leaseInfo := Buffer(52)
            if (!DllCall("GetFileInformationByHandle", "Ptr", this.hLease, "Ptr", leaseInfo)
                || (NumGet(leaseInfo, 0, "UInt") & 0x410))
                throw Error("任务锁类型无效")
            if (existingId = "")
                FileAppend this.Marker(), this.directory "\.owner", "UTF-8-RAW"
            if !this.ValidMarker()
                throw Error("任务归属不匹配")
        } catch as err {
            this.Release()
            throw err
        }
    }

    Marker() => "version=1`npid=" this.pid "`ncreated=" this.created "`nnonce=" this.nonce "`nrepo=" this.repo "`n"

    ValidMarker() {
        path := this.directory "\.owner"
        try {
            attributes := DllCall("GetFileAttributesW", "Str", path, "UInt")
            if (attributes = 0xFFFFFFFF || (attributes & 0x410) || FileGetSize(path) > 4096)
                return false
            return FileRead(path, "UTF-8") = this.Marker()
        }
        return false
    }

    CanResume(root, repo) {
        return this.hLease && this.hRoot && this.hDirectory
            && this.root = TranslationRequestFiles.Canonical(root) && this.repo = TranslationRequestFiles.Canonical(repo)
            && this.pid = DllCall("GetCurrentProcessId", "UInt")
            && this.created = TranslationRequestFiles.OwnerStart(this.pid) && this.ValidMarker()
    }

    KnownFiles() {
        files := []
        loop files this.directory "\*", "FD" {
            if (files.Length >= 32 || InStr(A_LoopFileAttrib, "D"))
                throw Error("任务目录含未知内容")
            name := A_LoopFileName
            if !(name = ".owner" || name = ".lease" || name = "input.txt" || name = "result.txt"
                || name = "result.txt.trace" || name = "resume.json"
                || RegExMatch(name, "^(result\.txt(?:\.trace)?|resume\.json)\.[a-f0-9]{32}\.tmp$"))
                throw Error("任务目录含未知内容")
            if (DllCall("GetFileAttributesW", "Str", A_LoopFileFullPath, "UInt") & 0x400)
                throw Error("任务目录含链接")
            files.Push({name: name, path: A_LoopFileFullPath})
        }
        return files
    }

    Cleanup(retainResume := false) {
        if !DirExist(this.directory)
            return true
        if (this.Busy || !this.hLease || !this.ValidMarker())
            return false
        retainResume := retainResume || this.Holds > 0
        try files := this.KnownFiles()
        catch
            return false
        clean := true
        for file in files {
            if (file.name = ".owner" || file.name = ".lease")
                continue
            if (retainResume && (file.name = "resume.json" || RegExMatch(file.name, "^resume\.json\.[a-f0-9]{32}\.tmp$")))
                continue
            try FileDelete file.path
            clean := !FileExist(file.path) && clean
        }
        if (retainResume || !clean)
            return clean
        try FileDelete this.directory "\.owner"
        if FileExist(this.directory "\.owner")
            return false
        this.CloseHandle("hLease")
        this.CloseHandle("hDirectory")
        try FileDelete this.directory "\.lease"
        try DirDelete this.directory
        removed := !DirExist(this.directory)
        this.CloseHandle("hRoot")
        if removed
            try DirDelete this.root
        return removed
    }

    CloseHandle(name) {
        if this.%name% {
            DllCall("CloseHandle", "Ptr", this.%name%)
            this.%name% := 0
        }
    }

    Release() {
        for name in ["hLease", "hDirectory", "hRoot"]
            this.CloseHandle(name)
    }

    __Delete() => this.Release()

    static Scavenge(root, repo, probe := unset, maxEntries := 64) {
        result := {checked: 0, removed: 0, deferred: 0}
        if !DirExist(root)
            return result
        guard := 0
        try guard := this.GuardDirectory(this.Canonical(root))
        catch
            return result
        deadline := A_TickCount + 100
        try {
            loop files root "\*", "D" {
                if (result.checked >= Min(64, Max(0, maxEntries)) || A_TickCount >= deadline)
                    break
                result.checked += 1
                request := 0
                try {
                    if !RegExMatch(A_LoopFileName, "^([1-9]\d{0,9})-([1-9]\d{0,18})-[a-f0-9]{32}$", &identity)
                        continue
                    live := IsSet(probe) ? probe.Call(Integer(identity[1])) : this.OwnerStart(Integer(identity[1]))
                    if (live < 0 || live = Integer(identity[2]))
                        continue
                    request := TranslationRequestFiles(root, repo, A_LoopFileName)
                    live := IsSet(probe) ? probe.Call(request.pid) : this.OwnerStart(request.pid)
                    if (live < 0 || live = request.created)
                        continue
                    if request.Cleanup(false)
                        result.removed += 1
                    else
                        result.deferred += 1
                } catch {
                    result.deferred += 1
                } finally {
                    if IsObject(request)
                        request.Release()
                }
            }
        } finally DllCall("CloseHandle", "Ptr", guard)
        ; Empty root removal is non-recursive and may lose a race safely.
        try DirDelete root
        return result
    }
}
