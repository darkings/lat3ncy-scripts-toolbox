# ImeHud WinUI 3 Renderer

唯一 IME HUD 实现。芯片视觉已定稿。

AHK CapsLock IME 状态芯片和 Caps+F 翻译链都打本进程主窗口 `Lat3ncyImeHudWinUi`。

```text
Win32 HWND  32×32 DIP
  WS_POPUP / NOACTIVATE / TOOLWINDOW
  跟 caret，点穿
        ↓
DesktopWindowXamlSource.SystemBackdrop
  Composition Controller，配方 Acrylic.Default
  强制 IsInputActive=true
        ↓
CN 中框 / EN A / CAPS 上箭头
ThemeResource
```

HWND + Island 只创建一次，之后 `ShowNoActivate` / `Hide` 复用。默认常驻，不自动退出。

## 独立标识

本进程的窗口和锁：

```text
WindowClass = Lat3ncyImeHudWinUi
WindowTitle = Lat3ncyImeHudWinUi
MutexName   = Local\Lat3ncyImeHudWinUi
```

只查找本 Renderer。

## 芯片（定稿，不要改）

正方形 `32×32 DIP`。图标 `20×20`，居中，四周约 6 DIP。

| 状态 | 图标 | stroke |
|---|---|---|
| `CN` | 方框 + 竖线 | `1.20` |
| `EN` | 字母 A，顶点略圆 | `1.32` |
| `CAPS` | 上箭头 + 竖杆 + 底杠 | `1.32` |

不要底线、不要副标题、不要 accent 条。三态同一套 stroke SVG，不混中英文字体和 Fluent 码点。

定稿 path：

```text
CN    M4.7,6.2 H15.3 V13.8 H4.7 Z
      M10,3.9 V16.1
EN    M5.35,15.25 L9.42,5.05 C9.62,4.55 10.38,4.55 10.58,5.05 L14.65,15.25
      M7.05,11.2 H12.95
CAPS  M5.55,9.25 L10,4.8 L14.45,9.25
      M10,5.05 V13.1
      M6.45,15.0 H13.55
```

定位：传入坐标 → IMM → Win32 caret → 窗口底部。出现在 caret 下方约 7 DIP，下方不够翻到上方。显示期间不跟手。

显示约 750ms（夹紧 650–900），90ms 淡入、110ms 淡出。连续 `STATE` 用 generation 挡住旧的淡出 Completed，避免把新芯片藏掉。

## 材质和圆角

默认材质是 Island Composition `DesktopAcrylicController`（配方 `Acrylic.Default`，不要 Thin），并强制 `IsInputActive=true`。不用默认 `SystemBackdropConfiguration`，避免 NOACTIVATE 走未激活实色。Island 接管时宿主改 `DWMSBT_NONE`。

系统透明效果关闭时不设 Island 材质，退回宿主 `DWMSBT_TRANSIENTWINDOW`，由 DWM 自己降成实色。`SystemBackdrop` 必须等 `Content.Loaded` + 下一个 tick。退出时先拆 Island，再 Destroy HWND。边框走 DWM `COLOR_DEFAULT`。关掉 `CS_DROPSHADOW`。不要 `SetWindowRgn`。

圆角只打在**宿主 HWND** 上：`DWMWCP_ROUNDSMALL`。Island 子窗口实测不接受 `ROUNDSMALL`。给站点打 DWM chrome 只是可选尝试，失败就算了。

高对比度只读系统当前值，本工程不开关、不测试高对比度。

## 协议

IME 状态走本 Renderer 主窗口：

```text
STATE|CN|x|y|dpi|durationMs
STATE|EN
STATE|CAPS
HIDE
PING
QUIT
```

第二个进程拿到 mutex 失败后，按类名 / 标题把命令转给已有 HWND，然后立刻退出。隐藏的 TOOLWINDOW 也会被找到。日志只追加。

## 翻译面板骨架

独立顶层窗口，**不**塞进 32×32 IME 芯片，**不**复用芯片的 `NOACTIVATE` + 点穿。可点击、可钉住、可拖标题栏。钉住后记住当前窗口矩形（进程内，不写盘）；关闭再 `OPEN` 回到记住的位置，取消钉住后下次 `OPEN` 才重新定位。

