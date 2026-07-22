# Script Toolbox Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the maintainable scripts from `D:\Scripts` into this repository, split the AutoHotkey script into independently enabled features with centralized shortcut configuration, improve Smart Paste routing, and make the OCR launchers portable.

**Architecture:** `ahk/main.ahk` is the only AutoHotkey entry point and enables features through commentable `#Include` lines; `ahk/shortcuts.ahk` owns shortcut strings while each namespaced feature owns its implementation. Smart Paste classifies clipboard content before dispatch and keeps its PowerShell image encoder beside the feature. The OCR tool lives independently under `tools/` with relative launchers and documented external dependencies.

**Tech Stack:** AutoHotkey v2, Win32 clipboard APIs, Windows Shell COM, Windows PowerShell 5.1, Python 3.12, Pillow, pytesseract, Tesseract OCR, Git.

---

## File structure

- Create `.gitignore`: ignore Python caches, OCR runtime artifacts, local language models, and Windows shortcuts.
- Create `README.md`: repository setup, AutoHotkey configuration, tests, and OCR overview.
- Create `ahk/main.ahk`: process directives, shared registration contract, test-mode guard, and commentable feature includes.
- Create `ahk/shortcuts.ahk`: centralized default hotkey strings.
- Create `ahk/features/caps-lock-ime.ahk`: Caps Lock state machine and IME control.
- Create `ahk/features/always-on-top.ahk`: active-window topmost toggle.
- Create `ahk/features/search-selected-text.ahk`: selected-text capture, URL encoding, and Google search.
- Create `ahk/features/open-selected-target.ahk`: normalize, classify, and open a selected URL/path.
- Create `ahk/features/locate-selected-target.ahk`: normalize, classify, and locate a selected filesystem target.
- Create `ahk/features/toggle-hidden-files.ahk`: Explorer hidden-file state and refresh.
- Create `ahk/features/smart-paste/smart-paste.ahk`: clipboard classification, dispatch, Explorer lookup, and helper invocation.
- Create `ahk/features/smart-paste/save-clipboard-image.ps1`: collision-safe PNG encoding with temporary-file cleanup.
- Create `ahk/tests/run-tests.ahk`: pure behavior and source-boundary assertions.
- Create `tools/screenshot-ocr/screenshot_ocr.py`: migrated OCR implementation.
- Create `tools/screenshot-ocr/launch.bat`: visible relative Python launcher.
- Create `tools/screenshot-ocr/launch-hidden.ps1`: portable hidden Python launcher.
- Create `tools/screenshot-ocr/README.md`: dependencies, Raycast setup, configuration, and troubleshooting.
- Preserve `docs/superpowers/specs/2026-07-22-clipboard-image-paste-design.md`: relevant historical Smart Paste design.
- Preserve `docs/superpowers/plans/2026-07-22-clipboard-image-paste.md`: relevant historical implementation plan.

### Task 1: Add repository hygiene and failing AutoHotkey contract tests

**Files:**
- Create: `.gitignore`
- Create: `ahk/tests/run-tests.ahk`

- [ ] **Step 1: Add repository ignores**

```gitignore
__pycache__/
*.py[cod]
*.lnk

tools/screenshot-ocr/last_ocr.log
tools/screenshot-ocr/last_capture.png
tools/screenshot-ocr/last_processed.png
tools/screenshot-ocr/tessdata/
```

- [ ] **Step 2: Write the initial failing test harness**

Create `ahk/tests/run-tests.ahk` with assertion helpers, include the future entry point, and exercise the public pure methods:

```ahk
#Requires AutoHotkey v2.0
#Include ..\main.ahk

resultFile := A_Temp "\lat3ncy-toolbox-test-result.txt"
if FileExist(resultFile)
    FileDelete resultFile

AssertEqual(expected, actual, name) {
    global resultFile
    if (expected != actual) {
        FileAppend "FAIL: " name "`nExpected: " expected "`nActual: " actual "`n", resultFile
        ExitApp 1
    }
}

AssertContains(haystack, needle, name) {
    global resultFile
    if !InStr(haystack, needle) {
        FileAppend "FAIL: " name "`nMissing: " needle "`n", resultFile
        ExitApp 1
    }
}

