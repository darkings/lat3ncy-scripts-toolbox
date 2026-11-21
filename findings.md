# 发现与决策

## 2026-11-22：设置窗口关闭与常驻生命周期

- 原生 HWND HUD 增加普通 XAML 设置窗口后，实际关闭设置导致 PID 17200 结束，AHK 后续恢复新 HUD；这不是设置读取失败。控件树和 settings-loaded 已确认加载成功。
- 本地 Windows App SDK 1.8 的 Microsoft.WinUI.xml 提供 Application.DispatcherShutdownMode。微软 [1.8 属性说明](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.application.dispatchershutdownmode?view=windows-app-sdk-1.8) 说明 Application.Start 将当前线程设为 OnLastWindowClose；混合原生 HWND 常驻应改 OnExplicitShutdown，正式结束时主动 Application.Exit。
- HudApp 构造时显式设置该模式。新增 --settings-lifecycle-test，不占用 HUD 全局标识、不保存设置、不注入输入，连续两轮设置加载/关闭后继续 Dispatcher 调度；独立源码构建产物实际返回 0。
- Computer Use 可枚举新设置窗口并读取全部控件/已加载状态，点击“重新加载”仍 GetCursorPos 0x80070005；没有成功输入，不能据此标为点击/视觉/声音通过。普通 ShellExecute 启动在后台环境挂起，清理精确自有 launcher PID，Raycast 改无 shell 的 ProcessStartInfo/CreateNoWindow，正常原生 CLI 转发已验证。

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

## 2026-10-27：锁屏跟随壁纸失效——WinRT 存储代理只认「应用可访问位置」

### 现象

Raycast 换壁纸弹 Toast：`Desktop changed, but lock screen failed: wallhaven-og7yyl.jpg`；`theme-scheduler.log` 里从 10-22 起每次计划任务切换都是 `LockScreen sync failed: exit code 1`，但旧实现只回传退出码，子进程的报错随控制台一起丢了。

### 根因

直接跑 `Set-LockScreenFromWallpaper.ps1` 拿到完整异常链才是关键：

```
System.UnauthorizedAccessException: 拒绝访问。 (0x80070005)
该项目没有位于应用程序可以访问的位置（包括应用程序数据文件夹、可通过许可范围进行访问的文件夹
以及保存在 StorageApplicationPermissions 列表中的项目）中。请确认未使用系统或隐藏文件属性标记该文件。
```

这是 `StorageFile.GetFileFromPathAsync` 的存储代理检查，不是 NTFS 权限（同一时刻 `Get-Item`、`Copy-Item` 都正常），也不是隐藏/系统属性。Raycast 是 MSIX 打包应用（`%LOCALAPPDATA%\Packages\Raycast.Raycast_qypenmj9wpt2a`），它派生的 `powershell.exe` 继承包身份，于是 `%LOCALAPPDATA%\Lat3ncy\lockscreen` 里的副本被判成「非应用可访问位置」。旧实现「复制到 LOCALAPPDATA 再交给 StorageFile」的思路在打包进程里走不通，锁屏一直没变，读回校验读到旧图后也只留下一个 `exit code 1`。

### 修复

| 位置 | 改动 |
|---|---|
| `Set-LockScreenFromWallpaper.ps1` | 主路径换成 `LockScreen.SetImageStreamAsync`：普通文件 IO 读字节 → `AsRandomAccessStream` → 交给系统。流接口不做路径可访问性检查，也不再需要磁盘副本。16-bit PNG 会被流接口拒（约 15s 后 `RPC_E_CALL_CANCELED 0x80010002`），此时用 `System.Drawing` 转同尺寸 24bpp JPEG 再走同一路。 |
| 同上 | 新增 `-ResultFile`：UTF-8 的 `status/method/source/error` 单行键值，父进程据此记日志、弹 Toast。退出码区分 1（设置失败）/ 2（读回校验不过）。 |
| `ThemeUtils.ps1` | `Sync-LockScreenWallpaper` 改用 .NET `Process` 启动子进程（`Start-Process -RedirectStandard*` 在 pwsh 7 下 `ExitCode` 返回 `null`，实测踩到）；超时 20s → 60s；失败原因写进 `$script:ThemeLockScreenError`；`Write-ThemeLog` 固定 UTF-8（5.1 的 `Add-Content` 默认 ANSI，和 pwsh 7 混写会乱码）。 |
| `next-wallpaper.ps1` | 失败 Toast 带上真实原因（截断 200 字）。 |

### 验证

