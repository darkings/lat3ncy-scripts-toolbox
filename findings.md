# 发现与决策

## 2026-10-01：中英文切换提示不跟光标（锚点退化）

### 现象
CapsLock 切换中/英后，WinUI 芯片出现在**目标窗口底部中心**，不跟输入光标。

### 证据（只读探针，真实桌面会话）
| 调用 | 结果 |
|---|---|
| `GetGUIThreadInfo(0)`（生产 `InputAnchor.TryCaret`） | `focus=<Chrome窗口> caret=0 rc=(0,0,0,0)` → 失败 |
| `anchor-locator.exe --hwnd <Chrome>` | `1536\|1496\|focus-bounds`（Focus/BoundingRectangle 只等于顶层窗口矩形） |
| `InputAnchor.TryWindowBottom(root)` | `1536,1496`（`top + height*0.85`，与上一行完全一致） |
| 历史 `ImeHudWinUi.log` | 只有 `place source=hint`；WinUI 对传入坐标一律标 `hint`，看不出真实来源 |

UIA 侧：`AutomationElement.FocusedElement` 在 Chrome 窗口上返回 `ControlType.Window`/`Chrome_WidgetWin_1` 本身，树里没有 `TextPattern`，`FromPoint` 还返回 `Access to denied`。

### 根因链
1. Chromium/TSF 类窗口不向 `GetGUIThreadInfo` 暴露 Win32 caret → `TryCaret` 必失败。
2. 当前工作区的 `ImeHud.Show` 热路径**主动删掉了 UIA locator**（注释："热路径不跑 UIA locator"），失败后直接落到 `TryWindowBottom`。
3. `AnchorLocator.cs` 的兜底 `TryFocusedBounds` 把"整窗矩形"当锚点用，等价于窗口底部。
4. 降级是静默的：调用方看不到来源，日志也无法区分。

### 决策（已实现）
| 决策 | 理由 |
|---|---|
| 锚点来源成为协议一等公民（`STATE/MOVE` 第 8 段 `anchorSource`） | 没有来源就无法判断"跟光标"还是"窗口底部" |
| 真光标白名单只有 `text-caret` / `imm-caret` / `win32-caret` | `focus-text`/`focus-bounds`/`window-bottom` 都是退化，混用就是这次的 bug |
| `focus-bounds` 不再当锚点用，只作为显式退化来源 | 它就是"提示钉在窗口底部"的来源 |
| L1 只接受 TextPattern2 `GetCaretRange` / TextPattern `GetSelection` 的插入点矩形 | 整窗矩形必须被拒绝 |
| 查询前对目标窗口做 `AccessibleObjectFromWindow(OBJID_CLIENT)` 预热 | Chromium 只在有客户端请求时才建内容树 |
| 只对真光标来源启动 `--watch` 跟随（`MOVE` 只重定位） | 假装跟随退化坐标会掩盖问题 |
| Locator 仍用 Windows 自带 `csc.exe`（C# 5）编译 | 该编译器不支持字符串内插 / `?.` / `init` / 目标类型 `new()`，改了会直接编译失败 |
| AHK 测试文件必须带 UTF-8 BOM（临时脚本） | 无 BOM 的 UTF-8 + 中文注释在本次环境里会让脚本**静默不执行**，排查花了很久 |

### 坑：PowerShell 5.1 读无 BOM 的 UTF-8 会解析失败
同一份 `restart-autohotkey.ps1`：`pwsh`(7) `ParseFile` = 0 错误，`powershell.exe`(5.1) = 9 个错误（报在**无关行号**上）。原因是文件里有中文/`✓`，而 5.1 把无 BOM 文件当 ANSI(GBK) 解码，字节被拆坏后字符串没有终结符，错误位置完全指不到真因。

规则：**非 ASCII 内容的 `.ps1` 必须带 UTF-8 BOM**（`Set-LockScreenFromWallpaper.ps1` 早就有 BOM 也是这个原因）；纯 ASCII 的脚本反过来不要加 BOM。改完必须用 5.1 复验：

```powershell
powershell -NoProfile -Command "\$e=\$null; [void][Management.Automation.Language.Parser]::ParseFile('path\to\x.ps1',[ref]\$null,[ref]\$e); \$e.Count"
```

同样地，临时 `.ahk` 测试脚本若无 BOM 且含中文注释，会**静默不执行**（既不报错也不写日志），排查时浪费了很久。