2026-09-07 起，AHK Caps+F 是翻译面板正式协议生产者：选区仍由 AHK 用 `Ctrl+C` 取，翻译仍走 `tools/translate/translate.py`。同日起，AHK CapsLock 也把 `STATE|CN/EN/CAPS` 发给本 WinUI 主窗口。WinUI **不**读剪贴板、**不**猜鼠标、**不**内置翻译后端。

材质和圆角跟芯片同一套：Island Composition `DesktopAcrylicController`（配方 `Acrylic.Default`，不要 Thin），强制 `IsInputActive=true`。Island 接管时宿主改 `DWMSBT_NONE`。圆角只打在宿主 HWND 上：`DWMWCP_ROUNDSMALL`。站点 chrome 是可选尝试，读回 `corner=0` 不算失败。不要 `SetWindowRgn`。

### 面板视觉（定稿，不要改）

标题栏贴芯片密度，正文边距和正文字号冻结。

| 项 | 定稿 |
|:---|:---|
| 标题栏 | 32 DIP，padding `12,0,4,0`。右边距不要再往圆角内沿收 |
| 按钮 | 24×24 DIP，顺序：复制译文 \| 钉住 \| 关闭 |
| 图标 | 16×16 stroke `1.32`。复制：夹子 + 纸；未钉：空心图钉；已钉：白图钉；关闭：交叉 |
| 标题字 | 「翻译」，12 DIP，`TextFillColorSecondaryBrush` |
| 正文 | 默认字号。原文 padding `12,8,12,8`；译文 padding `12,8,12,12` |
| 分隔线 | `DividerStrokeColorDefaultBrush`，不要写死 Gray |
| 空态 | 「暂无原文」/「暂无译文」/「剪贴板为空」。半透明、不可选中、不可复制 |
| 真内容 | 不透明、可选中。复制钮只出译文，空占位禁用 |

不混文字按钮，不暴露原文复制钮，不改这三套图标 path。

```text
WindowClass = Lat3ncyImeHudWinUiPanel
WindowTitle = Lat3ncyImeHudWinUiPanel
WS_POPUP + TOOLWINDOW + TOPMOST
没有 WS_EX_NOACTIVATE / WS_EX_TRANSPARENT
不返回 HTTRANSPARENT
```

WinUI 自己**不知道**快捷键按下时的鼠标位置。AHK Caps+F 必须把热键瞬间的坐标写进 `OPEN`。没有坐标就绝不能写成 `mouse-at-hotkey`。定位策略可替换，日志写明来源：

| 来源 | 何时使用 |
|---|---|
| `explicit` | 调用方传入坐标 |
| `mouse-at-hotkey` | 调用方明确采集并传入热键时的鼠标；本进程绝不自己 `GetCursorPos` 冒充 |
| `caret` | 无坐标时优先 IMM / Win32 caret |
| `active-window` | 再退到活动窗口底部 |
| `screen-fallback` | 最后用当前屏幕工作区中心 |

原文来源同样可替换，**和定位分开**。`OPEN` 默认空占位「暂无原文」，不会偷偷读剪贴板、不会抓选区 / 鼠标下文本。

译文也是可替换策略，**不接翻译后端**。默认空占位「暂无译文」。只有调用方显式传入 `RESULT` 才填译文。换原文时译文打回占位，不能沿用上一次结果，也不能把原文拷成译文。

`COPY` 只在调用方明确声明 `source` / `result` 时才写剪贴板。空占位、骨架文案都不写。Esc 关闭面板，不经过 AHK。

未钉住时，前台落到面板树以外就关：点左右其他窗口关，点面板按钮 / 正文 / Island 子窗口不关。钉住后切走窗口仍保持。同一窗口里点别处通常不换前台 HWND，那种点击走 `WH_MOUSE_LL`：点在面板矩形 / 子窗口外就关。`OPEN` 走 `ShowNoActivate`，打开瞬间前台仍是编辑器，**不要**当时用「前台不是我」立刻关；只在后续 `EVENT_SYSTEM_FOREGROUND` / `WM_ACTIVATE` / 外面点击里判断。看日志 `translation-foreground-hook`、`translation-mouse-hook`、`translation-dismiss-skip reason=open-fg`、`translation-dismiss reason=outside-click`。