- 直接跑脚本：3189x2048 JPG、3840x1608 16-bit PNG、6000x3000 JPG、3840x2160 JPG 全部 `exit 0`，读回尺寸与源一致（大图耗时 2-19s）。
- `Sync-LockScreenWallpaper` 在 pwsh 7（Raycast 路径）和 Windows PowerShell 5.1（计划任务路径）下都返回 `true`，日志形如 `LockScreen synced from ... (SetImageStreamAsync)`。
- 失败用例（文本文件改名成 .jpg）现在会把 `Get-ImagePixelSize : 使用“1”个参数调用“FromFile”时发生异常……` 带回调用方，不再只有 `exit code 1`。

### 未验证 / 注意

- Raycast 里的一次真实点击：沙箱内的 pwsh 设置桌面壁纸会静默失败（`SystemParametersInfo` 返回 0，代码没看返回值），端到端只验证到锁屏半段；需要在 Raycast 点一次确认。
- 计划任务的下一次自动切换（07:xx / 18:xx）才会走到 5.1 父进程那条路径。
- `%LOCALAPPDATA%\Lat3ncy\lockscreen` 下旧版留下的副本已无用，可以手动删（约 25MB）。

## 2026-11-02：Caps+D 报「蓝牙已连但立体声未就绪」——A2DP 服务已启用但链路卡死

### 现象
- 反馈：蓝牙耳机连上后按 `Caps+D` 一直弹 `蓝牙已连但立体声未就绪`。
- `audio-switcher.exe --debug --toggle` 在该状态下只打一行错误就退出：既不等待，也不重试。

### 现场证据（本机 ThinkPad T14p + AirPods，2026-11-02）
- WASAPI 里立体声终点有两个来源：`{a55ecf0f...}`（Intel BT audio offload，运行期名 `耳机 (Jie's AirPods - Find My)`，通常是默认）和 `{215ae6d0...}`（BthA2dp）。卡死时两者都非 ACTIVE，但蓝牙层 `BluetoothGetDeviceInfo` 的 `fConnected` 非 0；`pnputil /enum-devices /connected` 只有 `Dev_D8A25EFAC145` + SDP + AVRCP 节点，**没有 0000110B / 0000111E**。
- `BluetoothEnumerateInstalledServices` 已列出 `0000110b`，所以 `BluetoothSetServiceState(A2DP, Enable)` 返回 **87（已是该状态）**，旧逻辑判 `LinkActionSucceeded=false`，直接落 `蓝牙已连但立体声未就绪`，完全不等 Windows 把终点带起来。
- 实测 `Disable→Enable` A2DP（`bounce.exe`，只读探针）：`SetServiceState` 前后 `fConnected` 始终非 0（耳机不掉线，HFP 终点 `{e36af7a6}` 保持 ACTIVE），**A2DP 终点约 0.5s 内回到 ACTIVE**，默认输出也恢复。
- 结论：旧决策「永不 `BluetoothServiceDisable`」是基于早期"怕踢掉耳机"的假设，本次实测不成立——它只重协商 A2DP profile，不动配对/链路。

### 修复
| 位置 | 改动 |
|---|---|
| `FinishHeadsetConnect` | `BluetoothConnected` 分支不再立即失败：先 `WaitForActiveHeadset(StuckWaitMs=4s)`，仍未就绪则 `TryRecoverA2dpLink()`，再 `WaitForActiveHeadset(RecoverWaitMs=8s)`，都失败才报原消息。总预算仍在 AHK `ChildTimeoutMs=18s` 内。 |
| `TryRecoverA2dpLink` / `TryRecoverA2dpOnRadio` | 只对当前 `fConnected != 0` 的首选耳机做 A2DP `Disable`→(700ms)→`Enable`，日志 `recover A2DP disable/enable`、`recover skip disconnected`。 |
| `--recover` | 新增手动修复命令（输出 `RECOVERED` / `RECOVER_FAILED`），卡住时可单独跑一次。 |
| `ahk/tests/run-tests.ahk` | 契约改为断言恢复路径存在、只对已连耳机 bounce、不 `BluetoothRemoveDevice`。 |

### 验证
- 用户会话内用 `--recover` 实跑：`recover A2DP disable ... err=0` / `enable ... err=0` → `TryRecoverA2dpLink=True`，AirPods 终点保持 ACTIVE + 默认。
- 新 exe `--toggle` 回归：当前状态直接返回 `ONLY_ONE|耳机 (Jie's AirPods - Find My)`（无 G27Q2 扬声器时是预期行为），无回归。

