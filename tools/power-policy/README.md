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
- **`LenovoSmartStandby` 服务停掉会让 Lenovo 日志断流**。2026-11-05 起盖子状态改读 `Kernel-Power 506/507` 的 `LidOpenState`（OS 自己的记录），不再依赖该日志；Lenovo 日志只作兜底。
- **不要频繁重启该服务**。Lenovo 每次从睡眠恢复都会改回 `HIBERNATEIDLE`；旧逻辑每次都 `Restart-Service -Force` 纠正，一天七次后服务再也起不来。现在只有注册表参数真变时才重启，纯数值漂移用 `powercfg` 覆盖。
- **`IsEnabled=0` 不是「关闭 Smart Standby」**。它只让服务不执行动作，实测它**每天仍改写 `HIBERNATEIDLE(AC)` 4–13 次**。真正阻断只能让服务不运行，见下节。
## 2026-11-05：为什么最终把 LenovoSmartStandby 服务禁用了

### 现象

10-27 ~ 11-05 共 13 次 S4，全部是 `Kernel-Power 42 Reason=6`（固定超时）。其中 11 次在电池上、累计睡眠正好 ≈60 分钟（**符合设定**）；**但 2 次发生在插电状态**（累计 34 分钟 / 45 分钟），违反「插电永不 S4」。

### 结论：它不是应用，是驱动；且没有任何参数能关掉它

- 服务映像是 `DriverStore\...\smartstandbycomponent.inf_amd64_*\SmartStandby.exe`，来自驱动包 `oem114.inf`（Class=System，WHQL 签名）。**卸载 Lenovo Vantage 不会移除它**。
- 二进制字符串扫描：`SmartStandby.exe` 含全部四个配置值名；`Program Files\Lenovo` 与 `WindowsApps` 命中 **0** —— Vantage 只是 UI（RPC 客户端）。
- 三次参数实验（`Daytime` / `Overtime` / `PromoteHibernateLength` 各种组合）**都仍会写 AC=有限值**。11-02 的日志暴露了规律：它按「活跃时段结束 23:30」算剩余分钟并倒计时（35 → 34）。
- 所以**注册表层面没有开关**，只能让它不运行。

### 采用方案

```powershell
sc config LenovoSmartStandby start= disabled
sc stop  LenovoSmartStandby
```

本机 `FailureActions` 未配置，不需要额外清「自动恢复」。回退：

```powershell
sc config LenovoSmartStandby start= auto
sc start  LenovoSmartStandby
```

`Uninstall-PowerPolicy.ps1` 也会把启动类型恢复为 Automatic。

### 配套代码改动

1. 盖子状态改读 `Kernel-Power 506/507` 的 `LidOpenState`（OS 自己的记录，不依赖厂商服务），Lenovo 日志降为兜底。带 6 秒缓存，避免每轮重复解析 XML。
2. 服务为 `Disabled` 时不再尝试启动/重启它，只维护 `powercfg` 数值。

### 已知局限

`LIDACTION=0`（Caffeine 开着、合盖不睡）时合盖**不产生** 506/507，最后一次快照可能仍是「打开」。只影响日志文案，**不影响行为**——睡眠决策只由 Caffeine 决定，与盖子状态无关。

### 参考

- GitHub `brevstgaard/-Kill--the-Lenovo-SmartStandby-and-User-Presence-Sensing-feature`：同样用 `sc config` + `sc stop`
- GitHub gist（T14 Gen 3 实测）：额外提醒清 `sc failure ... actions=none`（本机本来就没有配置，无需处理）
## 2026-11-11（二）：路线 A 定稿 —— 合盖会锁屏，但系统不睡

### 最终形态

`LIDACTION` **恒为 1**（睡眠），不再随 Caffeine 在 0/1 之间切换：

| Caffeine | 合盖后 |
| --- | --- |
| 开 | Windows 关屏 + 锁屏 + 尝试进 S0；本工具持有 Power Request → 系统**留在工作状态**，不睡 |
| 关 | Windows 关屏 + 锁屏 + 进 S0 → DC 满 60 分钟按 `HIBERNATEIDLE` 转 S4 |

开盖需要重新验证登录（Windows 在合盖时就锁了会话）。**这是 `LIDACTION=1` 的固有行为，已确认可接受。**

### 为什么不是 LIDACTION=0

`LIDACTION=0` 是「什么都不做」：

1. 合盖后屏幕**不关**；
2. 合盖**不产生** `Kernel-Power 506/507`，本工具的盖子检测会永久停在旧值。

曾经为此尝试过用 AHK 监听 `GUID_LIDSWITCH_STATE_CHANGE` 广播来补救，但实测 **AHK 的隐藏窗口收不到 `WM_POWERBROADCAST`**（`RegisterPowerSettingNotification` 返回了有效句柄，60 秒内 0 次回调），该方案已放弃并删除 `shared/notify/lid-broadcast.ahk`。

### Power Request 的实测边界

升级到 `PowerCreateRequest/PowerSetRequest` 后，请求会以原因字符串
`Lat3ncy PowerPolicy: Caffeine keep-awake` 出现在 `powercfg /requests` 的 SYSTEM 段，
从此「有没有生效」可以直接验证。

**已经有量化的对照数据：**

| 合盖时刻 | Caffeine 开启时长 | SleepEntered | 实际睡眠 |
| --- | --- | --- | --- |
| 21:47:08 | **4 秒** | `true` | **167 秒** ❌ |
| 21:55:40 | 8 分钟 | `false` | **0 秒** ✅ |

结论：请求本身有效，但**刚建立时存在生效延迟**。开关 Caffeine 之后立刻合盖（几秒内）
仍可能被睡眠指令抢在前面。正常使用不会触发，暂不额外处理。

### 仍然存在的限制

`PolicyChange` 级别的会话切换（例如 11-11 12:22 那次由 `AnalyzeSystem`
触发的连续会话重建）有可能绕过 Power Request。该任务已禁用：

```powershell
schtasks /Change /TN "\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem" /DISABLE
# 回滚
schtasks /Change /TN "\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem" /ENABLE
```

### 不做的两件事

- **不自己发 `SC_MONITORPOWER`**：关屏交给 Windows（`LIDACTION=1`），
  `Set-DisplayOff` / `Set-DisplayOn` 已删除，避开 10-23 那个「类型编译副作用关屏」的坑。
- **不设 `CONSOLELOCK=0`**：那是「从睡眠唤醒不要求密码」，而现在的锁屏是
  合盖动作直接触发的，改它对本次场景无效。