### 未验证（需要真实桌面手动确认）
本机 UIA 查询拿不到 Chrome 内容树，因此 Chromium 下预期仍会落到 `anchor-degraded`。判断方法：按一次 CapsLock，看 `%TEMP%\ImeHudWinUi.log`：

* `real=1` 且 `anchor=text-caret` → 修好了，芯片跟光标。
* `real=0` + `anchor-degraded anchor=focus-bounds` → UIA 在该应用里确实拿不到插入点，此时落点是窗口底部（已如实标记，不再伪装跟随）。

## 需求
- 一键 `Caps+D` 在 `G27Q2 显示器音箱(NVIDIA HD Audio)` 与 `Jie’s AirPods 立体声` 间互切，未连时自动拉起 AirPods，已连时秒切，回切不掉线，失败分级提示（耳机未就绪/无设备/切换失败）
- 可选：`Caps+S` 朗读选中文本(`tools/tts/tts_player.py`)前可预热 AirPods，保证首句走耳机
- 通知与编码统一：系统 Toast `short~7s`，Raycast 不乱码

## 研究发现
- **入口**：`ahk/main.ahk:99 #Include audio-switcher.ahk` 注册 `Caps+D`；`ahk/features/audio-switcher.ahk:16 Toggle()` 用 `ProcessNoWindow.RunWait(audio-switcher.exe --toggle, %TEMP%\lat3ncy-audio-switcher.txt)` + 700ms 防抖 + Busy 互斥，无黑窗读协议行 `A|B`
- **核心**：`tools/audio-switcher/AudioSwitcher.cs:808 TogglePreferredOutputs()` -> `GetDevices(ACTIVE)` + `FindPreferredHeadset/Speaker` -> 分支：`current==headset ? 切扬声器 : headset!=null ? 切耳机 : ConnectPreferredHeadset()->WaitForActiveHeadset(8s)->SwitchToDevice`
- **建链**：`ConnectPreferredHeadset():770 EnableAirPodsA2dp()+ConnectAirPodsAudioProfile()` + `AddRememberedHeadsetIds()` 兜底。`Enable...` 枚举 `Bluetooth Radio` -> `BluetoothFindFirstDevice(Remembered+Authenticated)` -> `IsPreferredHeadset` 过滤 `AirPods && !Hands-Free/iPhone` -> `BluetoothGetDeviceInfo` 刷新 -> `BluetoothSetServiceState(A2dpSinkUuid=0000110B, Enable=1)`，`0/87` 均算成功。`Connect...` 取 `Address` -> `WSAStartup` -> `WSALookupServiceBegin/Next` 拿 `CSADDR` 再 `WSASetService(RNR)`，失败回退 `RegisterBtService(L2CAP/RFCOMM)`，复刻系统“连接”按钮
- **找回**：`AddRememberedHeadsetIds():521` 读 `HKLM\SOFTWARE\...\MMDevices\Audio\Render\{guid}\Properties` 的 `{b3f8fa53},6(DeviceDesc)/2(Interface)` 与 `{a45c254e},14(FriendlyName)`，排除 `BTHHF/Hands-Free`，拼 `{0.0.0.00000000}.{guid}` 补到候选，使未 `ACTIVE` 仍可被识别
- **设默认**：`SwitchToDevice():789` 仅 `ACTIVE` 才 `SetDefault()` 调 `CoCreateInstance({294935CE...})->vtable[12]` 设三角色 `eConsole/eMultimedia/eCommunications`，非 ACTIVE 直接 `耳机未就绪`，`0xE000020B` 统一映射
- **TTS**：`ahk/features/speak-selected-text.ahk Speak()` 复制选区 -> 写 `%TEMP%\lat3ncy-tts-in-<tick>-<random>.txt` -> `ProcessNoWindow.Run pythonw tts_player.py --input-file`（非等待返回 PID）；进程结束后由 `WatchPid` 删除临时文件。`pythonw` 由 `shared/python.ahk` 的 `ToolboxPython.ResolveW()` 解析，生产入口 `ahk/main.ahk` 统一 `#Include`，朗读/翻译 feature 不再各自包含。`tts_player.py play_audio_file` 走 `winmm.mciSendStringW(open/play wait/close)`，依赖系统默认设备，不自带切声卡。默认音色是 `Microsoft Yaoyao` / `Microsoft Zira`，不是 Xiaoxiao/Jenny Neural
- **通知**：`shared/notify/toast.ps1:15 duration=short` 约 7s，`_lib/notify.ps1:2 OutputEncoding=UTF8`，`audio-switcher.ahk:47 Notify.Success/Info/Error` 按名 `耳机|airpod` 选 `🎧/🔊` 图标
- **乱码根因**：6 个 `tools/raycast-scripts/*.ps1` 无 BOM，`Windows PowerShell` 按 ANSI 解码 `✓/已重载`，已补 `EF BB BF` 并改 `restart-autohotkey  √->✓`