### 未验证 / 注意
- 真实「服务已启用但链路卡死」难以手工复现（本次只验证了恢复动作本身）；下次复现时应确认 `Caps+D` 能在 ~12s 内自动恢复而不是弹错。
- 本机 AirPods 音频走 Intel offload 终点，**A2DP 服务状态与终点 ACTIVE 并不同步**，后续排查不要只看 `SetServiceState` 返回值。
- 工具每次运行都会写 `%TEMP%\lat3ncy-audio-debug.log`（`--debug` 还会回显到 stderr），排查优先看它。

### 2026-11-02（续）：第一次修复没生效——`fConnected` 抖动让恢复被跳过、等待又太短

第一次修复上线后用户按 `Caps+D` 仍弹同一条提示。用新加的持久日志拿到了现场：

```
11:25:02  BluetoothSetServiceState A2DP err=87 Adv err=1060      ← 服务已是启用状态，Enable 是空操作
11:25:05  PreferredHeadsetBluetoothConnected=True link=False remembered=True
11:25:05  WaitForActiveHeadset start waitMs=3000
11:25:08  WaitForActiveHeadset timeout
11:25:08  recover skip disconnected Jie's AirPods                 ← 关键：恢复被跳过
```

**根因 1（恢复被跳过）**：`TryRecoverA2dpOnRadio` 里用 `fresh.fConnected == 0` 当“别动离线设备”的门槛，但 AirPods 空闲时 `fConnected` 会抖动——同一轮里 3 秒前 `PreferredHeadsetBluetoothConnected` 读到非 0，3 秒后读成 0。门槛直接把唯一有效的修复跳过了。

**根因 2（等待太短）**：放宽门槛后实测恢复本身有效，但节奏比预期慢：

```
11:26:49  recover state conn=0 rem=16 auth=8
11:27:04  recover A2DP disable err=0      ← 耳机睡着时 Disable 要 15s（内部在 page 设备）
11:27:08  recover A2DP enable err=0
11:27:13  等 4s 没等到终点，进程退出
11:27:22  终点 ACTIVE，Windows 自动把它设成默认   ← 其实救回来了，只是晚于等待窗口
```

即：耳机在耳朵上时重协商 ~1s 就绪；空闲/睡眠时要 15-20s。旧等待 4s 必然错过。

### 修复（第二轮）
| 位置 | 改动 |
|---|---|
| `TryRecoverA2dpOnRadio` | 门槛改为“未配对/未认证才跳过”，并记录 `conn/rem/auth`；`fConnected` 不再作为跳过依据。 |
| `FinishHeadsetConnect` | 恢复后等待 `RecoverWaitMs=14000`（原 4s），第一次短等 `StuckWaitMs=2000`。最坏路径约 40s。 |
| `audio-switcher.ahk` | `ChildTimeoutMs 24000→48000`（覆盖慢路径）；子进程超过 8s 时补一个 HUD「正在唤醒耳机，请稍候…」，避免看起来没反应。 |
| 日志 | 首选 `%LOCALAPPDATA%\lat3ncy-toolbox\audio-switcher.log`，失败回退 `%TEMP%\lat3ncy-audio-debug.log`，再回退 exe 目录；每次运行写一行 `run args=… user=… temp=… tempFailed=…`。此前 `%TEMP%` 写失败时完全没痕迹，排查看不到现场。 |
| `--recover` | 手动修复命令保留。 |

### 验证
- 重载工具箱（`restart-autohotkey.ps1`，新 AHK PID 27616，11:30:21 启动）后，新的 exe + 新超时都生效。
- 恢复动作在用户会话实测把 A2DP 拉回 ACTIVE，Windows 自动把 AirPods 设为默认输出。
- 之后一次真实 `--toggle` 的日志确认：`recover A2DP disable/enable err=0` → 终点 ACTIVE。

### 注意
- 耳机睡眠时整条链最坏要 ~20-40s，属于蓝牙侧唤醒/重连耗时，不是工具空等；期间 HUD 会显示「正在唤醒耳机」。
- 若耳机同时被 iPhone 占着音频，重协商也可能抢不过来，需要在手机侧断开/暂停。

## 2026-11-06：Screenshot OCR「只截图、不分析」——scoop 升 Python 后整批二进制包变砖

### 现象
Raycast 里点 Screenshot OCR：截图框正常弹出、框选正常，之后**没有任何 OCR 结果、没有任何 Toast**，像功能没发生一样。