AssertThrows(callback, name) {
    global resultFile
    try callback.Call()
    catch
        return
    FileAppend "FAIL: " name "`nExpected an exception`n", resultFile
    ExitApp 1
}

AssertEqual("toggle-input", CapsLockIme.Action(false, 100), "CapsLock short press")
AssertEqual("enable-caps", CapsLockIme.Action(false, 500), "CapsLock long press")
AssertEqual("disable-caps-force-english", CapsLockIme.Action(true, 100), "CapsLock unlock")
AssertEqual("D:\Code\main.py", OpenSelectedTarget.Normalize('  "D:\Code\main.py:25:8"  '), "normalize target")
AssertEqual("D:\Code\main.py", LocateSelectedTarget.Normalize("file:///D:/Code/main.py"), "normalize file URL")
AssertEqual("plain-text", SmartPaste.ChooseAction(false, false, true, false), "plain text")
AssertEqual("save-image", SmartPaste.ChooseAction(false, true, false, true), "Explorer image")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, true, false, false), "application image")
AssertEqual("normal-paste", SmartPaste.ChooseAction(true, true, true, true), "file list wins")
AssertEqual("normal-paste", SmartPaste.ChooseAction(false, false, false, false), "unknown clipboard")
shortcutRegistry := Map()
ValidateFeatureHotkey("first", "^!a", shortcutRegistry)
AssertThrows(() => ValidateFeatureHotkey("duplicate", "^!a", shortcutRegistry), "duplicate shortcut")
AssertThrows(() => ValidateFeatureHotkey("empty", "", Map()), "empty shortcut")

FileAppend "PASS: core assertions`n", resultFile
ExitApp 0
```

- [ ] **Step 3: Run the harness and verify it fails because the entry point is absent**

Run:

```powershell
AutoHotkey.exe .\ahk\tests\run-tests.ahk --test
```

Expected: nonzero exit or AutoHotkey include error for `ahk\main.ahk`.

- [ ] **Step 4: Commit the red test and ignore rules**

```powershell
git add .gitignore ahk/tests/run-tests.ahk
git commit -m "test: define modular ahk behavior"
```

### Task 2: Implement the AutoHotkey entry contract and simple features

**Files:**
- Create: `ahk/main.ahk`
- Create: `ahk/shortcuts.ahk`
- Create: `ahk/features/always-on-top.ahk`
- Create: `ahk/features/caps-lock-ime.ahk`
- Create: `ahk/features/toggle-hidden-files.ahk`

- [ ] **Step 1: Create centralized shortcut configuration**

```ahk
class Shortcuts {
    static CapsLockIme := "$CapsLock"
    static AlwaysOnTop := "^#t"
    static SearchSelectedText := "^+g"
    static SmartPaste := "^+v"
    static OpenSelectedTarget := "^!o"
    static LocateSelectedTarget := "^!e"
    static ToggleHiddenFiles := "#+."
}
```

- [ ] **Step 2: Create the entry point and duplicate-shortcut guard**

```ahk
#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

global RegisteredFeatureHotkeys := Map()

IsToolboxTestMode() {
    return A_Args.Length && A_Args[1] = "--test"
}

RegisterFeatureHotkey(featureName, shortcut, callback) {
    global RegisteredFeatureHotkeys
    ValidateFeatureHotkey(featureName, shortcut, RegisteredFeatureHotkeys)
    Hotkey shortcut, callback
}

ValidateFeatureHotkey(featureName, shortcut, registry) {
    if (shortcut = "")
        throw Error(featureName " 的快捷键不能为空")
    normalized := StrLower(shortcut)
    if registry.Has(normalized)
        throw Error("快捷键冲突：" shortcut " 同时用于 " registry[normalized] " 和 " featureName)
    registry[normalized] := featureName
    return normalized
}

#Include shortcuts.ahk

