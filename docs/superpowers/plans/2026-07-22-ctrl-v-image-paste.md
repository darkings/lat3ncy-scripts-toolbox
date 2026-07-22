# Ctrl+V Image Paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Ctrl+V` save clipboard images in Windows Explorer or a selected VS Code folder while every non-image or uncertain case preserves native paste behavior.

**Architecture:** Smart Paste keeps one global `$^v` hotkey and routes only file-list-free image clipboards into destination discovery. Windows Explorer continues to use Shell COM; VS Code discovery performs a reversible clipboard transaction around its built-in `copyFilePath` keybinding. A small clipboard adapter makes restoration behavior testable without changing the real clipboard during automated tests.

**Tech Stack:** AutoHotkey v2, Win32 clipboard format APIs, Windows Shell COM, VS Code `copyFilePath`, Windows PowerShell 5.1, existing PNG helper.

---

## File structure

- Modify `ahk/shortcuts.ahk`: change Smart Paste to `$^v` and add the VS Code Copy Path key.
- Modify `ahk/features/smart-paste/smart-paste.ahk`: native-paste routing, VS Code process detection, directory parsing, clipboard transaction, and fallback behavior.
- Modify `ahk/tests/run-tests.ahk`: routing, shortcuts, directory parsing, adapter restoration, and source-boundary assertions.
- Modify `ahk/tests/run-tests.ps1`: keep the independent Smart Paste stub aligned with the shortcut contract.
- Modify `README.md`: document `Ctrl+V`, VS Code folder behavior, and native fallbacks.
- Modify `docs/superpowers/specs/2026-07-22-script-toolbox-migration-design.md`: mark the earlier Smart Paste behavior as superseded by the new design.

### Task 1: Define the new shortcut and routing contract with failing tests

**Files:**
- Modify: `ahk/tests/run-tests.ahk`
- Modify: `ahk/tests/run-tests.ps1`

- [ ] **Step 1: Replace the old Smart Paste assertions with the new contract**

In `ahk/tests/run-tests.ahk`, replace the old `ChooseAction` assertions with:

```ahk
AssertEqual("$^v", Shortcuts.SmartPaste, "Smart Paste intercepts Ctrl+V without recursion")
AssertEqual("+!c", Shortcuts.VsCodeCopyPath, "VS Code Copy Path shortcut")
AssertEqual("normal-paste", SmartPaste.ChooseAction(true, true, true, false), "file list wins over image")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, false, true, false), "non-image Explorer paste stays native")
AssertEqual("save-explorer-image", SmartPaste.ChooseAction(false, true, true, false), "Explorer image saves")
AssertEqual("probe-vscode-image", SmartPaste.ChooseAction(false, true, false, true), "VS Code image probes selected folder")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, true, false, false), "other application image stays native")
```

Remove assertions expecting `plain-text`; text is now represented by `hasImage = false` and must return `normal-paste`.

- [ ] **Step 2: Add failing pure directory-selection tests**

Create a unique temporary directory and file, then assert only the directory is accepted:

```ahk
vsCodeTestRoot := A_Temp "\lat3ncy-vscode-folder-" SmartPaste.NewGuid()
DirCreate vsCodeTestRoot
vsCodeTestFile := vsCodeTestRoot "\selected.txt"
FileAppend "test", vsCodeTestFile, "UTF-8"
try {
    AssertEqual(vsCodeTestRoot, SmartPaste.DirectoryFromCopiedPath(vsCodeTestRoot), "VS Code selected folder")
    AssertEqual(vsCodeTestRoot, SmartPaste.DirectoryFromCopiedPath('"' vsCodeTestRoot '"'), "VS Code quoted folder")
    AssertEqual("", SmartPaste.DirectoryFromCopiedPath(vsCodeTestFile), "VS Code selected file falls back")
    AssertEqual("", SmartPaste.DirectoryFromCopiedPath(vsCodeTestRoot "`n" vsCodeTestRoot), "VS Code multi-selection falls back")
    AssertEqual("", SmartPaste.DirectoryFromCopiedPath("C:\missing-lat3ncy-folder"), "VS Code missing folder falls back")
} finally {
    FileDelete vsCodeTestFile
    DirDelete vsCodeTestRoot
}
```

- [ ] **Step 3: Add a fake clipboard adapter and failing restoration tests**

Add this test-only adapter near the assertion helpers:

```ahk
class FakeSmartPasteClipboard {
    __New(copyValue, waitResult := true, throwOnWait := false) {
        this.copyValue := copyValue
        this.waitResult := waitResult
        this.throwOnWait := throwOnWait
        this.restored := false
        this.restoredValue := ""
    }

