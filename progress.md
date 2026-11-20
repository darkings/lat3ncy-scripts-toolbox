# 进度日志

## 会话：2026-10-01：中英文切换通知不跟光标

### 阶段 1：定位根因（complete）
- 现场证据（`%TEMP%\ImeHudWinUi.log` + 只读探针）：
  - `InputAnchor.TryCaret` 在 Chromium 窗口恒为 `caret=0 rc=(0,0,0,0)`；
  - 工作区里 `shared/notify/ime-hud.ahk` 的热路径**没有** UIA locator，`TryCaret` 失败直接 `TryWindowBottom`；
  - `anchor-locator.exe --hwnd <Chrome>` 也只返回 `focus-bounds`（= 窗口矩形 85% 处），和 `TryWindowBottom` 算出来的坐标完全一致；
  - 结论：不是渲染问题，是锚点静默退化到「窗口底部中心」。
- 修正一个一开始的误判：`GetGUIThreadInfo(0)` 返回的是**前台线程**信息，不是 bug。

### 阶段 2：实现（complete）
- `shared/notify/AnchorLocator.cs` 重写（仍用 Framework `csc.exe` 编译，只能 C# 5 语法）：
  - 输出带来源：`OK|x|y|w|h|source|caretHeight`，旧 `x|y|source` 保留；
  - 真光标白名单 `text-caret` / `imm-caret` / `win32-caret`，`focus-bounds` 等一律标退化；
  - L1 TSF/UIA 文本光标只接受插入点矩形，并对目标窗口做 `AccessibleObjectFromWindow` 无障碍预热；
  - `--watch` 跟随模式（`A|` / `L|` / `E|` 行协议）；`--self-test` 不碰 UIA。
- `shared/notify/anchor.ahk`：新增 `InputAnchor.RealCaretSources` / `IsRealCaretSource()`。
- `shared/notify/ime-hud.ahk`：`LocateAnchor()` + `ProbeLocator()` 结构化解析；`LastAnchorSource` / `LastAnchorReal` 观测字段；`FollowAnchor()`（只对真光标启动 `--watch`，读 stdout 文件推 `MOVE`）；`DisableSend` 仅测试用。
- `tools/ime-hud-winui`：`Protocol` 支持 `MOVE` 与第 8 段 `anchorSource`（含 `IsRealCaretSource`）；`HudHost` 处理 `MOVE` 重定位、`place ... anchor= real=` 与 `anchor-degraded` 告警日志。

### 阶段 3：验证（complete，含未覆盖项）
- `anchor-locator.exe --self-test` → exit 0；`ImeHudWinUi.exe --self-test` → exit 0。
- `ahk/tests/run-tests.ps1` 全绿（20 AHK 独立加载 + 31 PS AST + `PASS: core assertions`，含新增的来源/跟随契约）。
- 临时端到端（`tmp-probe/e2e`，stub locator，未改生产文件）：`STATE|CN|1111|2222|0|0|<hwnd>|text-caret` 拼装正确、来源解析与退化标记正确。
- **未能在本会话覆盖**：真实 Chromium 窗口里 UIA 能否给出 `text-caret`。探测显示本机 UIA 拿不到 Chrome 内容树（`FocusedElement` 只返回顶层窗口），所以会落到 `anchor-degraded`。需要用户在真实桌面按 CapsLock 后看日志确认。
- 未执行：`git commit`；`tmp-probe/` 已删除。

### 阶段 4：部署闭环（complete）
- 用户重载后仍不跟光标；日志证明「**旧代码还在跑**」：`copydata=STATE|...` 仍是 7 段老格式、`build hud=anchor-source-1` 一次都没有、`%TEMP%\ImeHudClient.log` 不存在（新客户端必写）。
- 沙箱无法代重启：`tasklist` Access denied、`schtasks`/Task Scheduler COM 0x80070003、`Get-CimInstance` 看不到用户 AHK/HUD、`FindWindowW` 在自己的 desktop 查不到该窗口（新 exe 转发时能查到 `hwnd=132906`）。最终确认必须由用户在自己的会话执行。
- 按用户要求把「结束 HUD + 重载 AHK」**并进现有的** `restart-autohotkey.ps1`（Raycast 里那个 Restart AutoHotkey）：新增 `Stop-ToolboxImeHud`，停不掉就抛错并提示用管理员重跑；`reload-ime-hud.ps1` 只负责编译/发布后调用它，`diagnose-ime-hud-anchor.ps1 -Restart` 也委托给它，避免三处逻辑分叉。
- 新增 `diagnose-ime-hud-anchor.ps1`（只读）：区分「HUD 旧进程 / AHK 旧客户端 / 锚点退化」，只看最近一次 HUD 会话（最后一个 `start pid=` 之后），避免旧日志假阳性。
- AHK 客户端加部署标记：`Show()` 首次写 `client-build=anchor-source-1`，每次写 `anchor state=.. source=.. real=.. x=.. y=.. target=.. sent=..`。
- 踩坑与修复：`restart-autohotkey.ps1` / `reload-ime-hud.ps1` 无 BOM 时 **5.1 解析失败（报在无关行号）**，已补 UTF-8 BOM；纯 ASCII 的 `diagnose-*.ps1` 保持无 BOM。
- 测试：全套仍全绿（20 AHK 独立加载 + 33 PS AST + `PASS: core assertions`），两个 exe 自检 exit 0；新增断言覆盖「restart 脚本必须一起停 HUD」。