## 技术决策
| 决策 | 理由 |
|------|------|
| A2DP 只开 `0000110B/0000110D`，永不 Disable | 保立体声质量，防踢掉蓝牙 |
| 仅 ACTIVE 设默认，建链靠 WSASetService | WASAPI 设非 ACTIVE 必 0xE000020B |
| DeviceDesc + 注册表找回 | FriendlyName 未建链为空，注册表仍有 |
| 双路径建链：WSALookup 查 CSADDR 优先，L2CAP/RFCOMM 兜底 | 覆盖不同系统缓存状态 |
| 8s 轮询 200ms×40（历史） | 当时实测开盖到 ACTIVE 约 2-5s；当前生产 `connect_wait_ms=12000`，`poll_ms=200` |
| TTS 预热 opt-in | 默认不改朗读链路，避免误切扬声器用户 |

## 遇到的问题
| 问题 | 解决方案 |
|------|---------|
| Raycast 乱码 `鈭?` | 补 BOM，统一 ✓ |
| `screenshot-ocr` 走 Raycast 气泡 | trap exit 0 + Show-SystemToast 统一 |
| 没有「Raycast 窗口底部提示后再关窗」的 mode | `compact` 留窗；`silent` 关窗。Windows 上 `silent` 的 stdout HUD 不稳，成功/失败都走 `Show-SystemToast` |
| WASAPI 找不到未建链 AirPods | DeviceDesc+注册表+MaskAll |
| 旧 Watcher 进程仍写 `Reconcile (periodic 60s)` | 源码已改静默对账；需 `/End` + `/Run` 重载，不能只改文件 |
| `schtasks /FO LIST /V` 经隐藏进程读中文系统乱码 | 状态查询改走 `Get-ScheduledTask`，schtasks 只作回退 |
| 朗读/翻译各自 `#Include shared/python.ahk` | 生产入口会同时加载两个 feature；改为 `ahk/main.ahk` 统一包含，独立加载 stub 始终注入 `python.ahk` |
| 完整 runner 卡住、AHK 弹出 Abort/Help/Edit 对话框 | 临时 feature stub 漏了 `python.ahk`，`ToolboxPython` 未定义；现已始终注入 |
| `run-tests.ps1` 在 `powershell.exe` 5.1 解析失败 | LF 源文件 + here-string 内行首 `#Requires/#Include` 被 5.1 误处理；已改成 CRLF 重写 runner |
| `Start-DshRemote` 提前扫进程 | `Get-DshPortInfo` 仅在 `.store.dat` 未命中后才 `Get-DshProcessSnapshot` |
| `--list` 空 / `--get` 为 `NO_DEFAULT` | 当前会话 WASAPI `all=0`，不能据此声称音频枚举已实测通过 |
| `ambient.py` 本会话 `BitBlt` 失败 | 当前会话无可用桌面抓屏；OpenRGB 服务与 `hi75.exe` 仍在 |

## 研究：RGB Ambient 桌面取色

### 需求
- 技嘉 B550M DS3H 机箱风扇 + Hi75 键盘 随桌面主色实时同步，最省资源

