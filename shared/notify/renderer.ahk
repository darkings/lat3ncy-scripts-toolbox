#Requires AutoHotkey v2.0
#Include anchor.ahk

; 统一 HUD Renderer — Win11 Mica/Acrylic · 10pt · 深浅色自适应 · 4级输入锚点定位
class NotifyRenderer {
    static FontName := "Segoe UI"
    static IconFontName := "Segoe Fluent Icons"
    static TextFontName := "Microsoft YaHei UI"
    static TextSize := 10
    static IconSize := 12
    static BadgeSize := 24
    static MinWidth := 132
    static MaxWidth := 340
    static PaddingX := 12
    static PaddingY := 8
    static IconGap := 8
    static Radius := 8
    static PositionYRatio := 0.82

    ; 深度优化的深色调色板（Dark Mode）
    static DarkTheme := {
        Bg: "202022",
        Border: "38383A",
        BorderDwm: 0x003A3838,
        Text: "F2F2F7",
        SubText: "A1A1AA",
        IsDark: true,
        TypeBadgeBg: Map(
            "state", "3A3A3C",
            "success", "1F3A2B",
            "info", "1E2F4A",
            "error", "3A1E1E"
        ),
        TypeIconColor: Map(
            "state", "E8E8E8",
            "success", "34D399",
            "info", "60A5FA",
            "error", "F87171"
        )
    }

    ; 极简通透的浅色调色板（Light Mode）
    static LightTheme := {
        Bg: "FFFFFF",
        Border: "E4E4E7",
        BorderDwm: 0x00E7E4E4,
        Text: "18181B",
        SubText: "71717A",
        IsDark: false,
        TypeBadgeBg: Map(
            "state", "F4F4F5",
            "success", "ECFDF5",
            "info", "EFF6FF",
            "error", "FEF2F2"
        ),
        TypeIconColor: Map(
            "state", "52525B",
            "success", "059669",
            "info", "2563EB",
            "error", "DC2626"
        )
    }

    static BackgroundColor => this.DarkTheme.Bg
    static TextColor => this.DarkTheme.Text
    static TypeBadgeBg => this.DarkTheme.TypeBadgeBg
    static TypeIconColor => this.DarkTheme.TypeIconColor