#Include features\caps-lock-ime.ahk
#Include features\always-on-top.ahk
#Include features\search-selected-text.ahk
#Include features\smart-paste\smart-paste.ahk
#Include features\open-selected-target.ahk
#Include features\locate-selected-target.ahk
#Include features\toggle-hidden-files.ahk
```

- [ ] **Step 3: Move Caps Lock behavior into its namespace**

Create a `CapsLockIme` class containing the current `CapsLockAction`, `MacCapsLockHandler`, `ForceEnglishIme`, `GetFocusedControlHwnd`, tooltip, and hide-tooltip behavior. Rename `CapsLockAction` to `Action` and the handler to `Handle`; replace calls with `CapsLockIme.Action(...)`, `CapsLockIme.ForceEnglishIme()`, and `CapsLockIme.ShowTip(...)`. End the file with:

```ahk
if !IsToolboxTestMode()
    RegisterFeatureHotkey("Caps Lock / 输入法", Shortcuts.CapsLockIme, CapsLockIme.Handle)
```

- [ ] **Step 4: Create the topmost feature**

```ahk
class AlwaysOnTop {
    static Toggle(*) {
        WinSetAlwaysOnTop -1, "A"
        isTopmost := (WinGetExStyle("A") & 0x8) != 0
        this.ShowTip(isTopmost ? "窗口已置顶" : "已取消置顶")
    }

    static ShowTip(message) {
        ToolTip message
        SetTimer () => ToolTip(), -1500
    }
}

if !IsToolboxTestMode()
    RegisterFeatureHotkey("窗口置顶", Shortcuts.AlwaysOnTop, AlwaysOnTop.Toggle)
```

- [ ] **Step 5: Move hidden-file behavior into its namespace**

Create `ToggleHiddenFiles` with static methods `Action`, `Toggle`, `RefreshExplorerWindows`, and `ShowTip`, preserving the existing registry value mapping, Shell COM refresh, and `WM_SETTINGCHANGE` broadcast. End the file with:

```ahk
if !IsToolboxTestMode()
    RegisterFeatureHotkey("显示隐藏文件", Shortcuts.ToggleHiddenFiles, ToggleHiddenFiles.Toggle)
```

- [ ] **Step 6: Run the harness to expose the remaining missing feature includes**

Run: `AutoHotkey.exe .\ahk\tests\run-tests.ahk --test`

Expected: fail on `search-selected-text.ahk`, the next not-yet-created include.

- [ ] **Step 7: Commit the entry contract and first modules**

```powershell
git add ahk/main.ahk ahk/shortcuts.ahk ahk/features/always-on-top.ahk ahk/features/caps-lock-ime.ahk ahk/features/toggle-hidden-files.ahk
git commit -m "feat: add modular ahk entry point"
```

### Task 3: Split selected-text and target features

**Files:**
- Create: `ahk/features/search-selected-text.ahk`
- Create: `ahk/features/open-selected-target.ahk`
- Create: `ahk/features/locate-selected-target.ahk`
- Modify: `ahk/tests/run-tests.ahk`

- [ ] **Step 1: Add failing target and encoding assertions**

Append before the PASS line:

```ahk
AssertEqual("https://example.com/a", OpenSelectedTarget.Normalize("https://example.com/a"), "keep URL")
AssertEqual("url", OpenSelectedTarget.Classify("https://example.com/a"), "classify URL")
AssertEqual("hello%20%E4%B8%AD%E6%96%87", SearchSelectedText.UriEncode("hello 中文"), "UTF-8 URL encoding")
```

Run: `AutoHotkey.exe .\ahk\tests\run-tests.ahk --test`

Expected: fail because the three feature files are absent.

- [ ] **Step 2: Create selected-text search**

Create class `SearchSelectedText` and move the existing selection-copy, UTF-8 `UriEncode`, `ShortText`, tooltip, and Google search behavior into static methods. The handler must save `ClipboardAll()`, clear and copy the selection, open `https://www.google.com/search?q=` plus encoded text, restore the clipboard in `finally`, and register with:

```ahk
if !IsToolboxTestMode()
    RegisterFeatureHotkey("搜索选中文字", Shortcuts.SearchSelectedText, SearchSelectedText.Search)
```

- [ ] **Step 3: Create the self-contained open-target feature**

Create class `OpenSelectedTarget` with static methods `Normalize`, `Classify`, `GetSelected`, `Open`, `ShortText`, `TargetLabel`, and `ShowTip`. Preserve ordinary `Ctrl+C`, VS Code `Shift+Alt+C` fallback, clipboard restoration, file URL conversion, line/column removal, and URL/file/directory opening. Register `OpenSelectedTarget.Open` with `Shortcuts.OpenSelectedTarget`.

