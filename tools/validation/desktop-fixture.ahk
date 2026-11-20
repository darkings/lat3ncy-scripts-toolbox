#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include ..\..\shared\notify\translation-panel.ahk

; Opt-in visible fixture. Controls are operated by a person or Computer Use;
; this app does not inject keys, capture other windows, or call voice services.
protocolMode := A_Args.Length = 2 && A_Args[1] = "--protocol-smoke"
if (A_Args.Length != 1 && !protocolMode)
    ExitApp 2

global EvidenceFile := A_Args[protocolMode ? 2 : 1]
global InitialClipboard := ClipboardAll()
global SourceText := "Toolbox speech validation. This is a fixed test sentence for checking interruption and recovery. "
    . "The second request should replace the first request and finish normally. "
    . "这里是固定测试文本，用于验证中英文朗读以及连续打断。"
global LongResult := ""
loop 180
    LongResult .= Format("{:03}", A_Index) " 固定译文 clipboard validation 🙂 | 保留换行`r`n"
LongResult .= "END-OF-FIXTURE-🙂"
OnExit RestoreOwnedClipboard
if protocolMode
    ExitApp RunPanelProtocolSmoke()

global FixtureWindow := Gui(, "Toolbox desktop validation fixture")
FixtureWindow.SetFont("s11", "Segoe UI")
FixtureWindow.AddText("w740", "固定选区：点击文本框、Ctrl+A，再用 Caps+S 验证实际常驻快捷键。")
FixtureWindow.AddEdit("w740 r6 ReadOnly", SourceText)
FixtureWindow.AddButton("w225", "检查剪贴板是否恢复").OnEvent("Click", CheckRestored)
FixtureWindow.AddButton("x+12 w225", "打开长译文测试面板").OnEvent("Click", OpenLongPanel)
FixtureWindow.AddButton("xm w225", "校验面板复制完整性").OnEvent("Click", CheckCopied)
FixtureWindow.AddButton("x+12 w225", "恢复剪贴板并退出").OnEvent("Click", (*) => ExitApp())
global StatusText := FixtureWindow.AddText("xm w740 r3", "尚未验证。结果仅记录布尔值和长度，不保存原剪贴板。")
FixtureWindow.OnEvent("Close", (*) => ExitApp())
FixtureWindow.Show()
Record("fixture-ready", "monitors=" MonitorGetCount() " expected_chars=" StrLen(LongResult))

Record(name, detail) {
    global EvidenceFile, StatusText
    line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " " name " " detail
    FileAppend line "`n", EvidenceFile, "UTF-8-RAW"
    StatusText.Text := line
}

CheckRestored(*) {
    global InitialClipboard
    current := ClipboardAll()
    same := current.Size = InitialClipboard.Size
        && (!current.Size || DllCall("msvcrt\memcmp", "Ptr", current.Ptr, "Ptr", InitialClipboard.Ptr, "UPtr", current.Size, "CDecl Int") = 0)
    Record("clipboard-restored", "passed=" (same ? "true" : "false"))
}

OpenLongPanel(*) {
    global SourceText, LongResult, FixtureWindow
    WinGetPos &x, &y, &w, &h, FixtureWindow.Hwnd
    opened := TranslationPanel.Send("PANEL|OPEN|" (x + w // 2) "|" (y + h // 2) "|0|explicit|explicit|" SourceText)
    delivered := opened && TranslationPanel.SetResult(LongResult)
    Record("long-panel-delivery", "passed=" (delivered ? "true" : "false"))
}

CheckCopied(*) {
    global LongResult
    actual := A_Clipboard
    Record("long-result-copy", "passed=" (actual == LongResult ? "true" : "false") " chars=" StrLen(actual))
}

RestoreOwnedClipboard(*) {
    global SourceText, LongResult, InitialClipboard
    ; Preserve unrelated clipboard changes made while the fixture was open.
    current := A_Clipboard
    if (current == SourceText || current == LongResult)
        A_Clipboard := InitialClipboard
}

RunPanelProtocolSmoke() {
    global SourceText, LongResult, EvidenceFile
    passed := false
    try {
        ; Explicit opt-in integration API: the resident owns the real Unicode
        ; clipboard writer. It does not depend on tool-window UI enumeration.
        if !TranslationPanel.FindWindow()
            throw Error("hud-unavailable")
        if !TranslationPanel.Send("PANEL|OPEN|100|100|0|explicit|explicit|" SourceText)
            throw Error("open-unavailable")
        if !TranslationPanel.SetResult(LongResult)
            throw Error("result-unavailable")
        if !TranslationPanel.SendExisting("PANEL|COPY|result")
            throw Error("copy-unavailable")
        copied := A_Clipboard == LongResult
        FileAppend "protocol-copy passed=" (copied ? "true" : "false") " chars=" StrLen(A_Clipboard) "`n", EvidenceFile, "UTF-8-RAW"
        TranslationPanel.SetResult("")
        TranslationPanel.SendExisting("PANEL|COPY|result")
        preserved := A_Clipboard == LongResult
        FileAppend "empty-copy-preserved passed=" (preserved ? "true" : "false") "`n", EvidenceFile, "UTF-8-RAW"
        TranslationPanel.Close()
        TranslationPanel.SetResult("Fixed late fixture result.")
        stayedClosed := !TranslationPanel.IsOpen()
        FileAppend "late-result-stayed-closed passed=" (stayedClosed ? "true" : "false") "`n", EvidenceFile, "UTF-8-RAW"
        passed := copied && preserved && stayedClosed
    } catch {
        FileAppend "protocol-smoke passed=false`n", EvidenceFile, "UTF-8-RAW"
    } finally {
        TranslationPanel.Close()
        RestoreOwnedClipboard()
    }
    return passed ? 0 : 1
}
