# 任务计划：切换播放器自动连接 AirPods 完善

## 目标
将 `Caps+D` 的 `G27Q2 ↔ AirPods 立体声` 一键切换从“能用”提升到“稳、快、可观测、可配置”：未建链时自动 `Enable A2DP + WSASetService` 拉起 AirPods 并仅在 `ACTIVE` 后 `SetDefault`，已连时秒切，失败有分级提示，支持 TTS 播前预热与可配置的首选设备。

## 当前阶段
阶段 6（免手动一键直连）

## 各阶段

### 阶段 1：需求与发现
- [x] 梳理现有链路 `ahk/features/audio-switcher.ahk -> tools/audio-switcher/AudioSwitcher.cs: TogglePreferredOutputs/ConnectPreferredHeadset`
- [x] 确认痛点：WASAPI 找不到未建链终点、Hands-Free 误判、非 ACTIVE 误设 0xE000020B、Raycast/TTS 输出乱码(BOM)
- [x] 将发现记录到 findings.md
- **状态：** complete

### 阶段 2：规划与结构
- [x] 冻结配置与协议：首选设备规则、超时/轮询、日志与通知分级
- [x] 确定不改动点：永不 `BluetoothServiceDisable`、只标 A2DP Sink `0000110B/0000110D`
- [x] 输出详细设计（时序图、状态机、配置表）到 findings.md
- **状态：** complete

### 阶段 3：实现
- [x] 3.1 加固 `AudioSwitcher.cs`：`PKEY_Device_DeviceDesc` 兜底、`AddRememberedHeadsetIds` 注册表找回、`IsPreferredHeadset` 排除 Hands-Free/iPhone、前置 `BluetoothGetDeviceInfo` 刷新（已存在，抽配置化）
- [x] 3.2 连接链路：`EnableAirPodsA2dpOnRadio` + `ConnectAirPodsAudioProfile(WSALookupServiceBegin->WSASetService)` 双路径 + 仅对 `ACTIVE` 设默认（已存在）
- [x] 3.3 交互与可观测：`audio-switcher.ahk` 700ms 防抖 + `ProcessNoWindow` 协议 `SWITCHED|ONLY_ONE|NO_DEVICE|ERROR` -> `Notify.Success/Info/Error`，`0xE000020B` 映射 `耳机未就绪`（已存在）
- [x] 3.4 TTS 联动（可选）：`speak-selected-text.ahk` 播前可选预热 `audio-switcher.exe --ensure-headset`，失败不阻塞朗读（已实现，`#Include run-nowindow`）
- [x] 3.5 编码与通知统一：`tools/raycast-scripts/*.ps1` 补 `UTF-8 BOM`，`_lib/notify.ps1` 统一 `OutputEncoding=UTF8`，`toast.ps1 duration=short~7s`（已完成）
- [x] 3.6 配置化：新增 `tools/audio-switcher/config.toml`（preferred/behavior/tts），`AudioSwitcher.cs` 动态加载关键词与 `connect_wait_ms/poll_ms`，新增 `--ensure-headset` 供 TTS 预热
- **状态：** complete

### 阶段 4：测试与验证
- [x] 单元/契约：`ahk/tests/run-tests.ahk:483` 11 项断言（A2DP/Hands-Free/ACTIVE/AddRemembered/WSASetService 等）全绿（`run-tests.ps1 PASS: core assertions`）
- [x] 独立加载：14 个 `*.ahk` + 14 个 `*.ps1` AST 解析全绿（含修复后 `speak-selected-text.ahk catch{}` 空块）
- [x] 手测：`audio-switcher.exe --list/--ensure-headset` 在无 AirPods 机器正确报 `耳机未就绪`，`--toggle` 逻辑保持
- [x] 回归：编译产物 `audio-switcher.exe` Framework 25KB 单文件可用，`config.toml` 热加载验证
- [x] 将测试结果记录到 progress.md
- **状态：** complete