    Capture() => "original-image"
    Clear() => 0
    ReadText() => this.copyValue

    Wait(*) {
        if this.throwOnWait
            throw Error("simulated clipboard failure")
        return this.waitResult
    }

    Restore(snapshot) {
        this.restored := true
        this.restoredValue := snapshot
    }
}
```

Inside the temporary-directory `try`, add:

```ahk
sentShortcut := ""
sendCopyPath := shortcut => sentShortcut := shortcut

successClipboard := FakeSmartPasteClipboard(vsCodeTestRoot)
AssertEqual(
    vsCodeTestRoot,
    SmartPaste.GetVsCodeSelectedDirectory(Shortcuts.VsCodeCopyPath, successClipboard, sendCopyPath),
    "VS Code directory probe succeeds")
AssertEqual("+!c", sentShortcut, "VS Code probe invokes Copy Path")
AssertEqual(true, successClipboard.restored, "VS Code success restores clipboard")
AssertEqual("original-image", successClipboard.restoredValue, "VS Code success restores original snapshot")

timeoutClipboard := FakeSmartPasteClipboard(vsCodeTestRoot, false)
AssertEqual("", SmartPaste.GetVsCodeSelectedDirectory("+!c", timeoutClipboard, (*) => 0), "VS Code timeout falls back")
AssertEqual(true, timeoutClipboard.restored, "VS Code timeout restores clipboard")

errorClipboard := FakeSmartPasteClipboard(vsCodeTestRoot, true, true)
AssertThrows(
    () => SmartPaste.GetVsCodeSelectedDirectory("+!c", errorClipboard, (*) => 0),
    "simulated clipboard failure",
    "VS Code probe exposes error after restoration")
AssertEqual(true, errorClipboard.restored, "VS Code exception restores clipboard")
```

- [ ] **Step 4: Update the independent feature stub**

In `ahk/tests/run-tests.ps1`, change and extend the `Shortcuts` stub:

```ahk
static SmartPaste := "`$^v"
static VsCodeCopyPath := "+!c"
```

- [ ] **Step 5: Run the suite and verify the intended RED**

Run:

```powershell
powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1
```

Expected: exit 1 because `Shortcuts.SmartPaste` is still `^+v` and `SmartPaste.DirectoryFromCopiedPath` / `GetVsCodeSelectedDirectory` do not exist. The failure must not be an AHK syntax or include error.

- [ ] **Step 6: Commit the red contract**

```powershell
git add ahk/tests/run-tests.ahk ahk/tests/run-tests.ps1
git commit -m "test: define ctrl-v image paste behavior"
```

### Task 2: Implement native Ctrl+V routing and reversible VS Code discovery

**Files:**
- Modify: `ahk/shortcuts.ahk`
- Modify: `ahk/features/smart-paste/smart-paste.ahk`

- [ ] **Step 1: Change centralized shortcuts**

Update the two properties in `ahk/shortcuts.ahk`:

```ahk
static SmartPaste := "$^v"
static VsCodeCopyPath := "+!c"
```

- [ ] **Step 2: Add the real clipboard adapter**

Place this class before `SmartPaste` in the feature file:

```ahk
class SmartPasteClipboard {
    Capture() => ClipboardAll()

    Clear() {
        A_Clipboard := ""
    }

    Wait(timeoutSeconds) => ClipWait(timeoutSeconds, true)
    ReadText() => A_Clipboard