### 阶段 5：待用户确认（blocked on real desktop）
- 需要用户跑一次 `restart-autohotkey.ps1`（或 Raycast 的 Restart AutoHotkey），按一次 CapsLock，再把 `diagnose-ime-hud-anchor.ps1` 的输出发回。
- 若结果是 `real=0 / focus-bounds`：说明该应用不向 UIA 暴露插入点，下一步试 Chromium `--force-renderer-accessibility`，或改从 renderer 客户区 `IAccessible` 读插入点。

---

## 会话：2026-08-24

### 阶段 1：需求与发现
- **状态：** complete
- **开始时间：** 2026-08-24
- 执行的操作：
  - 审阅 `tools/audio-switcher/AudioSwitcher.cs` 全链路、`ahk/features/audio-switcher.ahk` 防抖与协议、`tools/tts/tts_player.py` MCI 播放、`ahk/features/speak-selected-text.ahk` 选区朗读
  - 定位乱码与通知不一致问题，grep `airpods/Bluetooth/player`
- 创建/修改的文件：
  - `findings.md`（研究发现沉淀）

### 阶段 2：规划与结构
- **状态：** complete
- **结束时间：** 2026-08-24 14:49
- 执行的操作：
  - 冻结方案：A2DP 仅 Enable、ACTIVE 才 SetDefault、DeviceDesc+注册表找回、WSASetService 双路径、700ms 防抖、TTS opt-in 预热
  - 编写 `task_plan.md` 五阶段计划
- 创建/修改的文件：
  - `task_plan.md`、`progress.md`

### 阶段 3：实现
- **状态：** complete
- **开始时间：** 2026-08-24 14:50
- **结束时间：** 2026-08-24 14:55
- 执行的操作：
  - 新建 `tools/audio-switcher/config.toml`（preferred.headset/speaker、behavior.connect_wait_ms/poll_ms、tts.auto_switch_before_play）
  - 改 `AudioSwitcher.cs`：加 `EnsureConfigLoaded/ParseStringArray/ParseInt`、可配置 `HeadsetKeywords/Exclude/Speaker*`、`FindPreferredSpeaker` 按关键词顺序、新增 `EnsureHeadsetActive()` 与 `--ensure-headset` 入口
  - 改 `ahk/features/speak-selected-text.ahk`：加 `#Include run-nowindow`、`AudioSwitcherExe/IsAutoSwitchEnabled/EnsureHeadset`、`Speak()` 中 `StopCurrent()` 后若 `auto_switch_before_play=true` 则 `ProcessNoWindow.RunWait --ensure-headset`
  - 用 Framework `csc.exe` 重编译 `audio-switcher.exe` 25KB 单文件（`--help` 已含新参数）
- 创建/修改的文件：
  - `tools/audio-switcher/config.toml`、`tools/audio-switcher/AudioSwitcher.cs`、`tools/audio-switcher/audio-switcher.exe`、`ahk/features/speak-selected-text.ahk`

### 阶段 4：测试与验证
- **状态：** complete
- **开始时间：** 2026-08-24 14:55
- 执行的操作：
  - `pwsh -File ahk/tests/run-tests.ps1` 14*AHK 独立加载 + 14*PS AST + core assertions 全绿（修复 `speak` 中 `try{ }catch{}` 空块需 `;` 占位）
  - `audio-switcher.exe --list` 返回 `G27Q2`，`--ensure-headset` 在无 AirPods 机器正确 `ERROR|耳机未就绪` 不阻塞
- 创建/修改的文件：
  - `ahk/features/speak-selected-text.ahk`（catch 空块修复）

### 阶段 5：交付
- **状态：** complete
- **开始时间：** 2026-08-24 15:00
- **结束时间：** 2026-08-24 15:10
- 执行的操作：
  - 更新 `README.md`：补 `Caps+D` 行、新增 `## Audio Switcher`、TTS 耳机预热、仓库结构
  - 全量回归 `run-tests.ps1` 通过
- 创建/修改的文件：
  - `README.md`、`task_plan.md`、`progress.md`

