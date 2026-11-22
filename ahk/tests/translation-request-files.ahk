RequestFilesFixture(root, repo, pid, created) {
    nonce := TranslationRequestFiles.Nonce()
    id := pid "-" created "-" nonce
    directory := root "\" id
    DirCreate directory
    marker := "version=1`npid=" pid "`ncreated=" created "`nnonce=" nonce "`nrepo=" TranslationRequestFiles.Canonical(repo) "`n"
    FileAppend marker, directory "\.owner", "UTF-8-RAW"
    FileAppend "", directory "\.lease"
    FileAppend "fixed source", directory "\input.txt"
    FileAppend "fixed checkpoint", directory "\resume.json"
    return {id: id, directory: directory, marker: marker}
}

RequestFilesRemoveFixture(root, fixture) {
    ; Remove only named test files within the declared temporary fixture root.
    if (InStr(TranslationRequestFiles.Canonical(fixture.directory), TranslationRequestFiles.Canonical(root) "\") != 1)
        throw Error("fixture path escaped")
    for name in [".owner", ".lease", "input.txt", "resume.json", "keep-me"]
        try FileDelete fixture.directory "\" name
    try DirDelete fixture.directory "\nested"
    try DirDelete fixture.directory
}

TranslationRequestFilesTests() {
    repo := A_Temp "\translation-files-test-" TranslationRequestFiles.Nonce()
    root := repo "\requests"
    DirCreate repo
    pid := DllCall("GetCurrentProcessId", "UInt"), created := TranslationRequestFiles.OwnerStart(pid)
    first := 0, second := 0, child := 0
    fixtures := []
    links := []
    outside := 0
    try {
        first := TranslationRequestFiles(root, repo)
        second := TranslationRequestFiles(root, repo)
        AssertEqual(false, first.directory = second.directory, "each translation attempt has a collision-resistant directory")
        FileAppend "fixed source", first.inputFile
        FileAppend "fixed checkpoint", first.resumeFile
        first.Busy := false
        AssertEqual(true, first.Cleanup(true), "completed panel retains only its checkpoint")
        AssertEqual(false, !!FileExist(first.inputFile), "retained checkpoint does not retain source input")
        AssertEqual(true, !!FileExist(first.resumeFile), "retained checkpoint remains available")
        scan := TranslationRequestFiles.Scavenge(root, repo, (*) => 0)
        AssertEqual(0, scan.removed, "exclusive leases protect active work even if an owner probe says absent")
        renameBlocked := false
        target := root "\renamed"
        AssertEqual(1, InStr(TranslationRequestFiles.Canonical(target), TranslationRequestFiles.Canonical(root) "\"), "rename fixture is inside its declared root")
        try DirMove first.directory, target
        catch
            renameBlocked := true
        AssertEqual(true, renameBlocked, "directory guard blocks a rename while request paths are in use")
        first.Holds += 1
        AssertEqual(true, first.Cleanup(false), "retry claim protects a checkpoint while the old context clears")
        AssertEqual(true, !!FileExist(first.resumeFile), "claimed checkpoint survives context transfer")
        first.Holds -= 1
        AssertEqual(true, first.Cleanup(false), "unclaimed completed context releases its files and lease")
        AssertEqual(false, !!DirExist(first.directory), "closed request directory is removed without recursion")
        AssertEqual(true, first.Cleanup(false), "request cleanup is idempotent")
        second.Busy := false
        AssertEqual(true, second.Cleanup(false), "another request remains independently disposable")

        for scenario in ["live", "unknown", "reused", "foreign", "unknown-file", "nested", "bad-marker"] {
            fixture := RequestFilesFixture(root, repo, pid, scenario = "live" ? created : created + 1)
            fixtures.Push(fixture)
            if (scenario = "foreign" || scenario = "bad-marker") {
                FileDelete fixture.directory "\.owner"
                FileAppend scenario = "foreign" ? StrReplace(fixture.marker, "repo=" TranslationRequestFiles.Canonical(repo), "repo=another-checkout") : "version=999`n", fixture.directory "\.owner", "UTF-8-RAW"
            }
            if (scenario = "unknown-file")
                FileAppend "unrecognized data", fixture.directory "\keep-me"
            if (scenario = "nested")
                DirCreate fixture.directory "\nested"
            scan := scenario = "unknown" ? TranslationRequestFiles.Scavenge(root, repo, (*) => -1) : TranslationRequestFiles.Scavenge(root, repo)
            AssertEqual(scenario != "reused", !!DirExist(fixture.directory), "scavenger preserves uncertain ownership/content: " scenario)
            if (scenario != "reused")
                AssertEqual(true, !!FileExist(fixture.directory "\input.txt"), "uncertain directories keep their contents intact: " scenario)
            RequestFilesRemoveFixture(root, fixture)
        }
        fixture := RequestFilesFixture(root, repo, pid, created + 1)
        fixtures.Push(fixture)
        scan := TranslationRequestFiles.Scavenge(root, repo, (*) => 0, 0)
        AssertEqual(0, scan.checked, "scavenging respects an explicit zero work budget")
        AssertEqual(true, !!FileExist(fixture.directory "\resume.json"), "zero budget performs no deletions")
        RequestFilesRemoveFixture(root, fixture)

        ; Real junctions point at separate known test data outside the managed
        ; root. Neither a request-directory link nor a root link may be followed.
        outsideRoot := repo "\outside"
        outside := RequestFilesFixture(outsideRoot, repo, pid, created + 1)
        script := repo "\make-junction.ps1"
        FileAppend "$ErrorActionPreference='Stop'`nNew-Item -ItemType Junction -Path $args[0] -Target $args[1] | Out-Null`n", script, "UTF-8-RAW"
        DirCreate root
        for pair in [[root "\" outside.id, outside.directory], [repo "\root-link", outsideRoot]] {
            links.Push(pair[1])
            command := '"' A_WinDir '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "' script '" "' pair[1] '" "' pair[2] '"'
            AssertEqual(0, ProcessNoWindow.Run(command, true, repo "\junction-stdout.txt", 5000), "junction safety fixture is available")
        }
        scan := TranslationRequestFiles.Scavenge(root, repo)
        AssertEqual(0, scan.removed, "request junction cannot redirect cleanup outside its managed root")
        scan := TranslationRequestFiles.Scavenge(repo "\root-link", repo)
        AssertEqual(0, scan.checked, "a reparse-point root is rejected before enumeration")
        AssertEqual(true, !!FileExist(outside.directory "\input.txt") && !!FileExist(outside.directory "\resume.json"), "junction target private test data remains intact")
        for link in links
            DirDelete link
        links := []
        RequestFilesRemoveFixture(outsideRoot, outside)
        DirDelete outsideRoot
        outside := 0

        ; Actual host termination releases the lease; PID/start-time checks and
        ; exact marker then permit cleanup without reading the private payloads.
        SplitPath A_LineFile, , &tests
        command := '"' A_AhkPath '" /ErrorStdOut=UTF-8 "' tests '\translation-file-crash.ahk" --test "' root '" "' repo '"'
        child := ProcessNoWindow.StartAsync(command, repo "\child-stdout.txt", 15000, true)
        deadline := A_TickCount + 5000
        while (!FileExist(repo "\crash-ready.txt") && !child.Done && A_TickCount < deadline) {
            child.Poll()
            Sleep 10
        }
        AssertEqual(true, !!FileExist(repo "\crash-ready.txt"), "crash fixture published files under a real held lease")
        id := Trim(FileRead(repo "\crash-ready.txt", "UTF-8"))
        directory := root "\" id
        scan := TranslationRequestFiles.Scavenge(root, repo)
        AssertEqual(true, !!FileExist(directory "\resume.json"), "live host checkpoint is never scavenged")
        child.Cancel()
        deadline := A_TickCount + 5000
        while (!child.Done && A_TickCount < deadline) {
            child.Poll()
            Sleep 10
        }
        AssertEqual(true, child.Done && child.HandlesClosed, "forced host termination closes its process/job handles")
        scan := TranslationRequestFiles.Scavenge(root, repo)
        AssertEqual(1, scan.removed, "abandoned real host request is reclaimed on the next scan")
        AssertEqual(false, !!DirExist(directory), "crash checkpoint/source/result/trace and atomic residue are gone")
        AssertEqual(false, !!DirExist(root), "an empty managed root can be removed without recursion")
    } finally {
        if IsObject(child)
            child.Dispose()
        for owner in [first, second] {
            if IsObject(owner) {
                owner.Busy := false
                owner.Cleanup(false)
                owner.Release()
            }
        }
        for fixture in fixtures
            RequestFilesRemoveFixture(root, fixture)
        for link in links
            try DirDelete link
        if IsObject(outside)
            RequestFilesRemoveFixture(repo "\outside", outside)
        try DirDelete repo "\outside"
        for name in ["crash-ready.txt", "child-stdout.txt", "make-junction.ps1", "junction-stdout.txt"]
            try FileDelete repo "\" name
        try DirDelete root
        try DirDelete repo
    }
}

TranslationRequestFilesTests()