    Restore(snapshot) {
        A_Clipboard := snapshot
    }
}
```

- [ ] **Step 3: Replace the old classifier**

Remove `HasText()` and replace `ChooseAction` with:

```ahk
static ChooseAction(hasFiles, hasImage, isExplorer, isVsCode) {
    if hasFiles || !hasImage
        return "normal-paste"
    if isExplorer
        return "save-explorer-image"
    if isVsCode
        return "probe-vscode-image"
    return "normal-paste"
}
```

- [ ] **Step 4: Add selected-directory parsing**

```ahk
static DirectoryFromCopiedPath(value) {
    value := Trim(value)
    if !value || InStr(value, "`r") || InStr(value, "`n")
        return ""

    if (StrLen(value) >= 2) {
        first := SubStr(value, 1, 1)
        last := SubStr(value, -1)
        if ((first = '"' && last = '"') || (first = "'" && last = "'"))
            value := SubStr(value, 2, -1)
    }

    attributes := FileExist(value)
    return InStr(attributes, "D") ? value : ""
}
```

- [ ] **Step 5: Add the reversible VS Code clipboard transaction**

```ahk
static GetVsCodeSelectedDirectory(copyPathShortcut, clipboard := unset, sendCopyPath := unset) {
    if !IsSet(clipboard)
        clipboard := SmartPasteClipboard()
    if !IsSet(sendCopyPath)
        sendCopyPath := shortcut => Send(shortcut)

    snapshot := clipboard.Capture()
    try {
        clipboard.Clear()
        sendCopyPath.Call(copyPathShortcut)
        if !clipboard.Wait(0.75)
            return ""
        return this.DirectoryFromCopiedPath(clipboard.ReadText())
    } finally {
        clipboard.Restore(snapshot)
    }
}
```

- [ ] **Step 6: Replace `Paste` routing**

Use one clipboard classification pass and explicit native fallback:

```ahk
static Paste(_hotkeyName := "", receiverProbe := unset) {
    if IsSet(receiverProbe)
        return receiverProbe.Call(this)

    hasFiles := this.HasFiles()
    hasImage := this.HasImage()
    isExplorer := WinActive("ahk_class CabinetWClass") != 0
    isVsCode := WinActive("ahk_exe Code.exe") != 0
    action := this.ChooseAction(hasFiles, hasImage, isExplorer, isVsCode)

    if (action = "normal-paste") {
        Send "^v"
        return
    }

    if (action = "save-explorer-image") {
        explorerPath := this.GetActiveExplorerPath()
        if explorerPath
            this.SaveClipboardImage(explorerPath)
        else
            this.ShowTip("当前资源管理器位置无法保存图片")
        return
    }

    try {
        destination := this.GetVsCodeSelectedDirectory(Shortcuts.VsCodeCopyPath)
    } catch {
        destination := ""
    }

    if destination
        this.SaveClipboardImage(destination)
    else
        Send "^v"
}
```

This intentionally removes the old outer catch that converted every failure into a tooltip: VS Code discovery errors must fall back to native paste, while `SaveClipboardImage` already handles encoder errors internally.

- [ ] **Step 7: Add source-boundary assertions**

In `run-tests.ahk`, add:

```ahk
AssertNotContains(smartPasteSource, "SendText A_Clipboard", "Smart Paste no longer reformats text")
AssertNotContains(smartPasteSource, "static HasText()", "Smart Paste no longer classifies text")
AssertContains(smartPasteSource, 'WinActive("ahk_exe Code.exe")', "Smart Paste detects VS Code")
AssertContains(smartPasteSource, "ClipboardAll()", "VS Code probe captures all clipboard formats")
AssertContains(smartPasteSource, "finally", "VS Code probe restores clipboard in finally")
AssertContains(smartPasteSource, 'Send "^v"', "Smart Paste preserves native paste")
```

- [ ] **Step 8: Run the complete suite**

Run:

```powershell
powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1
```

Expected: exit 0; seven independent feature loads PASS, PowerShell helper AST PASS, and core assertions PASS.

- [ ] **Step 9: Run the production startup smoke**

Use the real AHK v2 engine resolved by `run-tests.ps1`, start `ahk/main.ahk` with `/ErrorStdOut`, wait two seconds, confirm the exact process remains alive with empty stderr, then stop only that PID.

Expected: no syntax, shortcut-conflict, helper, or startup error; no residual process for the worktree script.

- [ ] **Step 10: Commit the implementation**

```powershell
git add ahk/shortcuts.ahk ahk/features/smart-paste/smart-paste.ahk ahk/tests/run-tests.ahk
git commit -m "feat: save ctrl-v images in explorer folders"
```

### Task 3: Update current documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-22-script-toolbox-migration-design.md`