### 发现
- **抓屏**：`mss` 全屏 39ms → 中心320x180 4.6ms (210fps), `dxcam` 需 `comtypes` 且 `create` 易 hang，默认 `mss`
- **Hi75**：`VID_258A:010C` 8 HID，3×FF00 (`Col03/05/06`)，仅 `Col06` 的 `HidD_SetFeature 520B` 成功 (`Col05/03` 0x01)
- **协议**：`OpenRGB #4297` 5×pcapng → 3×Feature Report `0684/0604/060a` 各520B (ReportID 0x06)，`060a` 的 5×3B (29/93/114/135/156) 为全局色，`0604` offset18 0x01=on/0x00=off
- **OpenRGB**：`B550M DS3H` 走 SMBus (PawnIO)，需 `SDK 6742` + `Direct` 模式；`hi75` 走 HID 无需 OpenRGB
- **推灯（早期压测，历史）**：首帧3段，后续仅 `060a` + 阈值8 + EMA0.2 + 亮度16 + 5Hz idle /12Hz active
- **当前生产配置（`tools/rgb/config.toml`）**：阈值 6 + EMA 0.18 + lerp 0.35 + 亮度门限 22 + 6Hz idle / 12Hz active；OpenRGB 走官方系统服务 `127.0.0.1:6742`，项目内不再携带 `OpenRGB-App` / `PawnIO_setup.exe` / `lib/psutil`

### 决策

| 决策 | 理由 |
|------|------|
| 中心320x180采样而非全屏 | 14MB→0.2MB，39ms→4.6ms，误差<5% |
| `mss` 默认，`dxcam` 备选 | `dxcam` hang 无超时，`mss` 10.2.0 稳 |
| `Col06` 单口 Feature | 实测唯 `Col06` 520 成功 |
| 5 triple patch | 差分15B覆盖5色点，任意色 `ff00ff` 可 patch |
| 长连复用 + 阈值 | 56帧→14推 省75%，30Hz 与12Hz 推次相同 |
| `psutil` abi3 + 手动 wheel（历史） | 早期长稳采样用；当前生产已移除 `lib/psutil`，不再作为运行依赖 |

### 问题
| 问题 | 解决 |
|------|------|
| `dxcam create` hang | 自动 `mss`，跳过 dxcam |
| `hid Col05` -1 | 排序 `Col06>Col05>Col03` |
| `FEAT0 511≠520` | 重导 pcap bin |
| `pip Temp` 13 | 手动解 `mss/comtypes/psutil/openrgb` 到 `tools/rgb/lib` |

## 资源
- `tools/audio-switcher/AudioSwitcher.cs`、`ahk/features/audio-switcher.ahk`、`ahk/features/speak-selected-text.ahk`、`tools/tts/tts_player.py`、`shared/notify/toast.ps1`、`tools/raycast-scripts/_lib/notify.ps1`
- `tools/rgb/ambient.py`、`hi75.py`、`hi75_data/*.bin`、`lib/{mss,openrgb,dxcam,comtypes}`、`lib_hid/hid.pyd`、`config.toml`；OpenRGB 由系统服务提供，不入库
- 测试契约 `ahk/tests/run-tests.ahk:483` 11 项、`ahk/tests/run-tests.ps1`（含 RGB/Theme AST）+ `ambient --bench / --dry-run`

## 研究：腾讯移动应用引擎 (Androws) 标题栏自适应深浅模式

### 现象与根因
- 腾讯移动应用引擎（`Androws.exe` / `AndrowsStore.exe`）窗口标题栏在 Windows 开启深色模式后始终保持纯白/浅灰（`#F0F2F7`）。
- **根因链**：
  1. 标题栏并非 Windows 原生非客户区，而是 Qt 5 在客户区最上层自绘的控件（`QWidget#titlebar`），内置 QSS 将背景硬编码为白色，且无深色模式资源。
  2. 程序清单强制 `requireAdministrator`，存在 Windows UIPI 权限隔离，外部常规程序调用 `DwmSetWindowAttribute` 被系统拒绝（`0x80070006`）。
  3. DWM 美化工具（Mica For Everyone 等）仅作用于底层非客户区，被上层 Qt 白色控件完全遮挡。
  4. 外部透明浮层（Overlay）在 3D 渲染交换链上方会导致高频 Z-fighting 频闪，无法用于生产。
- **决策**：
  - 工具箱不保留侵入式浮层；`tools/raycast-scripts/force-dark-titlebar.ps1` 保留参数净化与 `-Silent` 健壮性修复。
  - 需要单窗口、原生深浅跟随与比例保持的用户推荐使用独立模拟器方案（如 MuMu 12 单应用独立窗口模式）或 Scrcpy 极客封装。


## 2026-10-21：摇动找鼠标留下的脏光标 + 能被永久挂死的 AHK 线程