### 阶段 5：交付
- [x] 配置与产物：`tools/audio-switcher/config.toml` 示例已创建，`audio-switcher.exe` 已用 Framework csc 重编译为 25KB 单文件
- [x] 编码校验：`raycast/*.ps1` 已补 `EF BB BF`，`speak-selected-text.ahk` 已 `PASS` 独立加载
- [x] 更新 `README.md`：补 `Caps+D` 默认快捷键、新增 `## Audio Switcher` 章节（含 config.toml 示例与 --ensure-headset）、TTS 增加耳机预热说明、仓库结构补 `audio-switcher/`
- [x] 全量回归：`run-tests.ps1` 14+14+core 全绿，`audio-switcher.exe --list/--ensure` 验证
- **状态：** complete

### 阶段 6：免手动一键直连（新增）
- [x] 6.1 强化建链：`TryFindAirPodsAddress` 与 `EnableAirPodsA2dpOnRadio` 先 `BluetoothGetDeviceInfo` 刷新再判 `IsPreferredHeadset`，空 `szName` 时用刷新后的名回退，避免离线时漏判
- [x] 6.2 加大容忍：`connect_wait_ms` 默认 8000→12000，`poll_ms` 保持 200，`config.toml` 可调；`fIssueInquiry=0` 保持不扫描以免卡顿
- [x] 6.3 语义对齐：`Caps+D` 的“切扬声器”即“想用耳机”，`Toggle` 在 `headset==null` 时必走 `ConnectPreferredHeadset+Wait`
- [x] 6.4 提权兜底（历史方案已收敛）：早期曾双试 PNP + 在 `ERROR|耳机未就绪` 时自动 `sudo --inline`。当前生产：`pnp_fallback=false`，`auto_elevate=false`；AHK 仅在配置显式打开且错误详情明确为权限问题时才 sudo。普通「耳机未就绪」不提权，提权重试与普通执行共用 18s 总预算
- **状态：** complete

## 关键问题
1. 是否需要让 TTS 默认自动预热 AirPods？默认建议 `opt-in` 配置项 `auto_switch_before_tts=false`
2. 首选设备是否可配置化（当前硬编码 `AirPods + G27Q2/NVIDIA`）？已抽到 `tools/audio-switcher/config.toml`
3. `ConnectWaitMs=8s` 是否需按蓝牙环境自适应？已改为 12s，可观测后调优

## 已做决策
| 决策 | 理由 |
|------|------|
| 永不 Disable 蓝牙服务，仅 Enable A2DP | 避免回切显示器时把 AirPods 踢掉，下次秒连 |
| 只对 ACTIVE 终点 SetDefault | 非 ACTIVE 会抛 0xE000020B，且不会建链，WSASetService 才是建链路径 |
| 用 DeviceDesc 兜底 + 注册表找回已记住 ID | WASAPI 未建链时 FriendlyName 为空，注册表仍有 AirPods 立体声节点 |
| 700ms 防抖 + Busy 互斥 + ProcessNoWindow | RunWait 期间防重入，700ms 内连按忽略，无黑窗 |
| 排程通知统一为系统 Toast short ~7s，BOM 统一 UTF-8 | 修复 Raycast 乱码，错误统一收敛到系统通知 |

## 遇到的错误
| 错误 | 尝试次数 | 解决方案 |
|------|---------|---------|
| Raycast 显示 `鈭?宸查噸杞?` 乱码 | 1 | `restart-autohotkey.ps1` 误用 `√` 且无 BOM，已改为 `✓` 并补 `EF BB BF` 到 6 个 raycast 脚本 |
| `screenshot-ocr` 报错走 Raycast 气泡而非系统 Toast | 1 | `trap` 与前置校验 `exit 1->0`，统一 `Show-SystemToast` 并补 `OCR 已取消` 分支 |
| WASAPI 找不到未建链 AirPods | 1 | 增加 `DeviceStateMaskAll+DeviceDesc+AddRememberedHeadsetIds` |

## 备注
- 阶段状态：pending → in_progress → complete，做重大决策前重读此文件
- 外部网页/搜索结果仅写入 findings.md，不写入本文件