- [ ] **Step 4: Create the self-contained locate-target feature**

Create class `LocateSelectedTarget` with its own static `Normalize`, `Classify`, `GetSelected`, `Locate`, `ShortText`, `TargetLabel`, and `ShowTip` methods. Files run through `explorer.exe /select,"<path>"`; directories open directly; URLs are rejected. Register `LocateSelectedTarget.Locate` with `Shortcuts.LocateSelectedTarget`.

- [ ] **Step 5: Run the harness and verify the next failure is Smart Paste**

Run: `AutoHotkey.exe .\ahk\tests\run-tests.ahk --test`

Expected: fail only because `smart-paste.ahk` is absent.

- [ ] **Step 6: Commit the selected-content modules**

```powershell
git add ahk/features/search-selected-text.ahk ahk/features/open-selected-target.ahk ahk/features/locate-selected-target.ahk ahk/tests/run-tests.ahk
git commit -m "feat: split selected content actions"
```

### Task 4: Implement improved Smart Paste with red-green coverage

**Files:**
- Create: `ahk/features/smart-paste/smart-paste.ahk`
- Create: `ahk/features/smart-paste/save-clipboard-image.ps1`
- Modify: `ahk/tests/run-tests.ahk`

- [ ] **Step 1: Complete failing Smart Paste assertions**

Add assertions for priority and source boundaries:

```ahk
AssertEqual("normal-paste", SmartPaste.ChooseAction(true, false, true, true), "file list before text")
AssertEqual("plain-text", SmartPaste.ChooseAction(false, false, true, true), "text in Explorer")
smartPasteSource := FileRead(A_ScriptDir "\..\features\smart-paste\smart-paste.ahk", "UTF-8")
AssertContains(smartPasteSource, 'IsClipboardFormatAvailable", "UInt", 15', "detect CF_HDROP")
AssertContains(smartPasteSource, 'RegisterClipboardFormat", "Str", "PNG"', "detect PNG format")
```

Run: `AutoHotkey.exe .\ahk\tests\run-tests.ahk --test`

Expected: fail because `SmartPaste` is undefined.

- [ ] **Step 2: Implement classification and dispatch**

Create class `SmartPaste` with this pure decision function:

```ahk
static ChooseAction(hasFiles, hasImage, hasText, isExplorer) {
    if hasFiles
        return "normal-paste"
    if hasImage
        return isExplorer ? "save-image" : "normal-paste"
    if hasText
        return "plain-text"
    return "normal-paste"
}
```

Add `HasFiles()` using `CF_HDROP` (15), `HasImage()` using formats 2, 8, 17 plus `RegisterClipboardFormat("PNG")`, `HasText()` using formats 1 and 13, and `GetActiveExplorerPath()` using the active `CabinetWClass` HWND and `Shell.Application`. `Paste(*)` must compute all four inputs once, call `ChooseAction`, then use `SendText A_Clipboard`, `Send "^v"`, or `SaveClipboardImage(path)`.

- [ ] **Step 3: Add collision-safe PowerShell encoding**

Create the helper with parameters `Destination` and `ResultFile`. Validate `Destination` is an existing directory and the clipboard still contains an image. Allocate a unique final name, save into a unique `.tmp` file in that same directory with `FileMode.CreateNew`, close the stream, then call `[IO.File]::Move($temporaryPath, $outputPath)` and write the final path to `ResultFile` as UTF-8 without BOM. In `catch`, remove the temporary file; in `finally`, dispose image and stream objects.

- [ ] **Step 4: Connect AHK to the helper**

`SmartPaste.SaveClipboardImage(destination)` must resolve the helper as `A_ScriptDir "\features\smart-paste\save-clipboard-image.ps1"` because `A_ScriptDir` refers to the entry script rather than the included feature file. It creates a process-specific result file under `A_Temp`, invokes Windows PowerShell with `-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass`, validates exit code and returned output path, shows the saved filename, and deletes the result file in `finally`. If the active Explorer window is virtual, show `当前资源管理器位置无法保存图片` instead of launching PowerShell.

