# power-policy

合盖 / 空闲时的睡眠与休眠策略，带 Caffeine（Raycast Coffee 扩展）感知。

Windows 的「合上盖子操作」是静态设置，无法表达「Caffeine 开着就别睡」。本工具每 5 秒读一次 Caffeine 状态，动态改写 `LIDACTION`，把「合盖该不该睡」交回 Windows 原生逻辑处理。

## 行为

| 场景 | 行为 |
| --- | --- |
| 插电 + 合盖，Caffeine 关 | 立刻进 S0 睡眠；**永不**转 S4，开盖瞬亮 |
| 电池 + 合盖，Caffeine 关 | 立刻进 S0 睡眠；60 分钟后转 S4（开盖需等固件 POST） |
| 合盖，Caffeine 开 | **不睡**，保持运行 |
| 插电 + 不合盖 | 10 分钟关屏，**永不**因空闲睡眠 |
| 电池 + 不合盖 | 10 分钟关屏，30 分钟后睡眠 |

术语沿用本机约定：**睡眠 = S4**（恢复见 BIOS logo），**休眠 = S0**（开盖即亮）。上表按实际电源状态描述，避免歧义。

## 为什么不是「让 Caffeine 直接挡住合盖」

Microsoft 文档对 `SetThreadExecutionState` 的说明很明确：

> It cannot prevent sleep caused by the user pressing the power button or closing the lid.

Caffeine（以及 PowerToys Awake 等）用的都是这个 API，**只能挡空闲超时，挡不住合盖**。所以必须改电源设置——也就是 `LIDACTION`。

本机实测各「关屏原因」的真实入睡率（来自睡眠分析报告统计）：

| 关屏原因 | 入睡率 |
| --- | --- |
| Video Idle Timeout | 3% |
| SC_MONITORPOWER（脚本自己的关屏） | 32% |
| Lid（Windows 原生合盖） | **83%** |

因此本工具**不再自己关屏**，只维护 `LIDACTION`，让 Windows 走原生合盖路径。

## 安装

需要管理员（注册计划任务、写 HKLM 的 Lenovo 键、改电源设置）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\power-policy\Install-PowerPolicy.ps1
```

注册两个任务：

| 任务 | 触发 | 作用 |
| --- | --- | --- |
| `PowerPolicy` | 登录时 | 常驻循环（每 5 秒检查一次），靠看护任务兜底拉起 |
| `PowerPolicy-OnLidEvent` | 合盖 / 开盖 / 断电 | 一次即时检查，秒级响应 |

两个任务都以 `wscript.exe //B ..\startup\SilentRun.vbs "<cmd>"` 启动，不分配控制台。**看护只由 `Lat3ncyToolbox-Watchdog` 一个任务负责**，它同时看护 `ahk/main.ahk` 和本工具的常驻进程（见 `tools/startup/Ensure-ToolboxRunning.ps1`）。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\power-policy\Uninstall-PowerPolicy.ps1
```

会移除任务、清掉关屏/睡眠标记，并把 Lenovo Smart Standby 恢复为自主管理。

## 配置

改 `config.toml` 后**必须重新运行 `Install-PowerPolicy.ps1`**：安装脚本把解析后的数值烘焙进任务参数，运行期不读配置文件。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `power.ac_standby_seconds` | 0 | 插电空闲睡眠（0 = 永不） |
| `power.dc_standby_seconds` | 1800 | 电池空闲睡眠 30 分钟 |
| `power.ac_hibernate_seconds` | 0 | 插电转 S4（0 = 永不） |
| `power.dc_hibernate_seconds` | 3600 | 电池 60 分钟后转 S4 |
| `power.ac/dc_video_idle_seconds` | 600 | 空闲关屏 10 分钟 |
| `caffeine.coffee_dir` | `%LOCALAPPDATA%\coffee` | Coffee 扩展状态目录 |

## Caffeine 判定

Raycast 的 Coffee 扩展在 worker 启动时写 `state.json`（含 `pid`），停止时删除。本工具校验「文件存在 + 该 pid 仍存活」，防 PID 复用误判。

注意这只认 Raycast 的 Coffee 扩展。换用 PowerToys Awake 或独立版 Caffeine **不会被识别**。

## 日志

```
%LOCALAPPDATA%\lat3ncy-toolbox\power-policy.log
```

写入策略：

- **状态行节流**：只在「盖子 / 供电 / Caffeine / LIDACTION」任一变化时写一行，另外每 30 分钟打一行心跳。5 秒轮询不会刷屏（迁移前的旧实现每轮都写，日志涨到 19 MB）。
- **轮转**：每 200 次写入检查一次，超过 3000 行只保留最后 2000 行。
- `[LIDACTION] 已切换为 ...` 只在真正的切换瞬间出现一次。

## 已知坑（都实际踩过）

- **`SetSuspendState(force=TRUE)` 在本机会被固件回落成 S4**。本机只有 S0/S4，没有 S3；强制挂起等于休眠，开盖必见 BIOS logo。所以本工具**不调用任何睡眠 API**。
- **类型编译不能带副作用**。曾把「未编译就调 `Set-DisplayOff`」当编译触发器，注释写着「副作用为一次关屏，可接受」。事件任务每次合盖都是新进程，于是每次合盖都真的发了 `SC_MONITORPOWER`，把 Caffeine 开着的情况也睡掉。现在编译与动作彻底分离。
- **`LenovoSmartStandby` 服务停掉会静默断掉盖子事件流**。本工具靠 `Lenovo-Power-SmartStandby/Operational` 日志判断盖子状态，服务一停，日志永久谎报「盖子=打开」。防漂移检查现在包含服务健康检查。
- **不要频繁重启该服务**。Lenovo 每次从睡眠恢复都会改回 `HIBERNATEIDLE`；旧逻辑每次都 `Restart-Service -Force` 纠正，一天七次后服务再也起不来。现在只有注册表参数真变时才重启，纯数值漂移用 `powercfg` 覆盖。
- **`IsEnabled=0` 不是「关闭 Smart Standby」，而是「拆掉自己的数据源」**。关掉后 Lenovo 不再记录 Lid 事件，本工具失去盖子感知。正确做法是 `IsEnabled=1` + `IsAutonomic=0`。
