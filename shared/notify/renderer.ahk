#Requires AutoHotkey v2.0
#Include paths.ahk
#Include anchor.ahk

; 统一 HUD Renderer — Win11 IME 选字框同款 Acrylic · 10pt · 深浅色自适应 · 4级输入锚点定位
class NotifyRenderer {
    static FontName := "Segoe UI Variable"
    static LatinFontName := "Segoe UI"
    static IconFontName := "Segoe Fluent Icons"
    static TextFontName := "Microsoft YaHei UI"
    static FallbackFontName := "Microsoft YaHei UI"
    static TextSize := 11
    static IconSize := 10
    static BadgeTextSize := 12.5
    static BadgeIconSize := 13
    static BadgeSize := 22
    static ChipSize := 28
    static ChipRadius := 4
    static ChipAnchorGap := 14
    static MinWidth := 80
    static MaxWidth := 320
    static PaddingX := 16
    static PaddingY := 7
    static IconGap := 8
    static Radius := 8
    static Height := 34
    static PositionYRatio := 0.82

    ; 输入态 28 芯片：同一壳体整盒居中。三态同 size，图标用 600 加笔画，不靠放大充粗
    static StateChip := Map(
        "中", Map("glyph", "中", "font", "Microsoft YaHei UI", "size", 12, "weight", 600),
        "A", Map("glyph", "A", "font", "Segoe UI", "size", 12, "weight", 600),
        "英", Map("glyph", "A", "font", "Segoe UI", "size", 12, "weight", 600),
        "CAPS", Map("glyph", Chr(0xE752), "font", "Segoe Fluent Icons", "size", 12, "weight", 600),
        "大写", Map("glyph", Chr(0xE752), "font", "Segoe Fluent Icons", "size", 12, "weight", 600),
        "⇪", Map("glyph", Chr(0xE752), "font", "Segoe Fluent Icons", "size", 12, "weight", 600),
        "⇧", Map("glyph", Chr(0xE752), "font", "Segoe Fluent Icons", "size", 12, "weight", 600),
        "↔", Map("glyph", Chr(0xE8AB), "font", "Segoe Fluent Icons", "size", 12, "weight", 600)
    )

    ; Win11 Dark Acrylic
    static DarkTheme := {
        Bg: "252525",
        Border: "3A3A3A",
        BorderDwm: 0x003A3A3A,
        ChipBg: "2C2C2C",
        ChipBorder: "333333",
        ChipBorderDwm: 0x00333333,
        Text: "F5F5F5",
        SubText: "A0A0A0",
        IsDark: true,
        TypeBadgeBg: Map(
            "state", "2B2B2B",
            "success", "16321F",
            "info", "152A40",
            "error", "3A1B1B"
        ),
        TypeIconColor: Map(
            "state", "D1D1D1",
            "success", "3FB950",
            "info", "60A5FA",
            "error", "F85149"
        )
    }

    ; Win11 Fluent 浅色
    static LightTheme := {
        Bg: "FFFFFF",
        Border: "D1D5DB",
        BorderDwm: 0x00D1D5DB,
        ChipBg: "F3F3F3",
        ChipBorder: "E5E5E5",
        ChipBorderDwm: 0x00E5E5E5,
        Text: "000000",
        SubText: "374151",
        IsDark: false,
        TypeBadgeBg: Map(
            "state", "F3F4F6",
            "success", "DEF7EC",
            "info", "E1EFFE",
            "error", "FDE8E8"
        ),
        TypeIconColor: Map(
            "state", "111827",
            "success", "0E700E",
            "info", "0066B3",
            "error", "C42B1C"
        )
    }

    static BackgroundColor => this.DarkTheme.Bg
    static TextColor => this.DarkTheme.Text
    static TypeBadgeBg => this.DarkTheme.TypeBadgeBg
    static TypeIconColor => this.DarkTheme.TypeIconColor

    static _cachedTheme := 0
    static _themeListenerRegistered := false

    static GetCurrentTheme() {
        if (!this._themeListenerRegistered) {
            OnMessage(0x001A, ObjBindMethod(this, "OnSettingChange"))
            this._themeListenerRegistered := true
        }
        if (this._cachedTheme == 0)
            this.UpdateThemeCache()
        return this._cachedTheme
    }

    static OnSettingChange(wParam, lParam, msg, hwnd) {
        if (lParam) {
            str := StrGet(lParam)
            if (str == "ImmersiveColorSet")
                this.UpdateThemeCache()
        }
    }

