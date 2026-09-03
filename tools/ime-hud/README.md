# ImeHud

CapsLock 中 / 英 / 大写状态的候选框式 HUD。AHK 只负责热键和 IME 检测，本进程只负责显示。

## 行为

* `CN` → `中`
* `EN` → `A`
* `CAPS` → `A` 加底线（大写）
* 窗口：`WS_POPUP` + `WS_EX_NOACTIVATE` + `WS_EX_TOOLWINDOW`，永不抢焦点
* 材质：DWM Desktop Acrylic（`DWMSBT_TRANSIENTWINDOW`），不用 Mica
* 圆角：`DWMWCP_ROUNDSMALL`
* 阴影：系统 `CS_DROPSHADOW`
* 尺寸：38×30 DIP，跟在 caret 下方约 7 DIP；下方不够则翻到上方
* 显示约 750ms，90ms 淡入、110ms 淡出

## 协议

```text
STATE|CN|x|y|dpi|durationMs
STATE|EN
STATE|CAPS
HIDE
PING
QUIT
```

生产路径是 `WM_COPYDATA` 到标题为 `Lat3ncyImeHud` 的窗口。没有窗口时，AHK 用 `ProcessNoWindow` 拉起 `ImeHud.exe`，并把第一条消息放进命令行。

## 回滚

1. 最快：`ahk/features/caps-lock-ime.ahk` 里把 `CapsLockIme.UseImeHud` 设为 `false`，立刻回到 AHK `NotifyRenderer` 芯片。
2. 完整回退到改前方案：`git checkout ime-hud-ahk-baseline`（Edge 单窗口标签页提交，AHK HUD）。

## 编译

本机没有 WinUI 3 / Windows App SDK 工作负载，因此显示层是 WPF `HwndSource` + DWM Acrylic，对外协议不变。

```powershell
dotnet publish .\tools\ime-hud\ImeHud.csproj -c Release -r win-x64 --self-contained false -o .\tools\ime-hud
dotnet exec .\tools\ime-hud\ImeHud.dll --self-test
# 或：
.\tools\ime-hud\ImeHud.exe --self-test
```

`--self-test` 不创建窗口，只校验协议和视觉常量，退出码 0 为通过。