| 原文来源 | 何时使用 |
|---|---|
| `empty` | 默认占位 |
| `explicit` | 调用方传入文本 |
| `clipboard` | 调用方明确声明后才读 Unicode 剪贴板 |

| 译文来源 | 何时使用 |
|---|---|
| `empty` | 默认占位，或换原文后重置 |
| `explicit` | 调用方传入译文。不读剪贴板，不调翻译服务 |

协议（仍走芯片 HWND 的 `WM_COPYDATA`，再转到面板）：

```text
PANEL|OPEN
PANEL|OPEN|x|y|dpi|explicit
PANEL|OPEN|x|y|dpi|mouse-at-hotkey
PANEL|OPEN|||||clipboard
PANEL|OPEN|||||explicit|hello world
PANEL|TEXT|clipboard
PANEL|TEXT|explicit|hello|world
PANEL|TEXT|empty
PANEL|RESULT|explicit|你好世界
PANEL|RESULT|empty
PANEL|COPY|source
PANEL|COPY|result
PANEL|MOVE|x|y|dpi|caret
PANEL|CLOSE
PANEL|PIN|1
PANEL|PIN|0
PANEL|PING
```

命令行：

```powershell
.\ImeHudWinUi.exe --panel
.\ImeHudWinUi.exe --panel 1200 800 96 explicit
.\ImeHudWinUi.exe --panel-clipboard
.\ImeHudWinUi.exe --panel-text hello world
.\ImeHudWinUi.exe --panel-result 你好世界
.\ImeHudWinUi.exe --panel-copy-source
.\ImeHudWinUi.exe --panel-copy-result
.\ImeHudWinUi.exe "PANEL|OPEN|1200|800|96|mouse-at-hotkey"
.\ImeHudWinUi.exe PANEL|CLOSE
```

看日志 `translation-place source=`、`raw=`、`clamped=`、`gap=`、`translation-text source=`、`translation-result source=`、`translation-copy`、`translation-pin`、`translation-esc`、`translation-host-chrome` 和 `translation-island-backdrop-ok=` 的 `recipe=Acrylic.Default`。面板上不画这些调试行。没有坐标时不应出现 `source=mouse-at-hotkey`。钉住后再 `OPEN` 应是 `source=remembered`，协议不能伪装这个来源。`OPEN` 未声明文本时不应出现 `text=clipboard`。`OPEN` / `TEXT` 后译文应是 `result=empty`，不能假装已经译完。`cursor-now=` 只是打开瞬间的当前光标，不是热键锚点。贴边打开时应出现 `clamped=True`，`raw=` 是夹紧前的像素，`gap=` 是锚点到未夹紧位置的像素偏移。`COPY` 空占位应是 `skipped`，不能覆盖已有剪贴板。`translation-island-site-chrome` 只是可选尝试，站点 `accepted=False` 不算失败。宿主圆角应是 `corner=3`（`ROUNDSMALL`）。`translation-place` 的 `raw=` / `clamped=` / `gap=` 只写日志：贴边时应是 `clamped=True`，工作区内是 `False`。钳位只改位置，不改宽高。`--panel-text` 会再发一次无坐标 `OPEN`，核对贴边钳位时不要用它覆盖显式位置；改走 `PANEL|OPEN|x|y|dpi|explicit|explicit|...` 或单独的 `PANEL|TEXT|explicit|...`。

## 运行

```powershell
dotnet publish .\tools\ime-hud-winui\ImeHudWinUi.csproj `
  -c Release `
  -r win-x64 `
  --self-contained false `
  -p:Platform=x64 `
  -o .\tools\ime-hud-winui\out