- [ ] **Step 1: Update the shortcut table and Smart Paste route**

Replace the Smart Paste row with:

```markdown
| `Ctrl+V`（`$^v`） | 在资源管理器或 VS Code 选中文件夹中保存剪贴板图片；其他内容原生粘贴 | `ahk/features/smart-paste/smart-paste.ahk` |
```

Replace the route introduction and table with:

```markdown
`Ctrl+V` 只在剪贴板包含图片且目标目录明确时改变行为：

| 剪贴板内容 | 活动窗口 | 行为 |
| --- | --- | --- |
| 已复制的文件或目录 | 任意 | 原生 `Ctrl+V` |
| 非图片内容 | 任意 | 原生 `Ctrl+V` |
| 图片 | 普通文件系统目录的 Windows 资源管理器 | 保存为不会覆盖已有文件的唯一命名 PNG |
| 图片 | VS Code 文件栏选中的单个文件夹 | 保存为唯一命名 PNG |
| 图片 | VS Code 选中文件、多个项目或路径探测失败 | 原生 `Ctrl+V` |
| 图片 | 其他应用 | 原生 `Ctrl+V` |
```

Add one sentence explaining that VS Code uses its Windows `Shift+Alt+C` Copy Path command and that a customized VS Code binding must be mirrored in `Shortcuts.VsCodeCopyPath`.

- [ ] **Step 2: Mark the original migration design as superseded for Smart Paste**

At the beginning of the Smart Paste section in `2026-07-22-script-toolbox-migration-design.md`, add:

```markdown
> **后续变更：** 本节的 `Ctrl+Shift+V` 与纯文本分支已由
> `2026-07-22-ctrl-v-image-paste-design.md` 取代；当前行为以该文档为准。
```

- [ ] **Step 3: Verify documentation paths and stale behavior references**

Run:

```powershell
$currentDocs = @(
    'README.md',
    'docs/superpowers/specs/2026-07-22-script-toolbox-migration-design.md',
    'docs/superpowers/specs/2026-07-22-ctrl-v-image-paste-design.md'
)
rg -n 'Ctrl\+Shift\+V|\^\+v|SendText|纯文本粘贴' $currentDocs
```

Expected: the new design and README contain no stale current-behavior claims. The original migration design may retain old text only immediately under the explicit superseded notice.

- [ ] **Step 4: Run Markdown and repository checks**

Run:

```powershell
git diff --check
powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1
```

Expected: both exit 0.

- [ ] **Step 5: Commit documentation**

```powershell
git add README.md docs/superpowers/specs/2026-07-22-script-toolbox-migration-design.md
git commit -m "docs: document ctrl-v image paste"
```

### Task 4: Final verification and manual handoff

**Files:**
- Verify: all changed files

- [ ] **Step 1: Run all non-interactive checks fresh**

```powershell
powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1
python -m compileall -q .\tools\screenshot-ocr\screenshot_ocr.py
$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path '.\ahk\features\smart-paste\save-clipboard-image.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count) { $errors | Format-List; exit 1 }
git diff --check
git status --short
```

Expected: AHK suite PASS, Python compile exit 0, PowerShell AST has zero errors, diff check clean, and worktree status clean after commits.

- [ ] **Step 2: Repeat the production AHK startup smoke**

Start the exact worktree `ahk/main.ahk` with the real v2 engine, confirm it remains alive for two seconds without stderr, then stop only that PID and confirm no residual process points to the worktree script.

- [ ] **Step 3: Record the interactive checks not performed automatically**

Do not claim these pass unless they are actually exercised:

- Native text paste in an editor, browser, and terminal.
- Native copied-file paste in Windows Explorer.
- Image save in a normal Windows Explorer directory and same-second collision behavior.
- VS Code Explorer folder selection saves the image.
- VS Code file selection, multi-selection, editor focus, timeout, or changed Copy Path binding falls back to native paste with the image clipboard preserved.
- PNG-only clipboard interoperability and encoder failure prompts.

- [ ] **Step 4: Review the final diff against the approved design**

Check every behavior, error case, and test requirement in `docs/superpowers/specs/2026-07-22-ctrl-v-image-paste-design.md`. Report any interactive checks that remain outstanding.
