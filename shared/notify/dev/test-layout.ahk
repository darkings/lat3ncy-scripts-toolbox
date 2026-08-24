#Requires AutoHotkey v2.0
#Include ..\renderer.ahk
#Include ..\notify.ahk

logFile := A_Temp "\notify-layout-test.log"
if FileExist(logFile)
    FileDelete(logFile)

Log(msg) {
    global logFile
    FileAppend(msg "`n", logFile, "UTF-8")
}

Log("=== NotifyRenderer Layout Fix Test ===")
Log("Time: " A_Now)
Log("Renderer constants:")
Log("  TextSize=" NotifyRenderer.TextSize " IconSize=" NotifyRenderer.IconSize " PaddingX=" NotifyRenderer.PaddingX " IconGap=" NotifyRenderer.IconGap " MinWidth=" NotifyRenderer.MinWidth " MaxWidth=" NotifyRenderer.MaxWidth)
Log("")

; 测试 1: MeasureIconWidth 对不同 glyph 的差异
Log("---- Test 1: MeasureIconWidth (should differ, not fixed 16) ----")
for icon in ["✓", "×", "!", "↑", "↓", "↔", "⇪", "●", "▣", "○"] {
    resolved := NotifyRenderer.ResolveIcon(icon)
    glyph := resolved["glyph"]
    font := resolved["font"]
    w := NotifyRenderer.MeasureIconWidth(glyph, font)
    Log(Format("  icon='{1}' glyph=U+{2:04X} font='{3}' width={4}", icon, Ord(glyph), font, w))
}
Log("")

; 测试不同 glyph 的原始码点
Log("---- Test 1b: IconMap glyph widths ----")
for k, v in NotifyRenderer.IconMap {
    w := NotifyRenderer.MeasureIconWidth(v, NotifyRenderer.IconFontName)
    Log(Format("  IconMap['{1}'] -> U+{2:04X} width={3}", k, Ord(v), w))
}
Log("")

; 测试 2: MeasureTextWidth
Log("---- Test 2: MeasureTextWidth ----")
for txt in ["OK", "成功", "CapsLock", "大写锁定已开启", "Hello World", "OK OK OK OK OK OK OK OK OK OK OK OK"] {
    w := NotifyRenderer.MeasureTextWidth(txt)
    Log(Format("  text='{1}' len={2} width={3}", txt, StrLen(txt), w))
}
Log("")

; 测试 3: 宽度计算对比（旧逻辑 vs 新逻辑）
Log("---- Test 3: Width calculation (old fixed 16 vs new measured) ----")
CompareWidth(icon, text) {
    resolved := NotifyRenderer.ResolveIcon(icon)
    glyph := resolved["glyph"]
    font := resolved["font"]
    iconW := NotifyRenderer.MeasureIconWidth(glyph, font)
    textW := NotifyRenderer.MeasureTextWidth(text)
    oldWidth := Min(NotifyRenderer.MaxWidth, Max(NotifyRenderer.MinWidth, NotifyRenderer.PaddingX*2 + 16 + NotifyRenderer.IconGap + textW))
    contentW := iconW + NotifyRenderer.IconGap + textW
    newWidth := Min(NotifyRenderer.MaxWidth, Max(NotifyRenderer.MinWidth, NotifyRenderer.PaddingX*2 + contentW))
    Log(Format("  icon='{1}' text='{2}' iconW={3} textW={4} oldWidth={5} newWidth={6} delta={7}", icon, text, iconW, textW, oldWidth, newWidth, newWidth-oldWidth))
    if (iconW != 16) {
        if (newWidth != oldWidth)
            Log("    -> 修复生效: 真实icon宽度导致旧计算偏差 " newWidth-oldWidth "px (右空间不足已修复)")
        else
            Log("    -> 宽度相同 (可能因 MinWidth 截断)")
    }
}
CompareWidth("✓", "成功")
CompareWidth("×", "失败")
CompareWidth("↑", "大写")
CompareWidth("↔", "切换")
CompareWidth("✓", "OK")
CompareWidth("✓", "OK OK OK OK OK OK OK OK OK OK OK OK OK OK OK OK OK OK")
Log("")