### 根因链（每一环都有实测证据）
1. `screenshot-ocr.ps1` 先 `Start-Process ms-screenclip:` 弹系统截图框——这步永远成功，所以「只截图」；
2. 再启动 `pythonw ocr.py --no-screenshot --result-file`；ocr.py 一进 `load_engine()` 就 `import rapidocr_onnxruntime` → `import cv2` → `import numpy` 崩溃；
3. 崩因：**scoop 的 site-packages 是 persist junction（`scoop\persist\python\Lib\site-packages`），跨版本升级原样保留旧包**。时间线：
   - 2026-09-21/23：在 Python **3.14** 下装了 numpy 2.5.3 / opencv / onnxruntime / pyclipper / shapely / aiohttp 全家（全是 cp314 二进制）；
   - 2026-10-12：scoop 装 Python **3.15.0**；
   - 2026-11-04：scoop 升 Python **3.15.2**——site-packages 里的 cp314 .pyd 在 3.15 下全部 `ModuleNotFoundError: No module named 'numpy._core._multiarray_umath'`；
   - 2026-10-25：Pillow 曾单独重装（cp315），所以 PIL 一直正常——这也是截图框能弹、Clipboard 抓图不报错的原因。
4. 失败被静默吞掉的三层原因：
   - `ocr.py` 旧版 `load_engine()` 失败只是 `notify()`（静默模式下直接 return）+ `return None` → `return 1`，**不写 result 文件**；
   - `screenshot-ocr.ps1` 旧版对 `ExitCode -ne 0` 只弹固定文案「识别进程异常退出」；但实际连这个 Toast 都少见——`Start-Process -PassThru` 拿到的 `$process` 对 `pythonw`（GUI 子系统）**没有重定向 stderr，异常文本直接丢控制台**；
   - 结果文件不存在时走「放弃或未截图时静默退出」分支——错误与「用户按了 Esc」不可区分。

### 修复
| 位置 | 改动 |
|---|---|
| `ocr.py` | 失败协议：`--result-file` 模式下异常统一写成首行 `ERROR: <原因>` 再 exit 1；`load_engine()` 失败改为抛 `RuntimeError`（原因含错误类名），不再 notify+None 静默；错误消息压单行、截 200 字。 |
| `screenshot-ocr.ps1` | `ExitCode -ne 0` 时读 result 文件，`ERROR:` 前缀剥掉后透传给 `Show-SystemToast`；文件缺失/无前缀才回落「识别进程异常退出」。 |
| `ocr/install-deps.py` | `module_installed()` 从 `find_spec` 改为**真实 `__import__`**：二进制不兼容的包会被判为缺失，触发 `--force-reinstall`；装完仍 import 失败时给出方向性指引（onnxruntime wheel 滞后 / 换 system 引擎）。 |
| `ocr/config.toml` | `ocr = "rapidocr"` → `"system"`：**onnxruntime 1.31.1 最高只有 cp314 wheel，Python 3.15 下 RapidOCR 物理不可用**，系统 OCR（Win+Shift+T，本机 build 26300 支持）接管；注释写明切回条件。 |
| 环境修复（site-packages） | 重装 cp315 wheel：numpy 2.5.4 / opencv 5.0.0.93 / shapely 2.2.0 / aiohttp 3.14.5 / multidict / yarl / propcache；pyyaml / frozenlist 无 cp315 wheel、本机无 MSVC 编译失败，但**纯 Python 回退可用**（`yaml.safe_load` OK，仅 CSafeLoader 缺失）。 |
| `screenshot-ocr.ps1` | 补 UTF-8 BOM（含中文注释，遵循仓库 5.1 ANSI 解码规则），PS 5.1 ParseFile 0 错误。 |
| `ahk/tests/run-tests.ahk` | 新增 3 条契约断言：ocr.py 写 `ERROR:` 行、ps1 读 `ERROR:` 前缀、保留通用兜底文案。 |

### 副产物影响（同一根因的波及面）
| 包 | 状态 |
|---|---|
| numpy / opencv / shapely / aiohttp 系 | 已重装 cp315，import OK |
| **RGB `ambient.py`** | 核心链路（mss 抓屏 320x180 + numpy 分析）实测恢复；但顶层 `from hi75 import` 依赖 `lib_hid/hid.pyd`（cp314 手动编译产物，9-21 放置），`import hid` 失败 → **ambient 整体仍跑不起来**，需按 cp315 重新编译 hid.pyd（无 MSVC，待办） |
| onnxruntime / rapidocr-onnxruntime | 3.15 无 wheel，保留安装但不可用；等 onnxruntime 发 cp315 或降级 Python |
| pyyaml / frozenlist | 纯 Python 回退可用（TTS 的 edge-tts 路径不受影响，aiohttp 已修） |
| pyclipper | 无 cp315 wheel 且本机无 MSVC，装不上；rapidocr 的依赖，同为待 onnxruntime |
| TTS（edge_tts） | `import edge_tts` OK（其 aiohttp 依赖已修复） |