### 阶段 6：免手动一键直连
- **状态：** complete
- **开始时间：** 2026-08-24 15:15
- **结束时间：** 2026-08-24 15:20
- 执行的操作：
  - `shared/notify/run-nowindow.ahk` 改 `FILE_SHARE_READ|WRITE` 并加 `DirCreate/FileDelete` 重试，`CreateFileW err` 带码抛错；`catch{}` 加 `;` 占位
  - `ahk/features/audio-switcher.ahk` 改唯一临时文件名 `lat3ncy-audio-switcher-<tick>-<rand>.txt`，`RunWait` 失败时 fallback 无文件直切并 `Notify.Success`
  - `ahk/features/speak-selected-text.ahk` 同步唯一名 + fallback
  - `tools/audio-switcher/AudioSwitcher.cs` 加 `freshProbe` 刷新后判名（空名漏判修复），`TryFindAirPodsAddress/EnableAirPodsA2dpOnRadio` 均处理 `Address==0` 跳过，`ConnectWaitMs` 8000→12000
  - 重编译 `audio-switcher.exe` 并 `run-tests.ps1` 全绿
- 创建/修改的文件：
  - `shared/notify/run-nowindow.ahk`、`ahk/features/audio-switcher.ahk`、`ahk/features/speak-selected-text.ahk`、`tools/audio-switcher/AudioSwitcher.cs`、`tools/audio-switcher/config.toml`、`tools/audio-switcher/audio-switcher.exe`

## 测试结果
| 测试 | 输入 | 预期结果 | 实际结果 | 状态 |
|------|------|---------|---------|------|
| 契约 11 项 | `run-tests.ahk:483` 11 断言 | A2DP/Hands-Free/ACTIVE/AddRemembered/WSASetService 等 | PASS: core assertions 全绿 | pass |
| 独立加载 | 14 AHK + 14 PS AST | 全部 PASS | 14+14 PASS（含修复后 speak） | pass |
| 手测 --list | 无参数 | 列出 G27Q2 | `*|G27Q2` | pass |
| 手测 --ensure | --ensure-headset 无 AirPods | ERROR|耳机未就绪 | ERROR|耳机未就绪 | pass |
| TTS 预热 | Caps+S auto_switch=true | 先 RunWait ensure 再播 | 日志 `预热耳机: ERROR|耳机未就绪` 不阻塞 | pass |

## 错误日志
| 时间戳 | 错误 | 尝试次数 | 解决方案 |
|--------|------|---------|---------|
| 2026-08-24 | Raycast `鈭?` 乱码 | 1 | 已补 BOM 并改 √->✓，见 task_plan |
| 2026-08-24 | screenshot-ocr 走 Raycast 气泡 | 1 | trap exit 0 统一 Toast |
| 2026-08-24 | `speak` 独立加载 `} catch {}` 空块解析失败 | 1 | 空 catch 需占位语句 `;`，已改为 `catch { ; }` |
| 2026-08-24 | `dotnet csc.dll` 无引用编译失败 | 1 | 改用 Framework `csc.exe` 单文件编译 + 临时 dotnet 项目 AssemblyName 修正 |
| 2026-08-24 | 音频切换 `无法创建输出文件` | 1 | `run-nowindow` 改 `FILE_SHARE_READ|WRITE` + 唯一文件名 + fallback 无文件直切 |
| 2026-08-24 | `caps-lock-ime` 独立加载因 `run-nowindow` 空 catch 失败 | 1 | `catch{}` 加 `;` 占位 |

## 会话：2026-08-25 RGB Ambient 桌面取色联动

### 阶段 1：环境基线
- **状态：** complete
- 执行：
  - 探测 `B550M DS3H` 注册表 + `VID_258A:010C` 8 HID (3×FF00)
  - 下载 `OpenRGB Pipeline 20.9MB` + `PawnIO 3.25MB` + `hidapi cp312` + `mss 10.2.0/comtypes/psutil`
  - `mss 32x32` 5抓 22ms，`HID Col06` 520B `ret 520` 唯成功口
- 产物：`tools/rgb/OpenRGB-App`, `lib_hid/hid.pyd`, `lib/{mss,openrgb,psutil}`

### 阶段 2：Hi75 HID 逆向
- **状态：** complete
- 执行：
  - 拉取 `OpenRGB #4297` 5×pcapng (api v4), scapy 解析 EPB→USBPcap→Feature Report `060a 520B`
  - 差分 `0684/0604/060a` 三段，定位5×3B色点 (29/93/114/135/156)
  - 锁定 `Col06` 为 Feature 口 (`Col05/03` 返回 -1/0x01)
- 产物：`tools/rgb/hi75_data/*.bin` (17×520B), `tools/rgb/hi75.py` (5 triple patch)