Register with:

```ahk
if !IsToolboxTestMode()
    RegisterFeatureHotkey("智能粘贴", Shortcuts.SmartPaste, SmartPaste.Paste)
```

- [ ] **Step 5: Parse the PowerShell helper**

Run:

```powershell
$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path '.\ahk\features\smart-paste\save-clipboard-image.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count) { $errors | Format-List; exit 1 }
```

Expected: exit code 0 with no parser errors.

- [ ] **Step 6: Run the full AHK harness**

Run:

```powershell
Remove-Item "$env:TEMP\lat3ncy-toolbox-test-result.txt" -ErrorAction SilentlyContinue
AutoHotkey.exe .\ahk\tests\run-tests.ahk --test
Get-Content "$env:TEMP\lat3ncy-toolbox-test-result.txt"
```

Expected: exit code 0 and `PASS: core assertions`.

- [ ] **Step 7: Commit Smart Paste**

```powershell
git add ahk/features/smart-paste ahk/tests/run-tests.ahk
git commit -m "feat: add clipboard-aware smart paste"
```

### Task 5: Migrate OCR source and create portable launchers

**Files:**
- Create: `tools/screenshot-ocr/screenshot_ocr.py`
- Create: `tools/screenshot-ocr/launch.bat`
- Create: `tools/screenshot-ocr/launch-hidden.ps1`
- Create: `tools/screenshot-ocr/README.md`

- [ ] **Step 1: Copy the maintained Python source only**

Copy `D:\Scripts\bat\raycast-ocr\screenshot_ocr.py` to `tools/screenshot-ocr/screenshot_ocr.py`. Preserve the current selection UI, preprocessing, multi-PSM recognition, clipboard copying, notifications, logging, environment variables, and Tesseract discovery. Remove the machine-specific `D:\Applications\Scoop\shims\tesseract.exe` entry from `COMMON_TESSERACT_PATHS`; keep the two standard Program Files locations and the `shutil.which("tesseract")` fallback. Do not copy captures, logs, caches, shortcuts, or `tessdata` binaries.

- [ ] **Step 2: Create a relative visible launcher**

```bat
@echo off
setlocal
python "%~dp0screenshot_ocr.py"
exit /b %errorlevel%
```

- [ ] **Step 3: Create a portable hidden launcher**

```powershell
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'screenshot_ocr.py'
$quotedScriptPath = '"' + $scriptPath + '"'
$python = Get-Command pythonw.exe -ErrorAction SilentlyContinue

if ($python) {
    Start-Process -FilePath $python.Source -ArgumentList @($quotedScriptPath) -WindowStyle Hidden
    exit 0
}

$py = Get-Command pyw.exe -ErrorAction SilentlyContinue
if ($py) {
    Start-Process -FilePath $py.Source -ArgumentList @('-3', $quotedScriptPath) -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName PresentationFramework
[Windows.MessageBox]::Show(
    '未找到 pythonw.exe 或 pyw.exe。请安装 Python 3 并启用 PATH。',
    'Screenshot OCR'
) | Out-Null
exit 1
```

- [ ] **Step 4: Write OCR-specific documentation**

Document `python -m pip install pillow pytesseract`, `winget install UB-Mannheim.TesseractOCR`, Chinese language-data installation, `launch.bat`, `launch-hidden.ps1`, Raycast setup, `OCR_LANG`, `OCR_PSM`, `TESSERACT_CMD`, generated debug artifacts, and diagnostics through `last_ocr.log`.

- [ ] **Step 5: Verify source and launcher portability**

Run:

```powershell
python -m compileall -q .\tools\screenshot-ocr\screenshot_ocr.py
$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path '.\tools\screenshot-ocr\launch-hidden.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count) { $errors | Format-List; exit 1 }
if (rg -n -F 'D:\Scripts' tools/screenshot-ocr) { exit 1 }
if (rg -n -F 'D:\Applications\Scoop' tools/screenshot-ocr) { exit 1 }
if (rg -n -F 'python312\current' tools/screenshot-ocr) { exit 1 }
```

Expected: exit code 0, no parser errors, and no hard-coded source or Python installation paths.

- [ ] **Step 6: Commit the portable OCR tool**