    static UpdateThemeCache() {
        try {
            val := RegRead("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
            this._cachedTheme := (val == 1) ? this.LightTheme : this.DarkTheme
        } catch {
            this._cachedTheme := this.DarkTheme
        }
    }

    static TextOnlySet := Map("中", true, "A", true, "英", true, "CAPS", true, "大写", true, "⇧", true, "⇪", true, "↔", true)
    static IconMap := Map(
        "✓", Chr(0xE930),
        "×", Chr(0xEA39),
        "!", Chr(0xEB90),
        "↑", Chr(0xE74A),
        "↓", Chr(0xE74B),
        "◉", Chr(0xE946),
        "○", Chr(0xE946),
        "↔", Chr(0xE8AB),
        "⇪", Chr(0xE752),
        "⇧", Chr(0xE752),
        "●", Chr(0xE7C8),
        "▣", Chr(0xE722),
        "−", Chr(0xE738),
        "-", Chr(0xE738),
        "🔍", Chr(0xE721),
        "📋", Chr(0xE8C8),
        "🔊", Chr(0xE767),
        "ℹ", Chr(0xE946),
        "⚙", Chr(0xE713),
        "📸", Chr(0xE722),
        "📌", Chr(0xE718)
    )

    static _gui := 0
    static HideCallback := 0
    static _textWidthCache := Map()
    static _iconWidthCache := Map()
    static _inputHook := 0

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
                font := this.LatinFontName
            else if (this.IconMap.Has(icon))
                font := this.IconFontName, display := this.IconMap[icon]
            else
                font := this.IconFontName
        } else if (this.IconMap.Has(icon)) {
            display := this.IconMap[icon]
            font := this.IconFontName
        } else {
            if (icon == "中" || icon == "英" || icon == "大写") {
                font := this.TextFontName
            } else if (icon == "A" || icon == "CAPS") {
                font := this.LatinFontName
            } else if (StrLen(icon) == 1 && Ord(icon) > 127 && Ord(icon) < 0xE000) {
                font := this.TextFontName
            } else {
                font := this.IconFontName
            }
        }
        return Map("glyph", display, "font", font)
    }

    static MeasureTextWidth(text) {
        if (text = "")
            return 0
        if this._textWidthCache.Has(text)
            return this._textWidthCache[text]

        w := 0
        try {
            g := Gui("-Caption +ToolWindow")
            g.MarginX := 0
            g.MarginY := 0
            g.SetFont("s" this.TextSize " q5", this.TextFontName)
            ctrl := g.AddText("x0 y0", text)
            ctrl.GetPos(,, &w)
            g.Destroy()
        } catch {
            try {
                if IsSet(g)
                    g.Destroy()
            } catch {
            }
        }
        if (w <= 0) {
            hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
            if (!hdc) {
                w := StrLen(text) * 7
            } else {
                dpi := DllCall("GetDeviceCaps", "Ptr", hdc, "Int", 90, "Int")
                if (!dpi)
                    dpi := 96
                height := -DllCall("MulDiv", "Int", this.TextSize, "Int", dpi, "Int", 72, "Int")
                hFont := DllCall("CreateFontW", "Int", height, "Int", 0, "Int", 0, "Int", 0, "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 5, "UInt", 0, "UInt", 0, "UInt", 0, "WStr", this.TextFontName, "Ptr")
                if (!hFont) {
                    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
                    w := StrLen(text) * 7
                } else {
                    hOld := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
                    size := Buffer(8, 0)
                    ok := DllCall("GetTextExtentPoint32W", "Ptr", hdc, "WStr", text, "Int", StrLen(text), "Ptr", size)
                    w := ok ? NumGet(size, 0, "Int") : StrLen(text) * 7
                    DllCall("SelectObject", "Ptr", hdc, "Ptr", hOld)
                    DllCall("DeleteObject", "Ptr", hFont)
                    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
                }
            }
        }
        if (this._textWidthCache.Count < 200)
            this._textWidthCache[text] := w
        return w
    }

    static MeasureIconWidth(glyph, font) {
        if (glyph = "")
            return 0
        cacheKey := font ":" glyph
        if this._iconWidthCache.Has(cacheKey)
            return this._iconWidthCache[cacheKey]

        w := 0
        try {
            g := Gui("-Caption +ToolWindow")
            g.MarginX := 0
            g.MarginY := 0
            g.SetFont("s" this.IconSize " Bold q5", font)
            ctrl := g.AddText("x0 y0", glyph)
            ctrl.GetPos(,, &w)
            g.Destroy()
        } catch {
            try {
                if IsSet(g)
                    g.Destroy()
            } catch {
            }
        }
        if (w <= 0) {
            hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
            if (!hdc) {
                w := 16
            } else {
                dpi := DllCall("GetDeviceCaps", "Ptr", hdc, "Int", 90, "Int")
                if (!dpi)
                    dpi := 96
                height := -DllCall("MulDiv", "Int", this.IconSize, "Int", dpi, "Int", 72, "Int")
                hFont := DllCall("CreateFontW", "Int", height, "Int", 0, "Int", 0, "Int", 0, "Int", 700, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "WStr", font, "Ptr")
                if (!hFont) {
                    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
                    w := 16
                } else {
                    hOld := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
                    size := Buffer(8, 0)
                    ok := DllCall("GetTextExtentPoint32W", "Ptr", hdc, "WStr", glyph, "Int", StrLen(glyph), "Ptr", size)
                    w := ok ? NumGet(size, 0, "Int") : 16
                    if (w > 0)
                        w += 2
                    DllCall("SelectObject", "Ptr", hdc, "Ptr", hOld)
                    DllCall("DeleteObject", "Ptr", hFont)
                    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
                }
            }
        }
        if (this._iconWidthCache.Count < 100)
            this._iconWidthCache[cacheKey] := w
        return w
    }

    static ResolveStateChip(token) {
        if (token = "")
            return 0
        if this.StateChip.Has(token)
            return this.StateChip[token]
        return 0
    }

    static EnableSystemDropShadow(hwnd) {
        ; 类样式 CS_DROPSHADOW，必须在 Show 前设置。不透明芯片不能开 Acrylic，靠系统阴影把壳体托起来。
        CS_DROPSHADOW := 0x00020000
        GCL_STYLE := -26
        try {
            style := DllCall("User32\GetClassLongPtrW", "Ptr", hwnd, "Int", GCL_STYLE, "Ptr")
            if (style & CS_DROPSHADOW)
                return
            DllCall("User32\SetClassLongPtrW", "Ptr", hwnd, "Int", GCL_STYLE, "Ptr", style | CS_DROPSHADOW, "Ptr")
        } catch {
        }
    }

    static ApplyDwmStyle(hwnd, theme, opaqueClient := false) {
        ok := false
        try {
            isDark := theme.IsDark ? 1 : 0
            DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 20, "Ptr*", isDark, "UInt", 4)
        }
        ; 芯片必须不透明客户区：Acrylic + ExtendFrame 会让 GDI 小字发灰/发彩
        if !opaqueClient {
            try {
                backdrop := 3
                DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 38, "Ptr*", backdrop, "UInt", 4)
                ok := true
            }
        }
        try {
            ; 芯片走 ROUNDSMALL（约 4px），长条 HUD 仍用 ROUND（约 8px）
            corner := opaqueClient ? 3 : 2
            DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 33, "Ptr*", corner, "UInt", 4)
            ok := true
        }
        try {
            borderColor := opaqueClient ? theme.ChipBorderDwm : theme.BorderDwm
            DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 34, "Ptr*", borderColor, "UInt", 4)
        }
        this.EnableSystemDropShadow(hwnd)
        if (!opaqueClient && theme.IsDark) {
            try {
                margins := Buffer(16, 0)
                NumPut("Int", -1, margins, 0)
                NumPut("Int", -1, margins, 4)
                NumPut("Int", -1, margins, 8)
                NumPut("Int", -1, margins, 12)
                DllCall("dwmapi\DwmExtendFrameIntoClientArea", "Ptr", hwnd, "Ptr", margins)
            }
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

            chipToken := icon != "" ? icon : text
            chipSpec := this.ResolveStateChip(chipToken)
            isTextOnly := !!chipSpec

            anchor := 0
            if (isTextOnly || type == "state") {
                anchor := InputAnchor.Get()
            }

            _preResolved := 0
            _preIconW := 0
            _preGlyph := ""
            _preIconFont := ""
            if (!isTextOnly) {
                if (icon != "") {
                    _preResolved := this.ResolveIcon(icon)
                    _preGlyph := _preResolved["glyph"]
                    _preIconFont := _preResolved["font"]
                    _preIconW := this.MeasureIconWidth(_preGlyph, _preIconFont)
                }
            }

            isMultiline := false
            if (isTextOnly) {
                width := this.ChipSize
                height := this.ChipSize
            } else {
                textW := (text != "") ? this.MeasureTextWidth(text) : 0
                if (text != "" && _preIconW > 0)
                    contentW := _preIconW + this.IconGap + textW
                else if (_preIconW > 0)
                    contentW := _preIconW
                else
                    contentW := textW

                maxSingleLineW := this.MaxWidth - this.PaddingX * 2 - (_preIconW > 0 ? _preIconW + this.IconGap : 0)
                if (text != "" && textW > maxSingleLineW && maxSingleLineW > 50) {
                    isMultiline := true
                    width := this.MaxWidth
                    height := 48
                } else {
                    width := Min(this.MaxWidth, Max(this.MinWidth, this.PaddingX * 2 + contentW))
                    height := this.Height
                }
            }

            anchorFound := false
            targetX := 0, targetY := 0
            if (anchor && anchor.confidence >= 50 && (anchor.x != 0 || anchor.y != 0)) {
                anchorFound := true
                monitor := this.GetMonitorFromPoint(anchor.x, anchor.y)
                MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)

                calcX := anchor.x - Floor(width / 2)
                calcY := anchor.y - anchor.h - height - this.ChipAnchorGap

                ; 若顶部空间不足（靠近屏幕顶边缘），则向下翻转至光标下方
                if (calcY < top + 8)
                    calcY := anchor.y + 12

                if (calcX + width > right - 8)
                    calcX := right - 8 - width
                if (calcX < left + 8)
                    calcX := left + 8
                if (calcY + height > bottom - 8)
                    calcY := bottom - 8 - height

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

            hud := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
            hud.BackColor := isTextOnly ? theme.ChipBg : theme.Bg
            hud.MarginX := isTextOnly ? 0 : this.PaddingX
            hud.MarginY := isTextOnly ? 0 : this.PaddingY
            dwmOk := this.ApplyDwmStyle(hud.Hwnd, theme, isTextOnly)

            if (isTextOnly) {
                ; 整盒水平+垂直居中；不再裁 h，避免字形被切矮后显细
                hud.SetFont(
                    "s" chipSpec["size"] " w" chipSpec["weight"] " q4 c" textColor,
                    chipSpec["font"]
                )
                hud.AddText(
                    "x0 y0 w" this.ChipSize " h" this.ChipSize " Center 0x200",
                    chipSpec["glyph"]
                )
            } else {
                if (_preResolved) {
                    resolved := _preResolved
                    glyph := _preGlyph
                    iconFont := _preIconFont
                    iw := _preIconW
                } else {
                    resolved := this.ResolveIcon(icon)
                    glyph := resolved["glyph"]
                    iconFont := resolved["font"]
                    iw := this.MeasureIconWidth(glyph, iconFont)
                }

                textW2 := (text != "") ? this.MeasureTextWidth(text) : 0
                if (text != "" && iw > 0)
                    _contentW2 := iw + this.IconGap + textW2
                else if (iw > 0)
                    _contentW2 := iw
                else
                    _contentW2 := textW2

                extra := width - this.PaddingX * 2 - _contentW2
                if (extra < 0 || isMultiline)
                    extra := 0
                iconX := this.PaddingX + Floor(extra / 2)

                if (iw > 0) {
                    hud.SetFont("s" this.IconSize " Bold q5 c" iconColor, iconFont)
                    if (isMultiline) {
                        hud.AddText("x" iconX " y8 w" iw " h20 Center 0x200", glyph)
                    } else {
                        hud.AddText("x" iconX " y0 w" iw " h" height " Center 0x200", glyph)
                    }
                    textX := iconX + iw + this.IconGap
                } else {
                    iw := 0
                    textX := iconX
                }

                if (text != "") {
                    maxTextW := width - textX - this.PaddingX
                    if (maxTextW < 10)
                        maxTextW := 10
                    hud.SetFont("s" this.TextSize " q5 c" textColor, this.TextFontName)
                    if (isMultiline) {
                        hud.AddText("x" textX " y6 w" maxTextW " h36 +Wrap 0x4000", text)
                    } else {
                        hud.AddText("x" textX " y0 w" textW2 " h" height " 0x200", text)
                    }
                }
            }

            hud.Show("x" x " y" y " w" width " h" height " NoActivate")
            if (!dwmOk) {
                try WinSetTransparent(theme.IsDark ? 235 : 250, hud.Hwnd)
                fallbackR := isTextOnly ? this.ChipRadius : this.Radius
                try WinSetRegion("0-0 W" width " H" height " R" fallbackR "-" fallbackR, "ahk_id " hud.Hwnd)
            }
            this._gui := hud
            SetTimer this.HideCallback, 0
            SetTimer this.HideCallback, -Max(1, duration)

            ; 输入态芯片只靠 duration 关闭，避免下一键立刻 Hide 造成闪一下
            if (!isTextOnly) {
                if (!this._inputHook) {
                    this._inputHook := InputHook("V")
                    this._inputHook.KeyOpt("{All}", "N")
                    this._inputHook.OnKeyDown := (*) => this.Hide()
                }
                try this._inputHook.Start()
            }
            return true
        } catch as err {
            throw err
        }
    }

    static Hide(*) {
        if this.HideCallback
            SetTimer this.HideCallback, 0
        if (this._inputHook) {
            try this._inputHook.Stop()
        }
        if !this._gui
            return
        try this._gui.Destroy()
        this._gui := 0
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
