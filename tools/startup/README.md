# 启动、看护与部署

`Start-Toolbox.ps1` 解析 AHK v2 引擎并启动本仓库的 `ahk/main.ahk`。`Ensure-ToolboxRunning.ps1` 是登录及每 5 分钟运行的看门狗：只在确认缺失时拉起，不杀健康进程。

## PowerPolicy 身份

提权进程的命令行可能对普通看门狗不可见。状态文件因此携带脚本绝对路径、仓库路径、PID、进程创建 FILETIME、启动时源码/配置 SHA-256 指纹。看门狗交叉验证这些字段和活进程创建时间，再使用心跳；未通过时回退 CIM，不把查询失败当成进程缺失。

心跳有效窗口为 60 秒，未来偏差最多 5 秒。状态含义：

时间读取兼容 Windows PowerShell 5.1 的 JSON 字符串与 PowerShell 7 自动转换的 DateTime，保留时区；CI 同时运行这两种宿主的身份测试。

| 状态 | 行为 |
| --- | --- |
| `running` | 当前源码/配置的健康实例，保持安静 |
| `outdated` | 旧源码/配置仍在运行，记录需重载，保持原进程 |
| `not-running` | 确认缺失，启动原计划任务 |
| `query-failed` | 证据不足，记录诊断，避免重复拉起 |

指纹在常驻启动时捕获，运行中修改配置不会让旧进程冒充新版。PID 复用、其他 checkout、损坏 JSON、过期心跳均有隔离回归测试。

## 发布 HUD 并重载 AHK

从仓库根目录运行：

```powershell
# 全套本机离线回归及 WinUI 源码构建
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ahk/tests/run-tests.ps1 -BuildImeHud
# 预览差异；执行部署；同版本不重复重启
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Deploy-Toolbox.ps1 -PlanOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Deploy-Toolbox.ps1
# 仅需重载 AHK 源码时
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Deploy-Toolbox.ps1 -ForceReload
# 使用某次发布输出的绝对 Release 路径回滚
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Deploy-Toolbox.ps1 -RollbackRelease 'C:\path\to\repo\.tmp\releases\release-id'
```

部署范围为 `tools/ime-hud-winui/test-out` 到 `out` 的产物差异，排除日志；不发布个人配置、Python 环境或其他二进制。源码戳与当前 C#/XAML 工程匹配、候选 self-test 通过才可继续。请先运行完整回归；源码戳不等于完整测试通过证明。

发布流程：哈希比较 → 备份/manifest → 精确停止当前仓库 AHK 与 HUD → 同目录原子替换 → 生产 self-test → AHK 启动 → 实例标记、HUD PING、唯一光标助手及 OwnerPid 检查。替换或健康检查失败时恢复旧文件并重启旧运行时；回滚前也备份当前字节。路径越界、重解析点、损坏备份、其他 checkout 的 HUD 窗口会被拒绝。

停进程前会重新核对候选、目标及备份哈希，停止后及逐文件替换前再次核对；目标发生变化或新文件出现碰撞时拒绝覆盖。自动失败恢复仅处理本次尝试写入的文件，并先检查其内容是否仍为本次产物；发现其他写入或删除则报告 `Automatic rollback conflict`，保留现场与备份，不继续覆盖。此时应审阅后选择显式回滚，显式回滚会恢复所选版本。manifest 更新使用同目录原子替换。

备份和 SHA-256 manifest 保存在忽略目录 `.tmp/releases/`，由用户按需保留。AHK 脚本直接从工作区加载，**回滚产物不会回退 AHK/Python/PowerPolicy 源文件或配置**；源码回退需另行审阅 Git 差异。失败恢复同样读取当前 AHK 源码。

部署与电源重载持有当前仓库专属的内核互斥体；看门狗暂缓巡检。部署进程崩溃后互斥体自动释放，不依赖可能遗留的维护文件。不要在发布期间手工启动同一仓库入口。

## 从源码重建 HUD 与锚点