### 现象与证据
- `%LOCALAPPDATA%\lat3ncy-toolbox\startup.log`：10:58–11:23 之间 watchdog 连续 6 次重启 `main.ahk`，且**没有任何一条 `main.ahk 退出` 记录** → 全是硬杀（`tools/startup/Start-Toolbox.ps1:204` 的 `Stop-Process -Force`），`OnExit` 不会执行。
- 放大走 `ahk\features\find-mouse\cursor-size.cs` 的 `SetSystemCursor`，**全局**替换 6 个系统光标；还原只有一条路：`FindMouse.OnExit → Stop → SendSizer("rest")`，外加 1400ms 的还原计时器。硬杀 = 没人还原，光标停在放大态，直到下次正常启动/换方案。
- `SendSizer` 的 `connect/send/recv` 全是阻塞调用且无超时（`find-mouse.ahk`）。助手一旦挂住，AHK 主线程永久堵在 `recv` 上——热键全失效，外部只看到"AHK 没启动"。
- 助手自身是单线程、单连接、没有 Accept/Read 超时：一个**半开连接**（连上不发数据）就能把它堵死，后续所有请求排队。
- 坑：从受限令牌的子进程里 `Process.GetProcessById(活的父进程)` 会抛 `ArgumentException: 进程当前未运行`（本机实测，即使父进程确实活着）。**"查 PID 判父进程存活"在这台机器上会静默失效**，不能作为唯一机制。

### 修复
| 文件 | 改动 |
|---|---|
| `cursor-size.cs` | **父进程守护换成命名互斥体**：AHK 以拥有者身份持有，助手 `OpenMutex` + `WaitForSingleObject`；互斥体被放弃（AHK 被强杀/崩溃）即还原并退出，实测 122ms。`rest` 逐条还原失败时回退 `SPI_SETCURSORS` 整表重载；`stop` 也先还原。助手捕获单客户端 IO 异常 + 收发超时（250ms/2s），半开连接不再带走整个助手；端口被占时安静退出（码 3）。 |
| `find-mouse.ahk` | `SO_RCVTIMEO/SO_SNDTIMEO = 600ms`，`recv` 超时返回 `timeout`；把自身 PID + 互斥体名交给助手；启动时回收上一轮留下的孤儿助手（rest → stop → 等端口释放）；`csc` 编译加 15s 超时。 |
| `run-tests.ahk` | 新增契约断言：互斥体、socket 超时、孤儿回收、`SPI_SETCURSORS` 回退、`ReceiveTimeout`。 |

### 验证
- `ahk\tests\run-tests.ps1` 全绿（含 `PASS: core assertions`）。
- 端到端（`default-workspace\fix\verify3.ps1`）：独立进程建互斥体 → 助手启动并应答 `rest` → **`Stop-Process -Force` 持有者后助手 115–122ms 退出并释放端口**；名字指向不存在的持有者时助手立刻退出。
- 半开连接下第二次 `rest` 仍在 ~160ms 内应答。
- 未验证（需手动）：真实摇动放大后 1.4s 的视觉还原——摇一次，确认光标恢复原尺寸。

### 结论
"鼠标点击后移不动"本身是 Windows 侧的问题（窗口模态拖拽循环 `SetCapture+ClipCursor`、左键 down 未配平、输入设备掉线），**不是**这个放大功能的直接后果；但上面两条是真实缺陷，会分别留下"光标变大不还原"和"热键全失效（看起来像 AHK 没启动）"。

## 2026-10-21（续）：摇动找鼠标「甩很久才放大 / 有时怎么甩都不放大」

### 根因
`FindMouse.Observe` 是**逐样本**判轴：每个 16ms 采样都要求 `|dx| ≥ 2|dy|` 或反之。真实甩动带一点弧度（单样本 5px/3px，比值 1.67）就整段被丢掉——位移丢了但 `LastX/LastY` 已经前进，于是这条腿永远凑不够 `MinDistance`；斜着甩/画圈则**任何样本都不满足 2:1**，一次都不会触发。再叠加 `ReverseCount=3`（要甩满 4 条腿），手感就是"要甩很久"。