    static GetCurrentTheme() {
        try {
            val := RegRead("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
            if (val == 1)
                return this.LightTheme
        }
        return this.DarkTheme
    }

    static TextOnlySet := Map("中", true, "A", true, "英", true, "CAPS", true, "大写", true, "⇧", true, "⇪", true)
    static IconMap := Map(
        "✓", Chr(0xE930),
        "×", Chr(0xEA39),
        "!", Chr(0xEB90),
        "↑", Chr(0xE74A),
        "↓", Chr(0xE74B),
        "◉", Chr(0xE890),
        "○", Chr(0xE890),
        "↔", Chr(0xE8AB),
        "⇪", Chr(0xE8AB),
        "●", Chr(0xE7C8),
        "▣", Chr(0xE722)
    )

    static _gui := 0
    static _badgeCtrl := 0
    static HideCallback := 0

    static ResolveType(type, theme) {
        type := StrLower(Trim(type))
        if theme.TypeBadgeBg.Has(type)
            return type
        return "state"
    }

    static ResolveIcon(icon) {
        display := icon
        font := this.IconFontName
        if (this.TextOnlySet.Has(icon)) {
            display := icon
            if (icon == "中" || icon == "英" || icon == "大写")
                font := this.TextFontName
            else if (icon == "A" || icon == "CAPS")
                font := this.FontName
            else
                font := this.IconFontName
        } else if (this.IconMap.Has(icon)) {
            display := this.IconMap[icon]
            font := this.IconFontName
        } else {
            if (icon == "中" || icon == "英" || icon == "大写")
                font := this.TextFontName
            else if (icon == "A" || icon == "CAPS")
                font := this.FontName
            else
                font := this.IconFontName
        }
        if (display == "⇪" || display == "⇧")
            display := "CAPS"
        return Map("glyph", display, "font", font)
    }

    static MeasureTextWidth(text) {
        if (text = "")
            return 0
        hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
        if (!hdc)
            return StrLen(text) * 7
        dpi := DllCall("GetDeviceCaps", "Ptr", hdc, "Int", 90, "Int")
        if (!dpi)
            dpi := 96
        height := -DllCall("MulDiv", "Int", this.TextSize, "Int", dpi, "Int", 72, "Int")
        hFont := DllCall("CreateFontW", "Int", height, "Int", 0, "Int", 0, "Int", 0, "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "WStr", this.TextFontName, "Ptr")
        if (!hFont) {
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
            return StrLen(text) * 7
        }
        hOld := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
        size := Buffer(8, 0)
        ok := DllCall("GetTextExtentPoint32W", "Ptr", hdc, "WStr", text, "Int", StrLen(text), "Ptr", size)
        w := ok ? NumGet(size, 0, "Int") : StrLen(text) * 7
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hOld)
        DllCall("DeleteObject", "Ptr", hFont)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
        return w
    }

    static ApplyDwmStyle(hwnd, theme) {
        ok := false
        try {
            isDark := theme.IsDark ? 1 : 0
            DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 20, "Ptr*", isDark, "UInt", 4)
        }
        try {
            corner := 2
            DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 33, "Ptr*", corner, "UInt", 4)
            ok := true
        }
        try {
            borderColor := theme.BorderDwm
            DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 34, "Ptr*", borderColor, "UInt", 4)
        }
        return ok
    }

    static Show(type, icon, text := "", duration := 650) {
        try {
            this.Hide()
            theme := this.GetCurrentTheme()
            resolvedType := this.ResolveType(type, theme)
            iconColor := theme.TypeIconColor[resolvedType]
            textColor := theme.Text

            isTextOnly := false
            displayText := text
            if (this.TextOnlySet.Has(icon) || (icon == "" && this.TextOnlySet.Has(text))) {
                isTextOnly := true
                displayText := icon != "" ? icon : text
                if (displayText == "⇪" || displayText == "⇧")
                    displayText := "CAPS"
            } else if (icon == "中" || icon == "A" || icon == "英" || icon == "CAPS" || icon == "大写") {
                isTextOnly := true
                displayText := icon
            }

            ; 1. 优先捕获瞬时输入锚点（在创建 GUI 前完成定位，杜绝窗口居中闪烁）
            anchor := 0
            if (isTextOnly) {
                anchor := InputAnchor.Get()
            }

            ; 2. 预计算控件尺寸
            if (isTextOnly) {
                width := (displayText == "CAPS") ? 56 : 34
                height := 34
            } else {
                textW := (text != "") ? this.MeasureTextWidth(text) : 0
                width := Min(this.MaxWidth, Max(this.MinWidth, this.PaddingX * 2 + 16 + this.IconGap + textW))
                height := 34
            }

            ; 3. 计算展示坐标
            anchorFound := false
            targetX := 0, targetY := 0
            if (anchor && anchor.confidence >= 50 && anchor.x > 0 && anchor.y > 0) {
                anchorFound := true
                monitor := this.GetMonitorFromPoint(anchor.x, anchor.y)
                MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)

                calcX := anchor.x - Floor(width / 2)
                calcY := anchor.y + 8

                if (calcX + width > right - 8)
                    calcX := right - 8 - width
                if (calcX < left + 8)
                    calcX := left + 8

                if (calcY + height > bottom - 8)
                    calcY := anchor.y - anchor.h - height - 8

                if (calcY < top + 8)
                    calcY := top + 8

                targetX := calcX
                targetY := calcY
            }

            if (anchorFound) {
                x := targetX
                y := targetY
            } else {
                monitor := this.GetActiveMonitor()
                MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
                x := left + Floor((right - left - width) / 2)
                y := top + Floor((bottom - top) * this.PositionYRatio) - Floor(height / 2)
            }

            ; 4. 创建 GUI 并直接以最终坐标展现（单次呈现，零跳跃零闪烁）
            hud := Gui("+AlwaysOnTop -Caption +ToolWindow")
            hud.BackColor := theme.Bg
            hud.MarginX := this.PaddingX
            hud.MarginY := this.PaddingY
            dwmOk := this.ApplyDwmStyle(hud.Hwnd, theme)

            if (isTextOnly) {
                font := (displayText == "A" || displayText == "CAPS") ? this.FontName : this.TextFontName
                hud.SetFont("s" this.TextSize " Bold c" textColor, font)
                hud.AddText("x" this.PaddingX " y" this.PaddingY " Center", displayText)
            } else {
                resolved := this.ResolveIcon(icon)
                glyph := resolved["glyph"]
                iconFont := resolved["font"]

                hud.SetFont("s" this.IconSize " Bold c" iconColor, iconFont)
                iconCtrl := hud.AddText("x" this.PaddingX " y" this.PaddingY, glyph)
                iconCtrl.GetPos(, , &iw)

                if (text != "") {
                    maxTextW := this.MaxWidth - this.PaddingX * 2 - (iw > 0 ? iw : 16) - this.IconGap
                    textW := this.MeasureTextWidth(text)
                    hud.SetFont("s" this.TextSize " Norm c" textColor, this.TextFontName)
                    if (textW > maxTextW) {
                        hud.AddText("x+" this.IconGap " yp w" maxTextW " +Wrap", text)
                    } else {
                        hud.AddText("x+" this.IconGap " yp", text)
                    }
                }
            }

            hud.Show("x" x " y" y " w" width " h" height " NoActivate")
            if (!dwmOk) {
                try WinSetRegion("0-0 W" width " H" height " R" this.Radius "-" this.Radius, "ahk_id " hud.Hwnd)
            }
            this._gui := hud
            SetTimer this.HideCallback, 0
            SetTimer this.HideCallback, -Max(1, duration)
            return true
        } catch as err {
            throw err
        }
    }

    static Hide(*) {
        if this.HideCallback
            SetTimer this.HideCallback, 0
        if !this._gui
            return
        try this._gui.Destroy()
        this._gui := 0
        this._badgeCtrl := 0
    }

    static GetMonitorFromPoint(ptX, ptY) {
        Loop MonitorGetCount() {
            MonitorGet(A_Index, &left, &top, &right, &bottom)
            if (ptX >= left && ptX < right && ptY >= top && ptY < bottom)
                return A_Index
        }
        return MonitorGetPrimary()
    }

    static GetActiveMonitor() {
        hwnd := WinExist("A")
        if !hwnd
            return MonitorGetPrimary()
        try {
            WinGetPos(&winX, &winY, &winWidth, &winHeight, "ahk_id " hwnd)
            centerX := winX + Floor(winWidth/2)
            centerY := winY + Floor(winHeight/2)
            Loop MonitorGetCount() {
                MonitorGetWorkArea(A_Index, &left, &top, &right, &bottom)
                if (centerX >= left && centerX < right && centerY >= top && centerY < bottom)
                    return A_Index
            }
        }
        return MonitorGetPrimary()
    }
}

NotifyRenderer.HideCallback := ObjBindMethod(NotifyRenderer, "Hide")