### 阶段 3：ambient 实现
- **状态：** complete
- 执行：
  - `mss` 中心320x180采样 4.6ms/帧 (210fps能力) 替代全屏39ms，`PIL` skip
  - `EMA0.2 + 阈值8 + 亮度16 + 复用句柄 + 首帧3段后续1段`
  - `ambient.py` 490行 支持 `dry-run/bench/time/fps/no-hi75/no-openrgb`
- 产物：`tools/rgb/ambient.py`, `config.toml`

### 阶段 4：联调与压测
- **状态：** complete
- 执行：
  - `hi75 --preset red/green/white` 全 `520` 成功
  - `ambient --dry-run 12Hz` 24帧/2s 均色收敛
  - `bench 20` 210fps, `5Hz 25帧/5s`, `12Hz 60帧/5s`, `30Hz 148帧/5s`
  - 带 HID `12Hz 56帧/14推`, `30Hz 109帧/14推` 阈值省75%
- 结果：`30Hz` 因 HID 20ms/次 实际21.8fps，与12Hz 推次相同，无需30Hz

### 阶段 5：长稳
- **状态：** complete
- 执行：`ambient --time 30 --fps 12 --no-openrgb` 30.2s 181帧14推
  - `psutil` 采样：`CPU avg 0.97% max 50%(首帧)`, `MEM 36.8MB delta 0.0` 无泄漏
  - 重跑 `hi75 --preset white/red` 仍 `520`
- 结论（当时压测）：空闲5Hz/活动12Hz，阈值8。**当前生产已改为** 空闲6Hz/活动12Hz，阈值6，亮度22，EMA0.18，lerp0.35；OpenRGB 改为官方系统服务，便携包已删除

### 阶段 6：交付
- **状态：** complete
- 执行：`README.md` 增 `RGB Ambient` 章节与仓库结构，`tools/rgb/README.md` 全量，`run-tests` 全绿
- 产物：`tools/rgb/*`, `README.md`

## 测试结果（新增）

| 测试 | 输入 | 预期 | 实际 | 状态 |
|------|------|------|------|------|
| Hi75 list | `hi75.py --list` | 8 HID, 3 FF00 | 8/3 命中 Col06 | pass |
| Hi75 preset | `hi75 --preset red/green` | 3×520 | 3×520 Col06 | pass |
| Hi75 任意色 | `hi75 --color 0000ff` | patch 5 triple | 29:0000ff, ret520 | pass |
| bench | `ambient --bench 20` | <10ms | 4.75ms 210fps | pass |
| dry-run | `ambient --dry-run 12Hz 2s` | 24帧 | 24帧 收敛 | pass |
| 全联动 | `ambient --time 3 12Hz` | 推>0 | 34帧14推 | pass |
| 长稳30s | `ambient 12Hz 30s psutil` | CPU<2% MEMΔ<5 | 0.97% 0.0 | pass |
| 句柄泄漏 | 长稳后 `hi75 --preset` | 仍520 | 仍520 | pass |

## 错误日志（新增）

| 时间 | 错误 | 解决 |
|------|------|------|
| 2026-08-25 | `mss` 全屏39ms | 中心320x180采样 4.6ms |
| 2026-08-25 | `dxcam.create` hang | 默认 `mss`，dxcam 仅备选 |
| 2026-08-25 | `hid Col05` SetFeature -1/0x01 | 切 `Col06` 520成功 |
| 2026-08-25 | `openrgb` pip Temp 无权限 | 手动解压 wheel 到 `tools/rgb/lib` |
| 2026-08-25 | `FEAT0` 511≠520 | 重导 pcap bin 520 |

## 会话：2026-08-26 仓库边界与文档对齐

### 阶段：gitignore / 测试 / 文档 / pyright / 日志
- **状态：** complete
- 执行：
  - 根 `.gitignore` 允许模块 README 与 findings/progress/task_plan 入库；忽略 `.tmp/`、`.pip_manual/`、RGB 便携包、运行日志、`*.bak`
  - `pyrightconfig.json` 纳入 `tools/rgb`，排除 vendor / build / dist / hi75_data
  - `ahk/tests/run-tests.ps1` 增加 RGB 与 Theme 安装/启停脚本 AST 解析（不执行安装）
  - README / RGB README / DSH README 对齐当前生产配置；Navicat 标明仅限合法授权测试环境
  - `Watch-DshRemote.ps1` 日志超过 5 MB 轮转为 `watcher.log.1`
  - 取消跟踪 `audio-switcher.exe.bak`；`.tmp/` 与 `.pip_manual/` 为本地临时目录，不入库

## 会话：2026-08-26 优化收尾与安全回归