Raycast 的 Reload IME HUD 现在调用统一入口；普通 Restart AutoHotkey 也遵守同一仓库发布锁。重建需要 .NET SDK 和 Windows .NET Framework 编译器，缺失或构建失败时保留当前运行实例。

```powershell
# 真正构建并运行合成 self-test，仅预览，不停止或替换当前实例
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Rebuild-ToolboxHud.ps1 -PlanOnly
# 构建、验证、备份、统一部署 HUD + anchor，重启并检查运行链路
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Rebuild-ToolboxHud.ps1
```

构建进入全新的 `.tmp/hud-rebuilds/<guid>/`，只选择 anchor 助手，不编译或发布音频助手。WinUI 输出也直接进入该候选目录，绝不向生产 `out` 执行 publish。构建前后核对源码指纹，记录每个候选产物的 SHA-256；self-test 产生的日志不会发布。Windows PowerShell 子进程使用自己的系统模块目录，避免继承 PowerShell 7 的不兼容模块路径。

完整候选验证后，复用 `Deployment.Core.ps1` 的备份、逐文件替换与失败恢复事务。候选在停止前和停止后再次校验；生产产物也需读回哈希并通过 self-test。AHK 进程持有创建身份已核对的句柄，HUD 退出消息只发给已验证的窗口所属 PID，最终确认实例标记、HUD PING 和光标助手归属。

发布范围严格限定 `shared/notify/anchor-locator.exe` 与 `tools/ime-hud-winui/out/` 内的产物。备份位于 `.tmp/releases/hud-<guid>/`，其 manifest 的路径相对仓库根；与旧的单独 HUD 发布备份范围不同，不能交给旧入口的 `-RollbackRelease`。替换或运行检查失败时，自动恢复本次写入且未被后续写入改变的文件并重启原运行链路；冲突时保留较新文件和备份，报告错误，需审阅现场。构建目录与备份均保留作证据，不自动清除。恢复产物不会回退工作区源码或个人配置。

故障回归在临时仓库中执行真实文件替换/备份/恢复，运行进程为桩；覆盖构建、候选/安装自检、部分写入、源文件漂移、后续写入冲突、发布锁、PID 变化与跨宿主模块路径。它们不代表曾在生产实例上制造故障。

## 重载 PowerPolicy

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/power-policy/Restart-PowerPolicy.ps1
```

该入口验证新鲜心跳、PID 创建时间及任务所属 checkout，以 stop 文件请求优雅退出，通过原任务拉起，然后验证新 PID、当前源码指纹和原生注册结果。它不会重装任务或自行提权。任务绑定系统 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`，与 Codex 安装版本无关。

## 自动化与真机验收

`ahk/tests/run-offline-tests.ps1` 是 Windows CI 子集：全部第一方 PowerShell AST/BOM、启动/心跳/发布回滚及主题入口桩，以及当前 134 个 Python 行为测试。Python 使用 `-S` 排除本机 site-packages；模型、网络服务和硬件均为桩。`.github/workflows/offline-windows.yml` 使用 Python 3.13、Windows PowerShell 5.1 执行它，并独立源码构建 WinUI；可靠性分支已有远端通过记录，最新结果以对应提交的 Actions 为准。

`run-tests.ps1` 额外验证真实 AHK 引擎、独立 feature 加载、WinUI 构建戳/self-test 与锚点 self-test。两种套件通过都不代表真实合盖、蓝牙和 UIA 场景已验收。

锚点/音频助手新增隔离编译与来源 manifest，操作见 `tools/build/README.md`。来源故障桩已加入两种套件；Windows CI 额外实际编译两种助手。此流程不替换已运行的生产二进制。

2026-11-19 本机证据：Windows `10.0.26300.0`；HUD/AHK 重载成功，同版本连续部署两次均 unchanged 且 PID 不变；电源受控停止后被普通权限看门狗恢复，随后两次巡检日志未增加。原生四路注册错误码均 0，Caffeine=true、requestBalance=1。证据保存在 `.tmp/next-step-20261119/`；这是正常停止后的缺失恢复测试，没有强杀提权进程或发送睡眠命令。

