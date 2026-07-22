# Clipboard Image Paste Implementation Plan

> **迁移说明：** 本文记录迁移前的 `D:\Scripts` 路径与结构，仅作历史参考；当前仓库结构以 [`2026-07-22-script-toolbox-migration-design.md`](../specs/2026-07-22-script-toolbox-migration-design.md) 为准，不应将本文视为现行操作指南。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `Ctrl+Shift+V` so copied images become PNG files in the active Explorer directory while existing plain-text paste behavior remains intact.

**Architecture:** The AHK hotkey becomes a small dispatcher: Windows clipboard format checks detect images, Explorer COM supplies the active filesystem path, and a focused PowerShell helper reads and encodes the clipboard image. Non-Explorer image paste delegates to normal `Ctrl+V`; text continues through `SendText`.

**Tech Stack:** AutoHotkey v2, Windows Shell COM, Win32 clipboard APIs, Windows PowerShell 5.1, .NET Windows Forms and System.Drawing.

---

## File structure

- Modify `ahk/productivity.ahk`: clipboard classification, active Explorer path lookup, dispatch, helper invocation, and user notifications.
- Modify `ahk/productivity.tests.ahk`: pure dispatch tests and structural assertions for Windows integration boundaries.
- Create `ahk/save-clipboard-image.ps1`: safely save the current clipboard bitmap as a uniquely named PNG without overwriting files.

### Task 1: Add failing dispatch and integration-boundary tests

**Files:**
- Modify: `ahk/productivity.tests.ahk`

- [ ] **Step 1: Add dispatch tests after the CapsLock state-machine tests**

```ahk
AssertEqual("plain-text", ClipboardPasteAction(false, false), "文本继续纯文本粘贴")
AssertEqual("normal-image-paste", ClipboardPasteAction(true, false), "非资源管理器正常粘贴图片")
AssertEqual("save-image", ClipboardPasteAction(true, true), "资源管理器保存图片")
```

- [ ] **Step 2: Add source-level integration assertions near the existing source assertions**

```ahk
AssertContains(source, 'DllCall("User32\\IsClipboardFormatAvailable"', "使用 Windows API 检测剪贴板图像")
AssertContains(source, 'ComObject("Shell.Application").Windows', "通过 Shell COM 获取资源管理器目录")
AssertContains(source, 'save-clipboard-image.ps1', "调用图片保存辅助脚本")
AssertContains(source, 'Send "^v"', "非资源管理器使用普通图片粘贴")

helperSource := FileRead(A_ScriptDir "\\save-clipboard-image.ps1", "UTF-8")
AssertContains(helperSource, '[Windows.Forms.Clipboard]::ContainsImage()', "辅助脚本验证剪贴板图像")
AssertContains(helperSource, '[Drawing.Imaging.ImageFormat]::Png', "辅助脚本编码 PNG")
AssertContains(helperSource, 'FileMode]::CreateNew', "辅助脚本禁止覆盖已有文件")
```

- [ ] **Step 3: Run the tests and verify the new behavior is missing**

Run: `autohotkey.exe D:\Scripts\ahk\productivity.tests.ahk`

Expected: FAIL because `ClipboardPasteAction` is not defined.

### Task 2: Implement clipboard dispatch and Explorer path lookup

**Files:**
- Modify: `ahk/productivity.ahk:43-50`
- Modify: `ahk/productivity.ahk:200-203`

- [ ] **Step 1: Rename the registered handler**

Change the hotkey registration to:

```ahk
Hotkey "^+v", PasteClipboard
```

- [ ] **Step 2: Add pure classification and clipboard-format detection**

```ahk
ClipboardPasteAction(hasImage, isExplorer) {
    if !hasImage
        return "plain-text"
    return isExplorer ? "save-image" : "normal-image-paste"
}

HasClipboardImage() {
    for format in [2, 8, 17] { ; CF_BITMAP, CF_DIB, CF_DIBV5
        if DllCall("User32\IsClipboardFormatAvailable", "UInt", format, "Int")
            return true
    }
    return false
}
```

- [ ] **Step 3: Add active Explorer filesystem-path lookup**

```ahk
GetActiveExplorerPath() {
    if !WinActive("ahk_class CabinetWClass")
        return ""

    activeHwnd := WinExist("A")
    for window in ComObject("Shell.Application").Windows {
        try {
            if (window.HWND != activeHwnd)
                continue
            path := window.Document.Folder.Self.Path
            return InStr(FileExist(path), "D") ? path : ""
        }
    }
    return ""
}
```

- [ ] **Step 4: Replace `PastePlainText` with the dispatcher**

```ahk
PasteClipboard(*) {
    explorerPath := GetActiveExplorerPath()
    action := ClipboardPasteAction(HasClipboardImage(), explorerPath != "")

    if (action = "plain-text") {
        SendText A_Clipboard
        ShowTip("已粘贴纯文本")
    } else if (action = "normal-image-paste") {
        Send "^v"
    } else {
        SaveClipboardImage(explorerPath)
    }
}
```