### 阶段：测试与报告
- **状态：** complete
- 执行：
  - 修复 `run-tests.ahk` 超时断言嵌套引号；补 DSH 60s 对账 / 日志降噪契约
  - `powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1` 全绿（15 AHK 独立加载 + 29 PS AST + core assertions）
  - `basedpyright tools/rgb|tts|translate` 均为 0 errors
  - 翻译自测 + 联网：`hello` → `你好`（en-zh），`你好世界` → `Hello World`（zh-en）
  - RGB 安全：`--dry-run --time 3` 36 帧 / `--bench 20` 4.96ms 201fps；OpenRGB 服务 Running；`hi75.exe` 仍在
  - Audio：`--help` 正常；`--get` 返回 `NO_DEFAULT`；`--list` 本次无设备行；`--ensure-headset` 超时后未再跑
  - DSH：`Get-DshRemoteStatus.ps1` 只读，DSH 未运行、Serve OFF、Watcher 任务存在
  - Theme / RGB-Ambient / DSH-Remote-Watcher 任务存在；未执行安装、卸载、切主题、写灯
- 未执行：Install/Uninstall、OpenRGB 停服务、真实 HID 写灯、TTS 播放、截图/录屏、Navicat 重置、`--toggle`

## 会话：2026-08-26 剩余风险修复

### 阶段：编译 / 重载 Watcher / 安全回归
- **状态：** complete
- **开始时间：** 2026-08-26 12:15
- **结束时间：** 2026-08-26 12:25
- 执行：
  - Framework `csc.exe` 重编译 `tools/audio-switcher/audio-switcher.exe`：`36864` → `36352`，时间 `2026-08-26 12:17:10`
  - 仅对 `DSH-Remote-Watcher` 执行 `/End` + `/Run`：旧 PID `9484` 结束，新 PID `28588` 于 `12:17:29` 启动
  - 新 Watcher 注册 4 个 WMI 事件；`12:17:31` 之后不再写 `Reconcile (periodic 60s)`（观察到 `12:24:41` 仍安静）
  - 新增 `Restart-Watcher.ps1`；`Get-DshWatcherTaskInfo` 优先 `Get-ScheduledTask`，避免 `schtasks` 中文 OEM 乱码
  - `Get-DshRemoteStatus.ps1` 现显示 `Running (event-driven, last 2026-08-26 12:17:29)`
  - `run-tests.ps1` 全绿：15 AHK 独立加载 + 30 PS AST + `PASS: core assertions`
  - `basedpyright tools/rgb|tts|translate` 均为 0 errors；翻译自测通过；`git diff --check` 无空白错误
  - Audio 只读：`--help` / `--debug-dump` 正常；`--list` 空、`--get` 为 `NO_DEFAULT`（当前 WASAPI `all=0`）
  - OpenRGB 服务 Running；`tools/rgb/dist/hi75/hi75.exe` 仍在
  - 本会话 `ambient.py --dry-run/--bench` 因 `mss BitBlt` 失败，判定为当前会话无可用桌面抓屏，不是服务/产物缺失
- 未执行：`--toggle`、`--ensure-headset`、TTS 播放、真实写灯、切主题、截图/录屏、Navicat 重置、DSH Start/Stop、任务卸载

## 会话：2026-08-26 P0/P1 收尾

### 阶段：Audio/TTS/RGB/DSH 查询复用与文档对齐
- **状态：** complete
- **开始时间：** 2026-08-26
- **结束时间：** 2026-08-26 16:12
- 执行：
  - Audio：`auto_elevate` 默认 false；仅明确权限错误才 sudo；提权重试共用 18s 预算
  - TTS：唯一临时输入文件 + PID 监视清理；`--self-test` 不合成不播放
  - RGB：`--bench` 改为合成帧；`--bench-capture` 才真实抓屏
  - DSH：`Get-DshPortInfo` 一次探测；`Test-TailscaleServeOn -ServeStatus` 复用；`Restart-Watcher` 轮询 Running；启动日志带 PID；node 事件读不到 CommandLine 时忽略
  - 文档：README / RGB README / findings / task_plan 6.4 与当前生产对齐
  - `tools/dsh-remote/README.md` 命令已确认无多余反斜杠
  - Serve apply 后的二次检查必须重新 `Get-TailscaleServeStatus`（状态已变），不是同一轮重复扫描