### 修复
| 项 | 旧 | 新 | 理由 |
|---|---|---|---|
| 判轴 | 逐样本 2:1 | **按整条腿的净位移**定轴（`AxisMinPx=8` 后锁定） | 带弧度/略斜的甩动不再丢位移 |
| 反向判据 | 同轴反向 + 每腿 ≥40px | 相对**本腿最远点**往回走 ≥ `MinDistance` | 语义更准，也更容易满足 |
| `ReverseCount` | 3（4 条腿） | **2**（3 条腿） | 一次半来回就够 |
| `MinDistance` | 40 | 24 | 正常甩动 30–80px 就够 |
| `LegMaxMs` | 450 | 320 | "慢腿=日常瞄准修正"这条要收紧才不误触 |
| `IdleResetMs` | 450 | 400 | 同上 |
| 诊断 | 无 | 状态文件新增 7 个计数器 | 见下 |

### 现场计数器（`%TEMP%\lat3ncy-find-mouse-status.txt`，每秒刷新）
- `ButtonBlocks` 涨 → 有按键状态卡住（和"点击后移不动"同源），整个检测被 `ResetMotion` 每帧清掉；
- `SlowLegs` 涨 → 甩得太慢（每腿 >320ms）；
- `ShortLegs` 涨 → 幅度不够（<24px）；
- `Reversals` 涨但 `Triggers` 不涨 → 节奏/间隔问题；
- `LastSizerResult` 不是 `ok` → 助手链路问题（`unavailable`/`timeout`/`connect`）。

### 验证
`ahk\tests\run-tests.ps1` 全绿；新增用例覆盖：带垂直漂移的甩动必须触发、慢腿不触发、10px 抖动不触发、停顿清零、跨屏清零、竖直甩动同样触发。已重载工具箱（PID 7804），状态文件确认新字段生效。

## 2026-10-21（三）：调过头了——"随意一晃就放大"

### 根因
上一版把 `ReverseCount` 压到 2、`MinDistance` 压到 24，只要出现两次快速反向就放大。而日常用鼠标几乎必然产生"过头再修正"这种单次反向；连着两次（比如移到按钮旁再挪一下）就满足了。**缺的不是阈值，是"原地摇"与"顺手抖一下"的区分。**

### 修复：净位移 / 累计腿长
新增 `MaxNetRatio = 0.6`：连击结束时算 `net = |当前点 - 连击起点|`、`travel = Σ各腿行程`。
- 真摇动绕着自己起点来回：三次等幅反向 → net ≈ L、travel ≈ 3L → **比值 ≈ 0.33**；
- 移到 400px 外再抖两下：net ≈ 370、travel ≈ 460 → **比值 ≈ 0.80** → 拒绝并清空连击。

配套：`ReverseCount` 3（四腿≈两个来回，轴判定修好后真摇一次能攒够）、`MinDistance` 30、`MaxIntervalMs` 400、`IdleResetMs` 380。

### 诊断
状态文件新增 `NetRejects`（被净位移判据否掉次数）、`StreakTravel`（当前连击累计行程）。

### 验证
`run-tests.ps1` 全绿；新增用例「移到 400px 外再抖两下不得放大」与「两个来回的真摇动必须放大」同时通过。

## 2026-10-24：合盖睡眠策略——从"自己调睡眠 API"退回"只改电源设置"

设备：ThinkPad T14p Gen 3，只有 S0 Modern Standby 与 S4，**没有 S3**（固件 + Device Guard）。术语沿用本机约定：**睡眠 = S4**（恢复见 BIOS logo），**休眠 = S0**（开盖即亮）。

需求最终形态：合盖就进 S0；插电永不转 S4，电池 60 分钟转 S4；**Caffeine 开着则完全不睡**；其它任何程序都不能阻止睡眠。

### 决定性依据：Caffeine 挡不住合盖

Microsoft 对 `SetThreadExecutionState` 的说明：

> It cannot prevent sleep caused by the user pressing the power button or closing the lid. This function only affects automatic sleep triggered by an idle timeout.

Raycast Coffee、PowerToys Awake、Insomnia 用的都是这个 API，**所以"设了 Caffeine 就不睡"必须由外部改写电源设置来实现**，不存在原生方案。能改的只有 `LIDACTION`（子组 `SUB_BUTTONS`，GUID `5ca83367-6e45-459f-a27b-476b1d01c936`）。

另外 `PowerSetRequest` 文档提到：电池供电的 Modern Standby 上，`SystemRequired` 请求会在睡眠超时到达后 5 分钟被系统切断。

### 实测：谁关的屏，决定能不能睡着

解析 `powercfg /sleepstudy` 的 `ScenarioInstances`（一个月的会话），按 `EnterReason` 统计 Type=1 会话的睡眠转化率：