- [ ] **Step 5: Run the tests to expose only the missing helper integration**

Run: `autohotkey.exe D:\Scripts\ahk\productivity.tests.ahk`

Expected: dispatch assertions PASS; source assertion for `save-clipboard-image.ps1` FAIL.

### Task 3: Add the safe PowerShell PNG writer

**Files:**
- Create: `ahk/save-clipboard-image.ps1`

- [ ] **Step 1: Create the helper with explicit inputs and unique-file creation**

```powershell
param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$ResultFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not [Windows.Forms.Clipboard]::ContainsImage()) {
    throw 'Clipboard no longer contains an image.'
}

$image = [Windows.Forms.Clipboard]::GetImage()
$stream = $null
$outputPath = $null

try {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    for ($index = 0; $index -le 999; $index++) {
        $suffix = if ($index -eq 0) { '' } else { "-$index" }
        $candidate = Join-Path $Destination "Clipboard-$timestamp$suffix.png"
        try {
            $stream = [IO.FileStream]::new(
                $candidate,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            $outputPath = $candidate
            break
        }
        catch [IO.IOException] {
            continue
        }
    }

    if (-not $outputPath) {
        throw 'Could not allocate a unique output filename.'
    }

    try {
        $image.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    }
    catch {
        $stream.Dispose()
        $stream = $null
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        throw
    }

    [IO.File]::WriteAllText($ResultFile, $outputPath, [Text.UTF8Encoding]::new($false))
}
finally {
    if ($stream) { $stream.Dispose() }
    if ($image) { $image.Dispose() }
}
```

- [ ] **Step 2: Validate PowerShell syntax without touching the clipboard**

Run:

```powershell
$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile(
    'D:\Scripts\ahk\save-clipboard-image.ps1',
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count) { $errors | Format-List; exit 1 }
```

Expected: exit code 0 and no parser errors.

### Task 4: Connect AHK to the helper and handle failures

**Files:**
- Modify: `ahk/productivity.ahk`

- [ ] **Step 1: Add synchronous hidden helper invocation and result cleanup**

```ahk
SaveClipboardImage(destination) {
    helperPath := A_ScriptDir "\\save-clipboard-image.ps1"
    resultFile := A_Temp "\\ahk-clipboard-image-" DllCall("Kernel32\\GetCurrentProcessId", "UInt") "-" A_TickCount ".txt"
    command := 'powershell.exe -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'
        helperPath '" -Destination "' destination '" -ResultFile "' resultFile '"'

    try {
        exitCode := RunWait(command, , "Hide")
        if (exitCode != 0 || !FileExist(resultFile)) {
            ShowTip("图片保存失败")
            return false
        }

        outputPath := Trim(FileRead(resultFile, "UTF-8"))
        if !FileExist(outputPath) {
            ShowTip("图片保存失败")
            return false
        }

        SplitPath outputPath, &fileName
        ShowTip("已保存图片：" fileName)
        return true
    } catch {
        ShowTip("图片保存失败")
        return false
    } finally {
        if FileExist(resultFile)
            FileDelete resultFile
    }
}
```

- [ ] **Step 2: Run the full automated test script**

Run: `autohotkey.exe D:\Scripts\ahk\productivity.tests.ahk`

Expected: exit code 0 and `PASS` in `%TEMP%\productivity-test-result.txt`.

- [ ] **Step 3: Run the script parser/startup check**

Run: `autohotkey.exe D:\Scripts\ahk\productivity.ahk`

Expected: the script starts without a syntax-error dialog; stop the prior script instance through its normal single-instance replacement behavior when rerun.

### Task 5: Manual end-to-end verification

**Files:**
- Verify: `ahk/productivity.ahk`
- Verify: `ahk/save-clipboard-image.ps1`

- [ ] **Step 1: Verify text behavior**

Copy formatted text, focus a text editor, and press `Ctrl+Shift+V`.

Expected: unformatted text is inserted and the tooltip says `已粘贴纯文本`.

- [ ] **Step 2: Verify Explorer image saving**

Copy a screenshot, focus a normal filesystem directory in Explorer, and press `Ctrl+Shift+V`.

Expected: a valid `Clipboard-yyyyMMdd-HHmmss.png` appears in that directory and the tooltip reports its filename.

- [ ] **Step 3: Verify collision protection**

Press `Ctrl+Shift+V` twice within one second with the same image clipboard.

Expected: the second file receives `-1` (or the next available integer) and the first file remains unchanged.

- [ ] **Step 4: Verify non-Explorer image behavior**

Copy an image, focus an application that supports image paste, and press `Ctrl+Shift+V`.

Expected: the application receives a normal `Ctrl+V` image paste and no PNG file is created by the helper.

## Environment note

`D:\Scripts` is not a Git repository, so the commit steps normally required between tasks are intentionally omitted. No repository history can be created without expanding the requested scope.