- 本轮回归：
  - `powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1`：15 AHK 独立加载 + 30 PS AST + `PASS: core assertions`
  - `basedpyright tools/rgb` 先报 3 errors，已修：`--bench` 合成路径改 `bench_ema`；主循环 `np.clip(NDArray)` 改为 `ndarray.clip`
  - `basedpyright tools/rgb|tts|translate` 均为 0 errors
  - `python -m py_compile tools/tts/tts_player.py` / `tools/translate/translate.py` 通过
  - `python .\tools\translate\translate.py --self-test` → `PASS: translate self-test`
  - `python .\tools\tts\tts_player.py --self-test` → `PASS: tts self-test`（夹紧 warning 属预期）
  - `python .\tools\rgb\ambient.py --bench 20` → `bench-synthetic ... (no capture, no OpenRGB, no HID)`
  - `python .\tools\rgb\ambient.py --bench 20 --bench-capture` → 当前会话 mss 成功：`20 frames / 212.5 fps`（此前 BitBlt 失败是环境限制，不是硬件损坏）
  - `git diff --check` 无空白错误（仅 CRLF warning）
  - `tools\rgb\dist\hi75\hi75.exe` 仍在；`audio-switcher.exe.bak` 仍不存在
- 未执行：`--toggle`、`--ensure-headset`、TTS 播放、真实写灯、Serve/relay 启停、任务删除/重建、git commit
- 工作区仍有大量未提交修改，不能声称干净或已提交

## 会话：2026-08-26 共享 include 与契约收口

### 阶段：python.ahk 统一加载 / PID 契约 / 按需快照
- **状态：** complete
- **开始时间：** 2026-08-26
- 执行：
  - `ahk/main.ahk` 统一 `#Include shared/python.ahk`；`speak-selected-text.ahk` / `translate-selected-text.ahk` 移除重复 include
  - 独立 feature 测试 stub 始终注入 `python.ahk`（朗读/翻译依赖 `ToolboxPython`；漏注入会弹 AHK 错误框并把 runner 卡死）
  - `ProcessNoWindow.Run()` 非等待返回真实 PID；`WatchPid` 在进程仍在时保留临时文件、退出后删除（不启动 TTS、不播放）
  - `Get-DshProcessSnapshot` 用局部变量，空结果保持真正空数组；`Start-DshRemote.ps1` 不提前扫进程，`.store.dat` 命中时跳过快照
  - `Restart-Watcher.ps1` 仍只 `/End` + `/Run`，未确认 Running 时打印实际状态
- 未执行：`--toggle`、`--ensure-headset`、TTS 播放、真实写灯、Serve/relay 启停、任务删除/重建、git commit

## 会话：2026-08-26 runner 5.1 解析与最终验证

### 阶段：CRLF runner / 契约全绿 / 安全回归
- **状态：** complete
- **开始时间：** 2026-08-26
- **结束时间：** 2026-08-26 17:10
- 执行：
  - Windows PowerShell 5.1 解析 `run-tests.ps1` 失败的根因是 LF 源文件 + here-string 内行首 AHK 指令；已改成 CRLF 重写 runner
  - stub 仍用 here-string 生成，但源文件是 CRLF；始终注入 `python.ahk`，并带 `#SingleInstance Off` / `#NoTrayIcon`
  - `powershell.exe -NoProfile -File .\ahk\tests\_parse-check.ps1` → `PARSE OK 5.1`（检查后已删除该临时脚本）
  - `powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1` 全绿
- 本轮实测：
  - AHK 独立加载：16/16 PASS（14 feature + `run-nowindow.ahk` + `python.ahk`）
  - PowerShell AST：30/30 PASS
  - core assertions：`PASS: core assertions`
  - `basedpyright tools/rgb tools/tts tools/translate`：0 errors, 0 warnings, 0 notes
  - `python -m py_compile tools/tts/tts_player.py` / `tools/translate/translate.py`：通过
  - `python .\tools\translate\translate.py --self-test` → `PASS: translate self-test`
  - `python .\tools\tts\tts_player.py --self-test` → `PASS: tts self-test`（夹紧 warning 属预期，未合成、未播放）
  - `python .\tools\rgb\ambient.py --bench 20` → `bench-synthetic process_frame 20 frames (20 emitted) in 0.011s = 1755.1 fps, 0.57 ms/frame (no capture, no OpenRGB, no HID)`
  - `git diff --check`：无空白错误（仅工作区 LF/CRLF warning）
  - `Test-Path .\tools\rgb\dist\hi75\hi75.exe` → True
  - `Test-Path .\tools\audio-switcher\audio-switcher.exe.bak` → False
- TEMP 里仍有 2026-08-19 / 2026-08-21 的旧 `lat3ncy-toolbox-feature-*.ahk` 各 1 个；本轮 runner 未残留新 stub
- 未执行：`--toggle`、`--ensure-headset`、真实 TTS 播放、真实 HID 写灯、OpenRGB 停/启、Serve/relay 启停、DSH Start/Stop、计划任务安装/卸载/删除/重建、主题切换、截图/录屏、Navicat 重置、git commit
- 工作区仍有大量未提交修改，不能声称干净或已提交

---
*每个阶段完成后或遇到错误时更新此文件*

