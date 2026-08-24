#Requires AutoHotkey v2.0
#Include ..\renderer.ahk

logFile := A_Temp "\gui-measure.log"
if FileExist(logFile)
    FileDelete(logFile)
Log(msg) => FileAppend(msg "`n", logFile, "UTF-8")

Log("=== GUI vs GDI width comparison ===")
Log("IconSize=" NotifyRenderer.IconSize " TextSize=" NotifyRenderer.TextSize)

; 创建隐藏 GUI 测试真实渲染宽度
TestGuiMeasure(glyph, font, size, isIcon := true) {
    g := Gui("-Caption +ToolWindow")
    g.MarginX := 0
    g.MarginY := 0
    if (isIcon)
        g.SetFont("s" NotifyRenderer.IconSize " Bold", font)
    else
        g.SetFont("s" NotifyRenderer.TextSize " Bold", font)
    ctrl := g.AddText("x0 y0", glyph)
    ; 需要 Show 才能正确测量？尝试不 Show 时 GetPos 可能 0，使用 GDI 后备
    ; 先尝试 GetPos 不 Show
    ctrl.GetPos(&x, &y, &w, &h)
    Log(Format("  GDI hidden: glyph='{1}' U+{2:04X} font='{3}' GetPos w={4} h={5}", glyph, Ord(glyph), font, w, h))
    ; 再 Show 隐藏窗口测量
    g.Show("x0 y0 w200 h100 Hide")
    ctrl.GetPos(&x2, &y2, &w2, &h2)
    Log(Format("    after Show(Hide): w={1} h={2}", w2, h2))
    g.Destroy()

    gdiW := isIcon ? NotifyRenderer.MeasureIconWidth(glyph, font) : NotifyRenderer.MeasureTextWidth(glyph)
    Log(Format("    GDI Measure: {1} diff={2}", gdiW, w2 - gdiW))
    Log("")
}

Log("--- Icon glyphs ---")
for icon in ["✓","×","!","↑","↓","↔","●","▣"] {
    resolved := NotifyRenderer.ResolveIcon(icon)
    TestGuiMeasure(resolved["glyph"], resolved["font"], NotifyRenderer.IconSize, true)
}

Log("--- Text samples ---")
for txt in ["OK","成功","Hi","CapsLock"] {
    TestGuiMeasure(txt, NotifyRenderer.TextFontName, NotifyRenderer.TextSize, false)
}

Log("--- Extra: Segoe Fluent Icons at different sizes ---")
for sz in [9,10,11,12,14] {
    g := Gui("-Caption +ToolWindow")
    g.SetFont("s" sz " Bold", "Segoe Fluent Icons")
    ctrl := g.AddText("x0 y0", Chr(0xE930))
    g.Show("Hide")
    ctrl.GetPos(&x,&y,&w,&h)
    Log(Format("  size {1}pt -> w={2} h={3}", sz, w, h))
    g.Destroy()
}

Log("Done")
FileAppend("Done`n", logFile)
ExitApp 0