### 验证
- `python ocr.py --no-screenshot --result-file <tmp>`（当前坏 rapidocr 环境）：exit 1，result 文件首行 `ERROR: RapidOCR 不可用（ImportError）…` ✓（新协议生效）
- `screenshot-ocr.ps1` PS 5.1 ParseFile 0 错误；BOM 已补。
- `python -m py_compile` ocr.py / install-deps.py 通过。
- system 引擎路径：`ms-screenclip:` 协议启动 + Win+Shift+T 注入不变（代码未动该分支），本机 build 26300 ≥ 23H2。
- RGB 抓屏分析路径：mss + numpy 实测 OK（`grab ok: (180, 320, 4)`）。

### 未验证 / 待办
- **端到端**：Raycast 里真实点一次 Screenshot OCR，确认 Win+Shift+T 框选识别复制符合预期（system 分支代码未改，但值得点一次确认）。
- **hid.pyd 重建**：RGB 键盘灯（hi75）仍不可用；需要装 VS Build Tools 或在 Python 3.14 环境重编 `lib_hid/hid.pyd`。
- **RapidOCR 回归**：等 onnxruntime 发布 cp315 wheel 后，`pip install -U onnxruntime` + config.toml 切回 `rapidocr`。
- `screenshot-ocr.ps1` 的 `Start-Process` 未重定向 stderr，`pythonw` 下异常输出仍不可见——但有了 result-file 协议后关键错误已能透传，此为次优先级。
## 2026-11-06（续）：RapidOCR 切回——onnxruntime 无 cp315 wheel 的解法是专用 3.14 venv

用户确认 system OCR 可用后要求切回 RapidOCR。onnxruntime 1.31.1 仍只有 cp311-cp314 wheel，全局 Python 3.15 物理装不上；不动全局解释器（TTS/RGB 还依赖它），改用 **uv 管理的 Python 3.14.10 专用 venv** 承载 RapidOCR。

### 方案
| 项 | 决定 |
|---|---|
| venv 位置 | `tools/raycast-scripts/ocr/.venv314`（uv venv 自动生成 `.gitignore`，整目录不入库，git check-ignore 验证过） |
| 解释器 | uv 下载的 CPython 3.14.10（scoop persist 区，机器级可复用） |
| uv 安装 | `scoop install uv`（0.13.7；persist 提示：旧 `%APPDATA%\uv` 数据需手动迁移，本机首次安装无历史数据） |
| 依赖 | `uv pip install rapidocr-onnxruntime pillow pyperclip` → rapidocr-onnxruntime 顺带升到 1.4.4，全套 cp314 wheel |
| Python 解析顺序（screenshot-ocr.ps1） | `ocr\.venv314\Scripts\pythonw.exe` 优先 → 全局 `pythonw.exe` → `pyw.exe` 兜底（venv 缺失时 Python ≤3.14 机器直接可用） |
| config.toml | `ocr = "rapidocr"` 切回；注释写明 venv 重建命令与 wheel 滞后背景 |

### 验证（全链路实测）
- venv 内 `RapidOCR()` 引擎加载 + 合成图识别：`Hello 世界 12345 Test` ✓
- 剪贴板真图 → `python ocr.py --no-screenshot --result-file`（走 venv）：exit 0，result 文件内容正确 ✓
- `screenshot-ocr.ps1` PS 5.1 ParseFile 0 错误；BOM 完好（本轮编辑后曾丢失，已补——**edit 工具改含 BOM 文件会重写无 BOM 副本，改完必须复查**）。
- run-tests.ps1 全绿（含新增 venv 解析契约断言）。

### 沙箱注意
DSH 会话内直接跑 ocr.py 写 `%TEMP%` 会被沙箱拦截（PermissionError）——是本会话的文件策略，不是 ocr.py 缺陷；Raycast 真实运行不受影响。会话内验证时 result 文件要放 workspace 内。

### 待办更新
- ~~切回 rapidocr~~ 完成。
- RGB hid.pyd 仍待重编（与 OCR venv 无关，是 lib_hid 的 cp314 产物问题；如法炮制建 3.14 venv 也可解，待用户决定）。
- onnxruntime 发布 cp315 wheel 后：`uv pip install -U onnxruntime` 也只升 venv；全局 3.15 环境是否补装由 TTS/RGB 需求决定，OCR 已与之解耦。
## 2026-11-06（三）：切回 RapidOCR 后 Raycast 弹 "Script execution failed"——是 30s IPC 超时，不是脚本崩