## 会话：2026-11-20 真实验收与 TTS 依赖闭合

- 按用户“开始/继续”执行真机可自动部分、干净 clone 与模块提交整理；本地语音失败后在线回退获用户明确授权。
- 新增 clean_checkout.py，导出当前候选但使用 HEAD 配置，在独立本地仓库提交快照后 clone 到带空格目录。原仓库 Git 状态不变，旧产物/venv/日志不带入。离线、助手构建、WinUI 源码构建与 AHK 全量套件通过。
- 捕获并修复：旧核心测试错误要求生产 out 存在；Python 启动 PS5.1 时应隔离 PS7 模块路径并使用规范化的环境变量名。
- 真实 RapidOCR 文字及空白图片通过；真实 Edge 7.2.8 403，7.3.1 MP3 合成通过。建立独立 .venv 和带哈希的完整依赖锁；AHK 优先该环境，安装器 --check 不再依赖全局包。
- 进程令牌对照确认 venv 是 low/4096、全局解释器是 medium/8192；同一 SAPI 探针分别失败/成功，低完整性 TEMP 写入被拒绝。非 AppContainer，非 restricted token，均 STA/FullLanguage。保留本地 SAPI 失败事实，未改 ACL/注册表或提权。
- TTS auto 从本地失败恢复到独立 MP3 缓存，中英文真实文件可解码；显式 winrt 无在线请求。缓存写入探针失败回退模块 .cache；MCI/SAPI/顶层失败不再伪报成功。
- 独立 Build-ImeHud.ps1 及 CI WinUI job 已补，构建逻辑与主套件共用 BuildSupport；validation 来源/排除/原 Git 状态保护纳入离线和全量回归。
- 新证据位于 .tmp/integration/20261120-* 与 .tmp/validation/20261120-release-candidate/。音频未播放，剪贴板/电源/设备状态未改；总体 TTS smoke 仍为 partial。
- 随后按模块在 codex/reliability-baseline-20261120 创建 6 个本地提交（电源/启动、AHK通知、Python、桌面助手、构建/测试、文档）；四份个人配置内容哈希不变且未提交。远端结果以对应分支的 Actions 为准。
- `icacls` 确认仓库有可继承 Low 标签，venv 解释器继承 Low、全局解释器无 Low；这解释了实际子进程完整性差异。保持 ACL 不变，并记录 Microsoft MIC 机制。

## 会话：2026-11-20 TTS 生命周期、反馈与预算

- AHK 从只持有 PID 改为持有 Windows Job 任务；绑定失败时挂起进程不会恢复。取消整组进程并回收句柄，独立请求目录与残片按 nonce 清理；正常退出有清理回调，强制退出遗留以 owner PID/FILETIME 核验后回收。
- 新增原子终态协议，AHK 读取退出码、严格验证当前请求与 generation，显示安全的失败类别，取消不通知，旧结果不清除新任务。
- 每片合成 30 秒及两层总预算落地；超时取消待完成的合成、关闭请求并清理下载临时文件。
- Python 行为测试新增终态/缺输入/取消/超时清理；AHK 用真实隔离父子进程验证取消、硬预算、句柄、文件归属、PID 复用与正常退出。测试日志隔离到临时目录。
- 在线真实合成与主编排终态通过（播放边界用解码器）；可选 MCI 静音 WAV 正常播放/播放中终止通过。没有朗读用户文本、调整音量、操作剪贴板或设备连接。
- 本机全量与干净 clone 套件通过：73 项 Python 行为测试、64 项 PowerShell AST/BOM 检查及 AHK 断言；新增实际模块解释器在必需 Job 中返回缺输入错误，覆盖终态文件交付与清理。干净 clone 同时完成助手与 WinUI 源码构建，证据在 `.tmp/validation/20261120-tts-managed-release/`。
- 正式 ForceReload 完成：AHK 53000、HUD 35032、光标助手 47548；HUD PING、实例及助手归属检查通过。此次 HUD 产物无字节变化，仅重载当前仓库实例；部署证据 `.tmp/integration/20261120-tts-lifecycle-deploy.json`。
- 旧编码归一化辅助脚本曾尝试写被占用配置，已停用；核对四份配置哈希与保护基线一致，后续只处理本次修改文件的编码。

## 会话：2026-11-19 二次评审修复部署与下一步分析