| EnterReason | 转化率 |
|---|---|
| `Video Idle Timeout` | 2/61 = **3%** |
| `SC_MONITORPOWER` | 28/85 = 32% |
| `PDC Task Client: Maintenance Scheduler` | 12/15 = 80% |
| `Lid`（Windows 原生合盖） | 5/6 = **83%** |
| `Power Button` / `Restricted Standby Budget Exceeded` | 100% |

结论：**别自己关屏，让 Windows 走原生合盖路径**。脚本只维护 `LIDACTION`：Caffeine 开 → 0（不操作）；关 → 1（睡眠）。

未入睡的会话在 sleepstudy 里的特征是 `TopBlockers = "No CS Phase" 99%`（PDC 从未进入 CS 相位），表现为"屏幕关着但 CPU 全速跑"。实测 34 分钟掉 6%（≈7.8 W）。

### 三个把机器搞坏的坑

**1. `SetSuspendState(force=TRUE)` 会被固件回落成 S4**

本机无 S3，强制挂起等于休眠。证据链：`Kernel-Power 42 Reason=4 TargetState=5`（5 = S4）、`Kernel-Boot 27 引导类型=0x2`（走了完整固件 POST）、`hiberfil.sys` 被写入。表现就是合盖即休眠，开盖必见 BIOS logo。

→ 现在**不调用任何睡眠 API**。

**2. 类型编译带副作用：注释写"可接受"，实际致命**

旧代码用 `if (-not ('LidPolicy.Display' -as [type])) { Set-DisplayOff }` 来顺带编译 C# 类型，注释是"副作用为一次关屏，可接受"。但 `Set-DisplayOff` 会真的发 `SC_MONITORPOWER`。而合盖事件任务每次都是**全新进程**，类型永远未编译 → **每次合盖都发一次关屏**，把 Caffeine 开着的情况也睡掉（当天 17:59 合盖后睡 56.7 分钟，60 分钟到点转 S4，开盖见到 logo）。

→ 拆出 `Initialize-DisplayType`，编译与动作彻底分离。

**3. 频繁 `Restart-Service -Force` 把 Lenovo 服务搞死**

`LenovoSmartStandby` 每次从睡眠恢复都会把 `HIBERNATEIDLE` 改回去，旧防漂移逻辑每次都重启服务纠正。10-24 一天重启 7 次后服务变成 `Stopped` 起不来，于是 `Lenovo-Power-SmartStandby/Operational` 不再记录 `Lid has been closed/opened`。

脚本靠该日志判断盖子状态，**数据源一断就永久误判**：当天日志出现 14459 条"盖子=打开"对 33 条"盖子=关闭"，中午之后完全失真。而 `LIDACTION` 只由 Caffeine 决定、与盖子状态无关，所以**实际睡眠行为仍然正确，坏的只是可观测性**——这种"静默降级"最难发现。

→ 两条修复：① 只在注册表参数真变时才重启服务，纯数值漂移用 `powercfg` 覆盖；② 防漂移检查增加服务健康检查，停了就 `Start-Service`。

### 另一个必须治的：日志无限膨胀

每 5 秒无条件写一行 → 一天约 17k 行 ≈ 1 MB，迁移前旧日志已涨到 **18.6 MB**。

→ 状态行只在「盖子/供电/Caffeine/LIDACTION」变化时写，另加 30 分钟心跳；每 200 次写入检查一次，超 3000 行保留最后 2000 行。实测 45 秒 9 次轮询只产生 5 行。

### 迁移与看护统一

工具从临时工作区（`deepseek-harness\default-workspace`，随时可能被清理）迁入 `tools/power-policy/`，任务参数随之指向仓库路径。

看护按要求收敛为**一个任务看护两个对象**：`Lat3ncyToolbox-Watchdog` 同时检查 `ahk/main.ahk` 与 `PowerPolicy.ps1 -Run` 常驻进程，逻辑都在 `tools/startup/Ensure-ToolboxRunning.ps1`。