### 现象
按前文切回 rapidocr 后，Raycast 里点 Screenshot OCR：截图框正常、能框选，随后 Raycast UI 弹 **Script execution failed**。

### 证据（Raycast 生产日志，`%LOCALAPPDATA%\Raycast\Logs\Raycast-Production-20261106.log`）
```
[INF 13:46:48 frontend/main] Action performed: Script Commands: runScript
[INF 13:46:48 backend] [handler::script-commands] Running script {
[WRN 13:46:52 host] Clipboard change ... SnippingTool.exe        ← 用户已框选完成
[ERR 13:47:18 host] [backend-coordinator] Host request timed out:
  method=scriptCommands.runScript, oldest_request_age_ms=30005, concurrent_requests=1
```
即：**Raycast host 对 `scriptCommands.runScript` 的 IPC 请求有 30s 硬超时**，到点直接判失败并弹 HUD。脚本头 `@raycast.timeout 90000` 只影响后端执行层的等待，**管不到 host 这一层**。

### 根因
uv venv（Python 3.14）冷启动 + RapidOCR 三模型（det/cls/rec ONNX）加载**实测 >30s**（全局 Python 热缓存时不会这么慢，venv 首次冷启动叠加 numpy/cv2/onnxruntime 加载）。ps1 里 `$process.WaitForExit(90000)` 让脚本阻塞 90s，Raycast 30s 就翻脸了。

### 修复（detached 模式）
| 位置 | 改动 |
|---|---|
| `screenshot-ocr.ps1` | **不再 WaitForExit**：`Start-Process pythonw -WindowStyle Hidden` 启动后立即 `exit 0`；ps1 只当触发器。注释写明 30s IPC 超时证据。 |
| `ocr.py` | 新增 `--notify-on-done`：结果 Toast 由本脚本自己弹（复用 `shared/notify/toast.ps1`），不再依赖 ps1 读 result 文件。`_SILENT_MODE` 判定改为 `result_file is not None and not notify_on_done`。 |
| `ocr.py notify()` | 两处加固：① Toast 文案走 **base64 UTF-8 runner**（纯 ASCII 临时 ps1），彻底避免 powershell.exe 5.1 按 GBK 解码中文乱码；② `Popen(...).wait(timeout=10)`——不对父进程等待时，pythonw 退出会把还没显示的 Toast 子进程一并回收。 |
| `ahk/tests/run-tests.ahk` | 断言改为 detached 契约：ps1 不得含 `WaitForExit`、必须传 `--notify-on-done`；成功 Toast 断言移到 `ocr.py` 的 `✓ OCR 文本已复制`。 |

### 验证
- 全链路（剪贴板真图 → venv pythonw → RapidOCR → Toast）：**6 秒完成**，中文完整识别（`中文编码测试 Base64 9527`），exit 0，runner 文件无残留。
- `run-tests.ps1` 全绿（含 3 条新 detached 断言）。
- ps1 PS 5.1 ParseFile 0 错误、BOM 完好。

### 教训
- **`@raycast.timeout` 不是全链路超时**：它只管后端执行层；host↔backend IPC 另有 30s 上限（`oldest_request_age_ms=30005`）。任何 >30s 的 Raycast 脚本都应改「立即退出 + 自通知」。
- **edit 工具会抹掉 UTF-8 BOM**（本会话第 3 次踩到）：改含中文的 `.ps1` 后必须 `[IO.File]::ReadAllBytes(...)[0..2]` 复查，并用 `powershell.exe 5.1` 的 ParseFile（不是 pwsh 7，pwsh 无 BOM 也能读 UTF-8，会漏报）复核。
## 2026-11-06（四）：WMI 启动——detached 还不够，Start-Process 的管道继承才是 30s 超时真凶

### 现象
上一轮改成 `Start-Process ... -WindowStyle Hidden` + 立即 `exit 0` 后，Raycast 仍然 30s 超时（`14:18:08 Host request timed out: runScript, oldest_request_age_ms=30008`）。

### 证据（Node spawn 复刻 Raycast 的 stdio:pipe 行为）
| 变体 | EXIT | CLOSE |
|---|---|---|
| `Start-Process -WindowStyle Hidden` | **40s 不触发**（powershell 进程残留） | 不触发 |
| WMI `Win32_Process.Create` | 1.7s | 1.7s |