- 用户授权替换并重载后，检查 test-out 源码戳及 self-test，备份生产差异文件后替换 `.source-stamp` / `ImeHudWinUi.dll` / `resources.pri`。
- AHK 40516 → 28080；WinUI 31344 → 5168；PowerPolicy 13340 → 44404。只针对当前仓库实例操作，PowerPolicy 通过 stop 文件正常退出后由原有提权任务重新启动，没有重装任务。
- 生产 WinUI self-test 和 PING 通过，DLL 与 test-out SHA-256 一致；AHK 实例标记存在，光标助手仅一个且属于 PID 28080；电源心跳有效、四路注册错误码 0、Caffeine 请求余额 1。
- RGB Ambient 当时未运行，因此未额外启动；OCR/TTS 为按需进程，后续调用读取新源码。
- 部署备份和机器可读证据：`.tmp/deploy-review-20261119/`；源码戳 `f11e37c285750855545c1b8200d82147711c55dae3ece036afd768f7a2d2388b`。
- 巡检发现：普通权限看护无法读取提权 PowerPolicy 命令行，健康业务实例仍被报 query-failed；列为下一阶段首项，计划用带仓库身份及进程创建时间的心跳识别。
- 更新 task_plan.md 最新阶段，规划发布回滚、稳定引擎定位、真机矩阵、提交基线与依赖/协议维护。仅形成计划，未开始新一轮实现，未 git commit。

## 会话：2026-11-19 执行下一步

- 执行前保存 402 个文件的内容/哈希基线；保留此前混合修改和个人配置，未 stage/commit/push。
- 新增 PowerPolicy 身份心跳及启动时源码/配置指纹；看门狗验证路径、PID 创建 FILETIME、新鲜度，区分 running/outdated/not-running/query-failed。新增隔离边界测试并纳入正式入口。
- 最终 PS7 交叉检查捕获 ConvertFrom-Json 自动日期转换导致的时区丢失：改为分别处理 string/DateTime/DateTimeOffset，补 UTC/本地/实际 JSON 日期回归，PS5.1 与 PS7 均通过；CI 增加 PS7 对应步骤。
- 将任务宿主迁移到系统 Windows PowerShell 5.1。普通终端修改 Highest 任务被 Windows 拒绝后，由原有提权常驻启动检查修复本仓库 action；没有提权看门狗或改变任务 principal/settings/triggers。实际新实例已从系统路径启动。
- 固化 HUD 发布事务、manifest、SHA-256 备份、预览、幂等、精确停止、原子替换、自检、AHK/HUD/光标助手健康检查、失败恢复及显式回滚；源码回退不在产物回滚范围。部署互斥体阻止看门狗在维护期间重拉，崩溃后自动释放。
- 真实 ForceReload：AHK 28080 → 16800，HUD 5168 → 49024，助手 33392；PING 与归属检查通过。连续两次普通部署 unchanged 且 PID 不变。
- PowerPolicy 受控正常停止后，看门狗确认缺失并恢复到 PID 21376；普通权限健康轮询两次不追加日志，原生注册四路错误 0，Caffeine=true、requestBalance=1。未强杀提权进程或发送合盖/睡眠命令。
- 新增本机已验证的离线 Windows runner/Actions workflow（55 个 Python 行为测试、PowerShell AST/BOM 和电源/启动/发布桩）；完整正式套件也通过。未推送，远端 Actions 尚未运行。
- `tools/startup/README.md` 补齐发布说明、待执行设备矩阵、模块提交边界。阶段 1/当前发布范围阶段 2 完成；阶段 3 待真实设备，阶段 4 提交/远端 CI 待办，阶段 5 不做无依据升级。证据位于 `.tmp/next-step-20261119/`。

## 会话：2026-11-19 继续执行发布边界与构建追溯

- 保存本轮涉及的 11 个既有文件基线。隔离复现准备备份后发生的目标更新被候选覆盖，修复部署前/停进程后/逐文件写入前的哈希预检。
- 自动恢复改为仅检查并恢复本次写入列表，遇到后续写入/删除报告冲突并保留现场；增加真实文件变更与故障注入测试，明确不承诺任意外部写入下的原子 CAS。manifest 改用原子替换。
- 新增 `tools/build/` 隔离编译与来源验证：两个 C# 助手实际编译，锚点 self-test 和来源核对通过；生成编译器/引用/源码/产物哈希 manifest。未覆盖生产 exe。来源故障桩加入两种测试入口，Windows Actions 增加实际编译步骤。
- 真实只读音频检查：生产/候选 --get/--list 一致，1 个活动设备，默认输出前后均 Realtek 扬声器；没有运行任何切换、恢复或建链命令。
- 全量与离线回归通过，64 个 PowerShell AST/BOM 检查、55 个 Python 行为测试，以及新增部署和来源故障测试通过。既有未提交修改/个人配置保留，未 stage/commit/push，远端 CI 尚未运行。
- 构建日志、只读音频 JSON、复现和测试日志在 `.tmp/continue-20261119/`。操作说明分别为 `tools/build/README.md`、`tools/startup/README.md`；真实设备矩阵仅增加已实测的只读部分。