```powershell
git add tools/screenshot-ocr .gitignore
git commit -m "feat: add portable screenshot ocr tool"
```

### Task 6: Migrate relevant history and write repository documentation

**Files:**
- Create: `README.md`
- Create: `docs/superpowers/specs/2026-07-22-clipboard-image-paste-design.md`
- Create: `docs/superpowers/plans/2026-07-22-clipboard-image-paste.md`

- [ ] **Step 1: Preserve the existing Smart Paste design and plan**

Copy the two Markdown files from `D:\Scripts\docs\superpowers\` to the corresponding repository directories without copying any other runtime artifacts. Add a short note at the top of each stating that paths describe the pre-migration layout and that the current structure is documented in the toolbox migration design.

- [ ] **Step 2: Write the root README**

Include:

```markdown
# lat3ncy-scripts-toolbox

Windows productivity scripts built around AutoHotkey v2 and a standalone screenshot OCR tool.

## AutoHotkey

Run `ahk/main.ahk`. Comment or uncomment feature `#Include` lines in that file to disable or enable behavior. Change shortcut strings only in `ahk/shortcuts.ahk`.

## Tests

```powershell
AutoHotkey.exe .\ahk\tests\run-tests.ahk --test
Get-Content "$env:TEMP\lat3ncy-toolbox-test-result.txt"
```

## Screenshot OCR

See `tools/screenshot-ocr/README.md`.
```

Expand the AutoHotkey section with a table of all default shortcuts and feature filenames, installation prerequisites, startup guidance, and Smart Paste routing.

- [ ] **Step 3: Verify the documented paths exist**

Run:

```powershell
$required = @(
    'ahk/main.ahk',
    'ahk/shortcuts.ahk',
    'ahk/tests/run-tests.ahk',
    'tools/screenshot-ocr/README.md'
)
$missing = $required | Where-Object { -not (Test-Path -LiteralPath $_) }
if ($missing) { $missing; exit 1 }
```

Expected: exit code 0 and no missing paths.

- [ ] **Step 4: Commit documentation and history**

```powershell
git add README.md docs/superpowers
git commit -m "docs: document toolbox setup"
```

### Task 7: Full verification and manual handoff

**Files:**
- Verify: all repository files

- [ ] **Step 1: Run all automated verification from a clean prompt**

```powershell
git diff --check
Remove-Item "$env:TEMP\lat3ncy-toolbox-test-result.txt" -ErrorAction SilentlyContinue
AutoHotkey.exe .\ahk\tests\run-tests.ahk --test
Get-Content "$env:TEMP\lat3ncy-toolbox-test-result.txt"
python -m compileall -q .\tools\screenshot-ocr\screenshot_ocr.py
$files = @(
    '.\ahk\features\smart-paste\save-clipboard-image.ps1',
    '.\tools\screenshot-ocr\launch-hidden.ps1'
)
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { $errors | Format-List; exit 1 }
}
if (rg -n -F 'D:\Scripts' ahk tools README.md) { exit 1 }
if (rg -n -F 'D:\Applications\Scoop' ahk tools README.md) { exit 1 }
if (rg -n -F 'python312\current' ahk tools README.md) { exit 1 }
git status --short
```

Expected: `git diff --check` clean; AHK result says PASS; Python and PowerShell checks exit 0; hard-coded path checks find nothing; status is clean after the task commits.

- [ ] **Step 2: Run startup smoke checks without leaving processes behind**

Start `ahk/main.ahk`, verify no syntax or duplicate-hotkey dialog appears, then stop that exact AutoHotkey process normally. Run `tools/screenshot-ocr/launch.bat`, press Escape at the selector, and verify it exits without an error notification.

- [ ] **Step 3: Perform the focused manual Smart Paste matrix**

Verify plain text in an editor, an image in a filesystem Explorer window, an image in an image-capable application, copied files in Explorer, and an image in a virtual Explorer location. Confirm clipboard restoration for selection-based features and confirm PNG collision handling does not overwrite an existing file.

- [ ] **Step 4: Review the final diff against the approved design**

Check every requirement in `docs/superpowers/specs/2026-07-22-script-toolbox-migration-design.md` against the resulting files and report any manual checks that could not be performed.