- `-WindowStyle Hidden` 会强制 `UseShellExecute=false`，pythonw **继承本进程的 stdout/stderr 管道**；Raycast 后端要等整棵进程树/管道结束才认为 `runScript` 完成。引擎冷启动 + 45s 剪贴板轮询期间，必然撞 30s 上限。
- WMI `Win32_Process.Create` 由 WmiPrvSE 创建进程：无句柄继承、不在调用方进程树/Job 里。实测 PID 落在用户 session（SessionId=1），可正常访问剪贴板/Toast。

### 修复
| 位置 | 改动 |
|---|---|
| `screenshot-ocr.ps1` | `Start-Process pythonw` → `Invoke-CimMethod -ClassName Win32_Process -MethodName Create`；ReturnValue≠0 时 Toast 报错。ps1 实测 802ms 退出（Raycast 复刻下 EXIT/CLOSE 同时触发）。 |
| `ocr.py` | 新增**剪贴板序列号守护** `_clipboard_sequence()`（`GetClipboardSequenceNumber`）：基线在出框/加载引擎前读取，只接受序列号变化后的图片。否则剪贴板里残留的旧截图会被立刻误识别（实测过：旧图 A + 3s 后新图 B → 以前认 A，现在正确认 B）。 |

### 验证
- Raycast 复刻（Node spawn + pipe）跑真实 ps1：**802ms EXIT/CLOSE**，无超时。
- WMI 直启 ocr.py：result 文件写入正确（`WMI Spawn / Test 7731 你好世界`），剪贴板被识别文本覆盖，pythonw 干净退出。
- 剪贴板序列号守护：旧图 A 在剪贴板、3s 后换新图 B → 识别结果 `FRESH IMAGE BBB` ✓
- `run-tests.ps1` 全绿，含新增 3 条契约（WMI 启动 / 禁止 Start-Process pythonw / 序列号守护）。

### 教训
- **Raycast 脚本的"完成"不等于"主进程退出"**：继承的管道/子进程都会拖住它。要真正脱离，必须让子进程既不属于调用方进程树、也不继承句柄——WMI `Win32_Process.Create` 是 PowerShell 里最省事的做法。
- 剪贴板轮询型工具必须用序列号做"新鲜度"判据，否则永远会先吞下上一次的剪贴板内容。
## 2026-11-06（五）：框选后"长时间等待没有反应"——write_result 失败吞掉了剪贴板和 Toast

### 现象
超时问题修好后，Raycast 不再报错，但**框选完成后等很久也没有任何反应**：没有结果、没有 Toast、剪贴板也没变。

### 根因（新加的 ocr\.debug.log 一次定位）
```
23:31:19 ps1 mode=rapidocr ... result=C:\...\Temp\lat3ncy-ocr-result-<guid>.txt
23:31:19 wmi rv=0 pid=35516          ← 进程起来得很快（0.24s 退出）
23:31:20 py start session=1          ← 会话正确，能访问桌面
23:31:20 py baseline_seq=1016
23:31:24 py engine ready             ← 引擎 4s 加载完成
23:31:24 py clipboard image (620,140) seq=1016->1025   ← 图抓到了、识别跑了
23:31:31 py write_result failed (ignored): [Errno 13] Permission denied: '...\Temp\...txt'
23:31:31 py done exit=0
```
**识别其实成功了**，但旧 `recognize()` 的顺序是 `write_result()` → `copy_to_clipboard()` → `notify()`。`%TEMP%` 写入抛 `PermissionError` 后直接冒泡到 `main()` 的 except，**后面两件真正给用户看的动作全被跳过**——用户侧就是"框选完、等半天、什么都没有"。

（`%TEMP%` 被拒的诱因是本会话的 DSH 沙箱；但代码顺序才是真 bug：诊断副产物的失败不该吃掉交付动作。）

### 修复
| 位置 | 改动 |
|---|---|
| `ocr.py recognize()` | 顺序改为 **Toast → 复制剪贴板 → best-effort 写 result 文件**；`write_result` 用 try/except 包住，失败只记日志（`write_result failed (ignored)`）不影响返回值。 |
| `ocr.py notify()` | Toast runner 改为**候选路径**：脚本目录 `ocr\.toast-<pid>.ps1` 优先，失败再回落 `%TEMP%`；两者都不可写才放弃并记日志（此前单一路径写 TEMP，TEMP 被拒 = Toast 永远发不出）。 |
| `ahk/tests/run-tests.ahk` | 断言改为：必须用 WMI；**禁止出现 `-WindowStyle Hidden`**（普通 Start-Process 仅作兜底，实测 6-11s 仍 < 30s）。 |