```

* 无参数 / `--resident`：常驻。HWND + Island 只创建一次，默认隐藏，吃 `WM_COPYDATA`
* `--self-test`：不创建窗口，只校验协议和独立标题 / mutex
* `--cycle 200`：连续 show/hide，核对焦点；通过后退出
* 第二个进程：`STATE|CN` / `HIDE` / `PING` / `QUIT` 转给已有实例
* `--resident QUIT` 或 `--quit`：让已有实例退出
* `--panel` / `PANEL|OPEN...`：打开独立翻译面板骨架。没有坐标时走 caret → 活动窗口 → 屏幕中心，不读当前鼠标冒充热键位置
* `--panel-clipboard` / `PANEL|TEXT|clipboard`：打开面板并**明确**读剪贴板原文；`OPEN` 默认不读
* `--panel-text ...` / `PANEL|TEXT|explicit|...`：打开面板并填入调用方原文；译文同时打回占位
* `--panel-result ...` / `PANEL|RESULT|explicit|...`：只填显式译文，不调翻译服务，不改原文
* `--panel-copy-source` / `PANEL|COPY|source`：复制当前原文到剪贴板。面板按钮不暴露这条路径
* `--panel-copy-result` / `PANEL|COPY|result`：复制当前译文到剪贴板。标题栏复制钮只走这条
* Esc：关闭面板。不经过 AHK
* 未钉住失焦：点其他窗口或同一窗口别处关闭；钉住后保持。打开瞬间编辑器仍前台不算失焦

日志：`%TEMP%\ImeHudWinUi.log`

看 `place source=`、`island-backdrop-controller-ok=` 的 `recipe=Acrylic.Default input-active=True`、`stole-focus=`、`pass=1`、`hide-begin` / `hide-now generation=`。`island-site-chrome` 只是可选尝试日志，站点 `corner=0` 不算失败。发布目录必须有 `resources.pri`。

## 现场验证（2026-09-04）

现场 `EnableTransparency=1`。没有开关、没有测高对比度。

| 项 | 结果 |
|---|---|
| `dotnet publish` | 通过 |
| `out\resources.pri` | 有，约 1.3 MB |
| `--self-test` | exit 0 |
| 常驻启动 | mutex claimed，类名 `Lat3ncyImeHudWinUi` |
| 宿主圆角 | `corner=3`（`ROUNDSMALL`） |
| Island 材质 | `DesktopAcrylicController recipe=Acrylic.Default input-active=True` |
| 站点 chrome | `accepted=False optional=True`，不算失败 |
| 二次进程 `STATE\|CN/EN/CAPS` | 转发到同一 HWND，`stole-focus=False`，generation 递增 |
| `PING` / `HIDE` | 隐藏后仍能找到 HWND，进程数保持 1 |
| 超时隐藏 | `hide-timeout` → `hide-begin` → `hide-now`，generation 对得上 |
| `--resident QUIT` | 先拆 Island，再 Destroy HWND |
| `--cycle 200` | `stolen=0`，`pass=1`，exit 0 |
| 常驻视觉 CN | 32×32 小圆角方芯片，方框 + 竖线，浅色 Acrylic 卡片 |
| 常驻视觉 EN | 同一套底，字母 A |
| 常驻视觉 CAPS | 同一套底，上箭头 + 竖杆 + 底杠 |
| 连发 STATE | generation 11→12→13，没有旧淡出把新芯片藏掉；过程中 `Visible=True`，`stole-focus=False` |
| 超时后 PING | HWND 仍在，窗口已隐藏 |

## 现场验证（2026-09-07 翻译面板）

现场工作区 `0,0-2560,1380`，DPI 120，面板 `450×300`。WinUI PID `42012`。视觉未改。

| 项 | 结果 |
|:---|:---|
| 贴边 `OPEN 2500,1300` | `source=explicit raw=2515,1315 clamped=True gap=15 x=2102 y=1072`。矩形 `2102,1072-2552,1372`，右/下各留 8 px，宽高不变 |
| 区内 `OPEN 200,200` | `clamped=False gap=15 raw=215,215` |
| 钉住后拖到 `1800,800`，CLOSE 再 OPEN | `source=remembered x=1800 y=800 clamped=False allow-relocate=False` |
| 钉住后拖出工作区 `2480,1280`，CLOSE 再 OPEN | `source=remembered raw=2480,1280 clamped=True x=2102 y=1072`，宽高仍 `450×300` |
| 协议 `OPEN\\|...\\|remembered` | 不能伪装。落到 `source=explicit` |
| 取消钉住后再 OPEN | `remembered=False`，走 `active-window` / `explicit`，不再恢复矩形 |
| 无坐标 `OPEN` | `source=active-window`（本机无可靠 caret），**不是** `mouse-at-hotkey` |
| 无坐标 `mouse-at-hotkey` | `translation-anchor mouse-at-hotkey missing; not reading live cursor`，退到 `active-window` |
| 钉住后 `MOVE` | `translation-move skipped pinned=True` |
| 空译文 / 空原文 / 未声明 COPY | `skipped`，剪贴板标记 `KEEP-CLIP-MARKER` 未被覆盖 |
| 有内容后 COPY | `result` 写出 `你好世界`（4 字），`source` 写出 `hello world`（11 字） |
| 焦点 / 圆角 / 材质 | `stole-focus=False`，宿主 `corner=3`，`recipe=Acrylic.Default` |

核对贴边时不要用 `--panel-text` 覆盖显式位置。带空格的 payload 必须整段加引号。

## AHK Caps+F 接线（2026-09-07）

只改 AHK 调用方，不改 WinUI 视觉、定位、Acrylic、DWM 圆角，也不重发 WinUI。

```text
Caps+F
  ↓