迁移中验证到的两个事实：
- **非提权进程可以启动 `RunLevel=Highest` 的计划任务**（本机实测），所以看护任务保持 `Limited`、电源任务保持 `Highest` 即可，不必抬高看护任务（抬高会连 AHK 一起提权，破坏 UI 自动化）。
- `wscript.exe` 静默外壳的命令行里也含 `PowerPolicy.ps1 -Run` 字样，用 CIM 统计实例数时要把 `wscript` 与 `pwsh` 分开算；非提权时又读不到提权进程的 `CommandLine`，会误显示 0 个。**判断"常驻是否在跑"应以日志是否在增长为准**。

### 未验证

- 迁移后的端到端行为（拔电合盖 → 睡 → 开盖瞬亮；插电合盖 70 分钟 → 不转 S4）需要实机跑一次确认。
- `LenovoSmartStandby` 服务停摆的**诱因**未定位（`Service Control Manager` 日志里没有对应记录），目前是"减少扰动 + 出错自愈"，不是根治。

## 2026-10-25：插电合盖 60 分钟后仍然休眠——Lenovo 一直在改写 HIBERNATEIDLE(AC)

10-25 出现两次真 S4（都做了固件 POST，`Kernel-Boot 27 引导类型=0x2`、`hiberfil.sys` 被写），其中 18:05 那次是确定的缺陷。

### 现象与证据

```
17:05:26  Lid has been closed
17:05:27  Hibernate Timeout (AC) has been updated to 60 minutes.     ← Lenovo，合盖同一秒
18:05:28  Kernel-Power 507 时长=60分 睡眠=60分
18:05:31  Kernel-Power 42 Reason=6 (Hibernate from Sleep - Fixed Timeout) TargetState=5
19:22:27  Kernel-Boot 27 引导类型=0x2 → 真 S4 恢复，开盖见 BIOS logo
```

`powercfg` 里 AC 明明是 0（永不）。防漂移当天纠正了约 10 次，每次回读都是 `AC=0s`——**但纠正发生在唤醒之后，对"睡眠期间就已经触发"的休眠无效**。

按天统计 Lenovo 的写入（`Lenovo-Power-SmartStandby/Operational`）：

| 日期 | AC 写入 | DC 写入 |
|---|---|---|
| 10-13 ~ 10-21（IsAutonomic=1） | 每天 4~12 笔 | 每天 17~42 笔 |
| **10-22 起（IsAutonomic=0）** | 每天 7~49 笔 | **0 笔** |

结论：`IsAutonomic=0` 确实让它不再碰 DC，但**它仍然独占 AC**——每次合盖/唤醒都按 `HibernateIdleOvertime` 写一次。

### 根因：字段映射猜错了一次

第一版把 AC 目标写进 `HibernateIdleDaytime`（=0），重启服务后它照样打印 `Hibernate Timeout (AC) has been updated to 60 minutes`（当时 Overtime=60）→ **AC 取的是 Overtime，不是 Daytime**。

第二次把 `HibernateIdleOvertime = 0`、`Daytime = 60`，服务重启后日志变成：

```
Smart Standby is enabled. Idle daytime: 60, Idle overtime: 0, Promote hibernate length: 90.
The calculated value out of range.
```

**它算出越界值后直接跳过写入**，AC 保留 `powercfg` 设的 0 → 插电合盖不再转 S4。这也是想要的最终效果：不写 = 不覆盖。

### 修复

| 位置 | 改动 |
|---|---|
| `Set-LenovoSmartStandbyPolicy` | `HibernateIdleOvertime = LenovoAcHibernateMinutes`（默认 0）、`HibernateIdleDaytime = DC 分钟数`；注释写明实测依据 |
| `Test-LenovoPolicyDrift` | 同步交换比较对象，避免误判偏离导致无谓重启服务 |
| `config.toml` | 新增 `lenovo_ac_hibernate_minutes = 0` |

顺带修掉一处 `-f` 运算符优先级 bug：`"A" + "B{0}{1}" -f x,y` 只会格式化第二段，日志里留下未替换的 `{0}`；正确写法是把拼接整体括起来再 `-f`。

### 未验证

- 需要一次真实的"插电 → 合盖 → 70 分钟 → 开盖"来确认不再 S4（服务启动路径已确认跳过写入，但合盖路径尚未实测）。
- 20:49:57 那次 S4 的 `Kernel-Power 42 Reason=0 (Button or Lid)`，当时 `LidOpenState=true`（盖子开着），更像是手动休眠或电源键触发；Lenovo 同时设置了 `10/26 07:28` 的 BIOS 唤醒定时器，待确认是否为用户操作。