### 验证（本地全链路，含真实剪贴板图片）
```
ps1 23:32:02.406 起 → 23:32:02.641 ps1 exit（0.24s，Raycast 秒返回）
py  23:32:03 start session=1 → 23:32:06 engine ready
py  23:32:06 clipboard image (640,140) seq=1046->1055
py  23:32:13 write_result failed (ignored) → done exit=0
剪贴板 = 「最终验证 Toast 3690」   ← 交付成功
toast runner 残留 = 0
```
- `run-tests.ps1` 全绿。
- ps1 BOM 完好、PS 5.1 解析 0 错误。

### 教训
- **诊断副产物（result 文件/日志）必须 best-effort**，绝不能排在用户可见交付（剪贴板 + Toast）前面。
- 临时文件路径不能只写死 `%TEMP%`：打包应用/沙箱/策略都可能拒绝，要有同仓库内的回落路径。
- 这一串问题的排查顺序很典型：**先看 Raycast 生产日志**（发现 30s IPC 超时）→**再做进程对照实验**（发现 -WindowStyle 继承管道）→**最后靠自建 debug.log**（发现 write_result 吞掉交付）。每一步都必须先有证据再改代码。
## 2026-11-06（六）：OCR 框选后"没有反应"——notify 被 tempfile 打断 + 引擎被高负载饿死

### 现象
Raycast 不再报错、ps1 也秒退，但框选完**看不到任何结果**，就是"没反应"。

### 证据（ocr\.debug.log，修复后补了 notify 的 rc/stderr）
```
23:37:13 py clipboard image (1877, 737)     ← 图抓到了
23:37:34 py notify threw: FileNotFoundError(2, "No usable temporary directory found in
         ['C:\\...\\Temp', 'C:\\Windows\\Temp', 'c:\\temp', ...]")
23:37:35 py done exit=0
```
两个独立缺陷叠在一起：

1. **Toast 从来没弹出来**：`notify()` 里用 `tempfile.gettempdir()` 拿临时目录写 PowerShell runner，而它在 TEMP 不可用时**抛 FileNotFoundError**（不是返回路径），异常被外层 `except Exception: return` 静默吞掉 → 用户永远看不到"已复制"。
2. **识别慢到像卡死**：实测 `1877x737` 首次推理 9-13s；整机 CPU 负载 91% 时**引擎初始化从 2.3s 涨到 20s**——onnxruntime 默认用满全部核心，和前台程序互相抢，反而把自己饿死。

### 修复
| 位置 | 改动 |
|---|---|
| `ocr.py notify()` | 不再用 `tempfile.gettempdir()`；候选路径改为**脚本目录优先** + `os.environ['TEMP']` 回落（纯字符串，不抛异常）。异常分支也写日志（`notify threw:`），不再静默。 |
| `ocr.py notify()` | 增加 `wait` 参数：即时提示用 `wait=False` 立即返回，结果提示用 `wait=True` + `communicate(timeout=10)` 并记录 `rc`/`stderr`。 |
| `ocr.py load_engine()` | 限制 ONNX 线程：`OMP_NUM_THREADS`/`ORT_NUM_THREADS` 默认设 4。高负载下引擎初始化 **20s → 1.3s**。 |
| `ocr.py recognize()` | 大图降采样上限 1600px（长边），`1877x737 → 1600x628`。 |
| `ocr.py run_ocr_from_clipboard()` | 抓到图后**立即弹「OCR 识别中…」**（`wait=False`），解决"等的时候以为没反应"。 |

### 验证（端到端全链路）
```
ps1 启动 → ps1 exit  0.26s      （Raycast 侧零等待）
py start → engine ready  3s      （线程限制生效，负载 87% 下仍 3s）
clipboard image (620,140)
notify fired (no wait)           ← 「识别中」立刻可见
notify rc=0 stderr=''  7s later  ← 结果 Toast 成功
剪贴板 = 「成功 Success 8888」    ← 交付完成
```
- `run-tests.ps1` 全绿。

### 教训
- `tempfile.gettempdir()` **会抛异常**，不能当"总能拿到路径"用；临时文件必须有同仓库内的确定性回落。
- 任何 `except Exception: return` 都必须先 `_debug(...)`——这次正是"静默吞异常"让 Toast 失败变得完全不可见。
- ONNX/OpenMP 类推理库默认吃满所有核心，在交互式小工具里**必须主动限线程**：高负载时抢占会让本来 2s 的事变成 20s。
- 超过 3 秒的操作要有**立即可见的中间反馈**，否则功能正常也会被感知成"坏了"。
