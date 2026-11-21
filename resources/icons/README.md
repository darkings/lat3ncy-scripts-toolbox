# 托盘图标

`ahk/features/caffeine-indicator.ahk` 在 Caffeine（Raycast Coffee）开着时显示的咖啡杯图标。

* `coffee_power_white.ico`：深色任务栏用（白图）
* `coffee_power_black.ico`：浅色任务栏用（黑图）

选哪一版由 `CaffeineIndicator.IconPath()` 按 `SystemUsesLightTheme` 决定，主题变化（`ImmersiveColorSet`）时换图。

## 规格

每个 `.ico` 含 **9 档** 32bpp PNG 压缩帧：**16 / 20 / 24 / 32 / 40 / 48 / 64 / 128 / 256**。
`coffee_power.png` 是 256px 预览图。

两版形状完全一致，只差墨色：白版 `#ffffff`、黑版 `#000000`。黑版由白版的 alpha 通道重上色得到，
切主题时不会出现形状跳变。

## 为什么图形要「撑满」

本机是 **200% 缩放（192 dpi）**，`SM_CXSMICON = 32`，也就是托盘实际取 32px 那一档。
用户提供的原始 `coffee_tray_white.ico` 图形只占画布的 **73% 高**（256 画布里 188px），
放到 32px 格子里杯身只有 ~23px，而旁边的应用图标基本铺满格子，看起来就「好小」。

所以这里的处理是：**裁到图形 -> 等比放大到画布 96% -> 居中**，再从这张 256px 母版重出所有档位。
现在 16/24/32 三档图形高度都占满格子（96–100%），和系统图标一致。

## 小尺寸锐化

原来的 16/20/24/32 是 256px 直接缩小，半透明边占比很高（16px 里 116 个非空像素只有 9 个全不透明），
深色任务栏上发灰。现在 ≤64px 的档位会过一条 alpha 曲线（≤36 压成 0、≥220 提到 255），
边缘变实，同时保留抗锯齿。

## 改动后怎么验

`shared/tray/tray.ahk` 走 `LoadImageW(…, IMAGE_ICON, SM_CXSMICON, SM_CYSMICON, LR_LOADFROMFILE)`，
所以验的重点是「Windows 能把每一档读出来、且图形占满」。按 tray.ahk 同样参数调 `LoadImageW`，
再 `DrawIconEx` 画到 32bpp DIB 存 PNG，就能看到托盘实际会画的像素（16px 和 32px 都要看）。
ICO 目录项要 `planes=1`、`bpp=32`，帧按尺寸升序。

注意：AHK 是 DPI-aware 的（`A_ScreenDPI = 192`），所以它拿到的 `SM_CXSMICON` 就是 32，
不会退到被系统虚拟化的 16px。
