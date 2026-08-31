# 发现与决策

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
| 没有「Raycast 窗口底部提示后再关窗」的 mode | `compact` 留窗；`silent` 关窗。Windows 上 `silent` 的 stdout HUD 不稳，成功改走 `Show-ToolboxNotify`，失败走系统 Toast |
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