; 测试 4: MinWidth 视觉居中
Log("---- Test 4: MinWidth centering (short message) ----")
TestMinWidthCentering(icon, text) {
    resolved := NotifyRenderer.ResolveIcon(icon)
    glyph := resolved["glyph"]
    font := resolved["font"]
    iconW := NotifyRenderer.MeasureIconWidth(glyph, font)
    textW := NotifyRenderer.MeasureTextWidth(text)
    contentW := iconW + NotifyRenderer.IconGap + textW
    width := Min(NotifyRenderer.MaxWidth, Max(NotifyRenderer.MinWidth, NotifyRenderer.PaddingX*2 + contentW))
    extra := width - NotifyRenderer.PaddingX*2 - contentW
    if (extra < 0)
        extra := 0
    iconX := NotifyRenderer.PaddingX + Floor(extra/2)
    textX := iconX + iconW + NotifyRenderer.IconGap
    leftPad := iconX
    rightPad := width - (textX + textW)
    Log(Format("  icon='{1}' text='{2}' contentW={3} width={4} extra={5} iconX={6} textX={7} leftPad={8} rightPad={9} diff={10}", icon, text, contentW, width, extra, iconX, textX, leftPad, rightPad, Abs(leftPad-rightPad)))
    if (Abs(leftPad - rightPad) <= 2)
        Log("    -> 居中良好 (左右差 <=2px)")
    else
        Log("    -> 居中偏差 " Abs(leftPad-rightPad) "px")
}
TestMinWidthCentering("✓", "OK")
TestMinWidthCentering("✓", "成功")
TestMinWidthCentering("×", "失败")
TestMinWidthCentering("✓", "Hi")
Log("")

; 测试 5: 超长文本换行
Log("---- Test 5: Long text wrapping ----")
longText := "这是一个非常长的通知文本，用于测试超过MaxWidth时的换行逻辑是否正确，MaxWidth=" NotifyRenderer.MaxWidth
w := NotifyRenderer.MeasureTextWidth(longText)
Log("  longText width=" w " MaxWidth=" NotifyRenderer.MaxWidth)
iconW := NotifyRenderer.MeasureIconWidth(NotifyRenderer.ResolveIcon("✓")["glyph"], NotifyRenderer.IconFontName)
maxTextW := NotifyRenderer.MaxWidth - NotifyRenderer.PaddingX*2 - iconW - NotifyRenderer.IconGap
Log("  iconW=" iconW " maxTextW=" maxTextW " textW>maxTextW? " (w>maxTextW ? "YES 需要换行" : "NO"))
Log("")

; 测试 6: 验证布局代码特征
Log("---- Test 6: Layout code verification ----")
rendererSource := FileRead(A_ScriptDir "\..\renderer.ahk", "UTF-8")
checks := [
    ["MeasureIconWidth", "新增 MeasureIconWidth 方法"],
    ["Center 0x200", "垂直居中 0x200"],
    ["y0 w", "绝对定位 y0"],
    ["iconX +", "绝对坐标计算 (非 x+)"],
    ["extra / 2", "MinWidth 额外空间均分居中"],
    ["PaddingX * 2 + contentW", "修复固定16的宽度计算"]
]
for pair in checks {
    needle := pair[1]
    desc := pair[2]
    found := InStr(rendererSource, needle) ? "PASS" : "FAIL"
    Log(Format("  [{1}] {2} : {3}", found, desc, needle))
}
; 确保旧的 buggy 模式已移除
if InStr(rendererSource, "PaddingX * 2 + 16 +") {
    Log("  [FAIL] 仍存在旧的 PaddingX*2+16 硬编码")
} else {
    Log("  [PASS] 已移除 PaddingX*2+16 硬编码")
}
if InStr(rendererSource, 'x+" this.IconGap') || InStr(rendererSource, "x+`"") {
    Log("  [WARN] 仍存在 x+ 相对定位 (应已改为绝对)")
} else {
    Log("  [PASS] 已移除 x+ 相对定位依赖")
}
if InStr(rendererSource, "GetPos(") {
    Log("  [WARN] 仍存在 GetPos 依赖 (应改为预测量)")
} else {
    Log("  [PASS] 已移除 GetPos 依赖")
}
Log("")

Log("=== All layout tests completed ===")
Log("Log file: " logFile)

; 尝试实际展示通知（如果处于交互桌面，用户可目视验证）
try {
    Log("")
    Log("---- Visual demo (5 notifications, 1.2s each) ----")
    Notify.Success("✓", "成功", 1200)
    Sleep 1500
    Log("  Show ✓ 成功")

    Notify.Success("✓", "OK", 1200)
    Sleep 1500
    Log("  Show ✓ OK (short, test MinWidth centering)")

    Notify.Error("×", "失败", 1200)
    Sleep 1500
    Log("  Show × 失败")

    Notify.Info("↑", "大写", 1200)
    Sleep 1500
    Log("  Show ↑ 大写")

    Notify.Success("↔", "切换", 1200)
    Sleep 1500
    Log("  Show ↔ 切换 (wide glyph)")

    ; 超长
    Notify.Info("✓", "这是一个超长文本用于测试换行和MaxWidth截断是否居中", 1500)
    Sleep 1800
    Log("  Show long text wrap test")

    ; TextOnly
    Notify.State("中", "", 1200)
    Sleep 1500
    Log("  Show 中 (textOnly)")

    Log("  Visual demo finished")
} catch as e {
    Log("Visual demo error: " e.Message)
}

ExitApp 0