MouseGetPos（热键瞬间）
  ↓
Ctrl+C 取选区，立刻恢复剪贴板
  ↓
PANEL|OPEN|x|y|0|mouse-at-hotkey|explicit|原文
  ↓
Python tools/translate/translate.py
  ↓
成功：PANEL|RESULT|explicit|译文
失败：PANEL|CLOSE + 现有 Notify.Error Toast
```

AHK 客户端：

```text
shared/notify/translation-panel.ahk
shared/notify/paths.ahk → ImeHudWinUiExe()
ahk/features/translate-selected-text.ahk
```

约束：

* `MouseGetPos` 必须 `CoordMode "Mouse", "Screen"`。WinUI 按屏幕物理像素解释；客户区坐标会把右窗选区画到左边
* 只找 `Lat3ncyImeHudWinUi` 主 HWND，不找面板 `Lat3ncyImeHudWinUiPanel`
* payload 含 `|` / 换行时走 `WM_COPYDATA`，不要把完整协议塞进命令行
* 冷启动只拉起 `ImeHudWinUi.exe`，等主 HWND 出现后再发第一条 `OPEN`
* `CLOSE` 找不到窗口就当作已经关上，不再冷启动

## 明确不做

* 生产 CapsLock 状态和翻译面板统一打 WinUI 主窗口
* 不把手写 palette 抄进 ResourceDictionary
* 不改这三套 SVG 和 32×32 芯片
* 不把 Island 子窗口 DWM 圆角当成必过项
* 不加 `SetWindowRgn`
* 不用 Acrylic Thin
* 不开关、不测试高对比度
* 不把翻译面板塞进 IME 芯片窗口
* 不把打开瞬间的 `GetCursorPos` 当成快捷键鼠标锚点
* 不把剪贴板当成当前选区或鼠标下文本
* 不在 `PANEL|OPEN` 时偷偷读剪贴板
* 不接翻译后端，不把原文拷成译文
* 不把剪贴板当成译文来源
* 不在 OPEN / TEXT / RESULT 时偷偷写剪贴板
* 不把占位文案覆盖用户剪贴板
* 不把「暂无原文 / 暂无译文 / 剪贴板为空」当成可复制内容
* 不把钉住矩形写成磁盘配置
* 不让协议把 `remembered` 伪装成定位来源
* 不改翻译面板定稿视觉：标题栏密度、padding、图标 path、标题次级色、分隔线、正文边距
* 不把标题栏右边距再往圆角内沿收
* 钳位只改位置，不改宽高
* 不在 `ShowNoActivate` 当时用「前台不是我」立刻关面板
* 不把面板自身或 Island 子窗口当成失焦
* 钉住后面板不因切走前台窗口、也不因同一窗口里点别处关闭