后续设备矩阵，待执行项必须记录环境、步骤、预期、实际结果和证据，不能用桩测试填为通过：

| 场景/步骤 | 预期 | 当前结果 |
| --- | --- | --- |
| Chromium、编辑控件、终端中选区翻译；逐一切换多屏/DPI | 锚点落在有效显示范围，原文/结果完整 | 待真机验证 |
| 5000+ 字符/emoji 译文，点击复制；关闭面板后等待迟到结果 | 剪贴板完整，面板不重开 | 7397 UTF-16 单元的真实协议复制、空结果保护与关闭后迟到结果通过；按钮点击待测 |
| OCR 成功、空白、取消、模型失败 | 正确交付，错误通知存在，runner 最终清理 | 2026-11-21 用户确认基础使用正常；模型、旧宿主剪贴板保护与通知 API 已通过。新宿主自动剪贴板保护探针、横幅和各异常路径保留原专项验收状态 |
| TTS 连续打断、下载失败、本地兜底 | 无残留音频/进程，后续请求正常 | 2026-11-21 用户确认朗读基础使用正常；真实 Caps+S 替换/最终 MCI 完成、进程文件清理及新宿主离线中英文 SAPI 通过。下载失败等专项场景仍单独验收 |
| Caffeine 开/关、到期、停止、解锁/恢复 | 请求与策略恢复一致 | 本机开启状态及重载通过，其余待测 |
| 插电/电池合盖、睡眠、供电切换 | 回调与预期策略一致，任务连续性有实测依据 | 待用户可观察窗口执行 |
| RGB SDK/HID 断连、重连、退出 | 超时有界，能重连，无忙循环 | 离线协议通过，设备待测 |
| AirPods 未取出、立体声恢复及超时 | 有界等待，默认端点正确，不禁用蓝牙服务 | 生产/新编译助手真实只读枚举一致、默认端点不变；建链/切换/超时待测 |

## 2026-11-19 提交整理记录（历史）

本轮开始前已保存 402 个文件的哈希/副本到 `.tmp/next-step-20261119/baseline*`，保护已有大量未提交修改。本轮未执行 stage/commit/push。建议按以下依赖顺序审阅提交，个人配置单独审核：

1. 电源/启动身份及稳定引擎：Identity、Core、任务安装/修复、看门狗与对应测试。
2. 发布事务及共享构建指纹：Deployment 三个文件、Deploy 入口、BuildSupport、测试入口与发布测试。
3. 通知/翻译、OCR/TTS、RGB 修复：分别审阅既有差异和行为回归；自编译 exe 必须与对应源码同批核对。
4. 自动化、评审记录和文档：离线 runner、Windows workflow、README 与进度记录。

`config.toml`、运行日志、备份、模型和本机凭证不随上述批次自动暂存。协议/依赖收口仍按模块推进，先收集真机失败证据，再确定升级与性能改动。

2026-11-20 增量：真实 OCR 合成图片/空白图片通过；TTS 中英文 auto 在线恢复、MP3 解码和实际缓存路径通过，低完整性本地 SAPI 失败保留为 partial。干净本地 clone（HEAD 配置、无旧产物）已通过离线、C# 编译、WinUI 构建及 AHK 全量回归。入口与证据范围见 `tools/validation/README.md`，不能将这些结果替代真实 UIA、剪贴板、播放或物理设备验收。

随后完成本地语音恢复：按仓库隔离的用户目录锁定环境为 medium/RID 8192；AHK 仅选择归属匹配且已就绪的宿主，否则保留旧环境回退。WinRT 不可用后先生成 SAPI WAV，失败才在线恢复。真实本地/在线文件和禁止在线的受管流水线通过；未修改 ACL、个人配置或全局 Python 包。证据见 `.tmp/integration/20261120-local-host/`。
