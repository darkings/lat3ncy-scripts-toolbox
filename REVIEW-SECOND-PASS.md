# 全仓二次代码评审（2026-11-19）

## 2026-11-21 合并前增量复核

在 PR #2 的完整差异、既有评审映射及实际调用链基础上，追加修复两项 P2：

| 编号 | 触发与影响 | 修复与验证 |
| --- | --- | --- |
| M01 | `Set-Theme-Dark.ps1` 开启通知且模式改变时，将 U+1F319 强转单个 .NET char，实际抛 InvalidCastIConvertible，通知无法送出 | 改为 `ConvertFromUtf32`。隔离复制真实明/暗入口、替换系统写入提供者，覆盖通知开关与变化/不变；修复前失败、修复后全部通过，不改变当前主题 |
| M02 | 内部诊断探针发现缺包/版本不匹配或低完整性时返回非零，父级 `run_json` 丢弃其 JSON，导致报告缺少依赖与完整性详情 | 内部探针完成 JSON 交付即退出 0，外层保留健康退出码语义。真实父子进程边界回归证明 `attention`、缺包和 `low` 详情保留；修复前为 `query-failed` |

同时补齐完整测试入口：OCR 改为发现全部 `test_*.py`，包含 5 项宿主测试；主题隔离入口同时加入离线与完整套件。合计 97 项 Python 测试，以及主题、启动/心跳、部署回滚、助手来源、WinUI/AHK 完整本机检查，通过含空格路径的干净候选 clone 三阶段验证。证据 `.tmp/validation/20261121-merge-fixes/report.json`。

三个已更新的助手隔离重编译后，核对方法体、字段与外部调用元数据。归一化编译生成 GUID 和音频助手原临时构建名称 `audio-switcher.new` 后，220 / 93 / 37 项成员比较未发现差异；这是所述元数据/方法体比较，不是 PE 字节一致或签名证明。未替换生产二进制或调用设备切换；本机比较记录 `.tmp/merge-review/binaries/il-comparison.json`。

用户基础使用验收保持通过；多屏和物理设备专项保留既有边界。没有发现其他需要在本次合并前修复的问题；剩余未测场景不据此标为通过。

评审以当时的工作区文件为准，包含未提交和未跟踪的一方源码，不限于 Git diff。先读取 `REVIEW.md`，再独立检查实现与调用链。随后按用户要求修复，原始发现保留在下方，修复与最新验证结果记录如下。

评审发现 **16 项 P2 问题**。其中 14 项有隔离运行证据，另外 2 项由调用顺序或数学条件直接确认。**目前 16 项均已修复，并纳入正式回归入口。**

## 修复状态与最新验证（2026-11-19）

| 发现 | 修复 | 回归证据 |
| --- | --- | --- |
| R01 | 增加 InputAnchor.Resolve 对象适配器，renderer 使用 found/坐标契约 | 实际 popup/state 渲染成功并关闭 |
| R02 | 光标纵向判断改为窗口边界加 2px 容差，保留过大矩形检查 | 重建 anchor-locator.exe；顶部、中央、底部及越界 self-test |
| R03 | 原文和译文保存完整 Unicode，剪贴板读取也不再截断 | 6001 UTF-16 单元、跨旧边界 emoji 和完整复制 self-test |
| R04 | 托盘检查完整 JSON、进程 FILETIME、有效期和 stop.flag，并读取相同 coffee_dir；移除无条件防睡眠承诺 | 实际 AHK 校验活跃、到期、PID 复用、停止、半写文件、自定义目录 |
| R05 | RTCWAKE 纳入逐计划备份、回滚和恢复；新增独立 disable_timers 配置 | 新旧备份迁移、原值恢复、配置关闭和 DryRun 隔离测试 |
| R06 | 恢复成功的条目才移除，失败条目持久化并抛错，允许卸载重试 | 部分成功、失败保留、重试成功及损坏存档保留 |
| R07 | 使用写前恢复日志；JSON 同目录原子替换，跨 PS 版本固定 UTF-8 BOM | 桩断言禁用前记录已存在；写档失败/损坏存档时零设备写入 |
| R08 | 唯一 runner 名，成功派发后转交子进程；子进程 finally 自删 | 异步文件保留、连续唯一、启动失败和同步清理 |
| R09 | 错误 result 写入独立捕获，不阻断 Toast | 双重故障仍通知并返回 1 |
| R10 | 网络 await 移入 finally 保护范围 | 部分写入后的网络异常和 CancelledError 都无残片 |
| R11 | 每个 helper 独立读线程和队列，消费者限时等待；RPC 超时回收失步进程 | 半行阻塞、READY/RPC/EOF、超时回收测试 |
| R12 | OpenRGB 头部/各类包体共用 recv_exact，空读断连，清理安全释放锁 | 分片读取、半个头部和六种包体 EOF；无 SDK/HID 连接 |
| R13 | 看护共用完整脚本路径匹配器，精确 -Run token，不可读保持 unknown | 外部路径、参数前缀、不同 PowerShell host 和不可读进程测试 |
| R14 | 重启匹配移除仓库名称子串兜底，共用精确匹配；先查询再停 HUD | 执行真实匹配函数，仅当前 checkout 进入进程名单 |
| R15 | helper 写低 32 位无符号计数，AHK 兼容旧有符号值并计算模差 | 有符号边界、32 位回绕、NOCARET 新鲜度及过期测试 |
| R16 | 自启明确引用命令行参数 | 含空格目录下真实 AHK 脚本执行并正确收到含空格参数 |

最新验证：

- `ahk/tests/run-tests.ps1 -BuildImeHud`：**退出码 0**；标准 `dotnet publish` 从源码生成 test-out，构建脚本正常写入源码戳，没有手工复用旧 PRI 或伪造源码戳。
- 最终 `ahk/tests/run-tests.ps1`：**退出码 0**。包含 AHK 核心与新增行为测试、WinUI/locator 自检、翻译 **33**、TTS **12**、OCR **4**、RGB **6** 条 unittest，另有启动隔离及电源恢复检查。
- AST/BOM 检查改为自动发现一方 PowerShell 文件，新增模块和测试不再依赖手写名单。
- 电源恢复测试在 Windows PowerShell 5.1 和 PowerShell 7 均通过；真实 PowerNative 自检也通过，未修改电源计划或发送关屏/睡眠命令。
- 保留原有未提交改动；新增评审报告白名单、正式回归文件与模块说明。修复阶段没有重启常驻进程；随后按用户要求完成下述部署与重载。

部署状态：2026-11-19 15:25–15:28（Asia/Shanghai）已将通过验证的 WinUI 构建替换到生产 `out/` 并重载。AHK `40516 → 28080`，WinUI `31344 → 5168`，PowerPolicy `13340 → 44404`；光标助手仅一个，OwnerPid 为新的 AHK PID。WinUI 生产自检和 PING 均通过，生产 DLL 与 test-out SHA-256 相同；PowerPolicy 新心跳、四路注册、Caffeine 请求余额 1 均已确认。RGB Ambient 当时未运行，未启动额外常驻实例。

只替换 `.source-stamp`、`ImeHudWinUi.dll`、`resources.pri` 三个差异产物，替换前备份在 `.tmp/deploy-review-20261119/backup-20261119-072522/`。部署结果和存活验证在同目录的 `hud-ahk-result.json`、`power-result.json`、`verification.json`。源码戳为 `f11e37c285750855545c1b8200d82147711c55dae3ece036afd768f7a2d2388b`。

部署巡检曾发现普通权限 Watchdog 无法读取提权 PowerPolicy 的命令行，15:16、15:21、15:26 误报 `query-failed`。随后按用户授权补充带仓库路径、PID/创建时间及源码指纹的心跳，普通权限看护已正常识别；受控停止后的恢复和健康轮询安静性均实测通过。PowerPolicy 任务已解除 Codex runtime 版本路径绑定，并实际从系统 Windows PowerShell 5.1 启动。

本轮固化了 `tools/startup/Deploy-Toolbox.ps1` 的 HUD 差异备份、原子替换、AHK 重载、PING/助手归属检查、失败恢复和显式回滚。连续部署同版本两次 unchanged，PID 不变；离线注入健康失败可恢复旧字节并重新启动。该回滚只涵盖发布产物，不回退工作区源码。新增离线 Windows CI 入口及真机矩阵，详见 `tools/startup/README.md`；正式全量回归通过，远端 Actions 与物理设备场景仍待实际执行。

后续检查对新部署流程追加修复：备份准备后若目标被更新，原流程会覆盖新字节。现已加入步骤间哈希预检；自动恢复只处理本次写入且未发生后续变更的文件，冲突时保留现场和备份。故障测试覆盖源/目标变化、新文件碰撞、部分写入、健康失败和回滚冲突。另新增两种 C# 助手隔离编译及来源 manifest，并完成真实音频只读枚举比对；生产助手未替换，设备切换/断连验收仍待执行。

历史限制：旧版本已覆盖却未记录的电源历史原值无法恢复推断；本次保证后续变更可恢复。

## 1. 发现（按建议处理顺序）

### R01 [P2] GDI Renderer 与 InputAnchor 的接口不匹配，状态芯片和翻译 fallback 实际抛错

- 位置：`shared/notify/renderer.ahk:594`、`:655`；接口定义 `shared/notify/anchor.ahk:26`。
- 触发：`NotifyRenderer.Show("popup", "", text)`，或走该 renderer 的 state 芯片。
- `InputAnchor.Get` 要求 `&x, &y`，返回布尔值；renderer 却无参调用，并把返回值当作带 `confidence/x/y/h` 的对象。调用立即抛出缺参异常。`Notify.Show` 捕获后退回 ToolTip，所以 WinUI 不可用时承诺的阅读气泡无法显示，普通 state 也失去自定义渲染。
- **运行证据**：加载实际 `main.ahk` 并传 `--test`，调用实际 renderer，得到 `Missing a required parameter.`，没有创建弹窗。
- 建议：统一返回契约；若保留 ByRef 接口，renderer 必须收集坐标、来源和所需尺寸，不能只补两个参数后继续读取布尔值属性。增加一次真实调用链测试。

### R02 [P2] C# 光标几何校验会拒绝正常高度窗口内的所有短插入点

- 位置：`shared/notify/AnchorLocator.cs:445`、`:501`。
- 当前要求光标距离窗口顶部和底部都不能超过 `maxInset`，而 `maxInset = min(windowHeight/3, 600)`（另有 120 下限）。这要求光标至少占窗口高度的约三分之一，与正常 20px 插入点矛盾。
- **条件复核**：窗口高 1000、光标高 20 时，inset=333。枚举窗口内所有合法 Y，接受位置为 **0**：上下间距之和是 980，却要求两项都不超过 333。
- 影响：PS 常驻 helper 无答案或无法使用时，C# 的真实 text-caret 路径系统性退化；重试也无法改变该条件。
- 建议：用窗口边界加容差判断是否在外部，再独立判断过大的矩形；补顶部、中央、底部的短光标用例。这是数学条件复核，未伪称真实 UIA 桌面实测。

### R03 [P2] WinUI 静默截断译文，复制按钮也只能交付被截断的内容

- 位置：`tools/ime-hud-winui/TranslationResult.cs:136`；原文存在同类逻辑 `TranslationSource.cs:162`。
- 触发：后端返回超过 4000 个 UTF-16 code unit 的译文。当前 2000 字中文输入翻译成英文可能超过该长度；提高后端 `max_chars` 也会更容易触发。
- `Normalize` 无提示地返回 `trimmed[..MaxChars]`，`Ok` 仍为 true；`TranslationPanelHost` 保存的是截断后的结果，`TranslationCopy` 复制的也是它。用户无法从面板取回完整译文。
- **运行证据**：反射调用当前、源码戳已验证的 test-out 程序集中的 `TranslationResult.FromExplicit`，5001 字输入仅保存 **4000** 字。
- 建议：保存完整文本，单独限制显示；若必须限制存储，应明确返回超长状态，不能当作完整成功。截断 UTF-16 还须避免切开代理对。

### R04 [P2] Caffeine 托盘会显示“合盖不会睡眠”，但电源策略已经判定为未启用

- 位置：`ahk/features/caffeine-indicator.ahk:55`、`:66`、`:93`；对照 `tools/power-policy/PowerPolicy.Core.ps1` 的 `Test-CaffeineActive`。
- 托盘只检查 `state.json` 中的 PID 存在，未检查 `startTicks`、到期时间或 `stop.flag`，状态目录也没有跟随电源策略的 `coffee_dir` 配置。
- 触发：计时会话到期但 worker 未退出、stop 文件先落地、遗留状态文件的 PID 被复用，或自定义 Coffee 目录。
- **运行证据**：分别用当前进程和过期/错误的创建时间构造状态，实际 AHK `IsActive()` 返回 **1**，实际 PowerShell `Test-CaffeineActive` 返回 **False**。
- 影响：托盘给出错误的防睡眠承诺，用户合盖时实际仍会睡眠。
- 建议：两端采用同一身份、有效期、停止信号和目录契约；提示还应考虑 PowerPolicy 是否有新鲜心跳。

### R05 [P2] 唤醒定时器被永久置零，卸载没有备份可恢复

- 位置：`tools/power-policy/PowerPolicy.Core.ps1:203`、`:207`；备份字段定义在 `:8`。
- `Invoke-WakeBlock` 在设备禁用策略之外，仍会把 AC/DC 的 RTCWAKE GUID 写成 0。但 `SettingDefinitions` 只有 LIDACTION、STANDBYIDLE、HIBERNATEIDLE、VIDEOIDLE，保存和恢复都不包含唤醒定时器。
- 触发：安装并运行常驻，原电源计划允许全部或重要唤醒定时器。即使 `wake.disable_devices=false`，此写入仍会执行。
- **隔离运行证据**：使用假的 `ToolboxPower.Native`，初值 AC=2、DC=1，调用后都变成 **0**；备份定义不包含该设置。没有修改本机电源计划。
- 建议：把 RTCWAKE 纳入逐电源计划备份和恢复，并在配置里说明该策略。

### R06 [P2] 设备恢复失败仍删除全部存档，失去重试依据

- 位置：`tools/power-policy/PowerPolicy.Core.ps1:167`、`:171`。
- 触发：卸载时设备不在线、权限不足，或 `powercfg /deviceenablewake` 失败。
- 函数只记日志，最后无条件删除整个 JSON。随后卸载还会报告已恢复；重新运行卸载已经不知道哪些设备未恢复。
- **隔离运行证据**：桩令 powercfg 返回 1，恢复函数结束后 `archiveExists=False`。
- 建议：仅移除已成功恢复的设备；保留失败条目并向卸载调用方返回失败或部分成功。

### R07 [P2] 唤醒设备实际在禁用之后才存档，写档失败会留下无法恢复的系统副作用

- 位置：`tools/power-policy/PowerPolicy.Core.ps1:194`、`:198`。
- 触发：禁用成功后状态目录不可写、磁盘错误，或进程在循环中被终止。
- 与 `REVIEW.md` 和当前注释的“禁用前存档”不同，实现先调用 `devicedisablewake`，全部处理完才调用 `Save-DisabledWakeDevices`。若写档失败，外层仅记录唤醒检查异常，已经禁用的设备没有恢复依据。
- **证据类别**：直接由调用顺序确认；没有对本机设备实施禁用故障实验。
- 建议：使用操作前日志，持久化成功后再执行禁用；对禁用失败条目做明确协调。无法保存恢复信息时应停止写系统状态。

### R08 [P2] OCR 异步 Toast runner 仍被父进程删除，形成启动竞争

- 位置：`tools/raycast-scripts/ocr/ocr.py:151`、`:168`、`:171`。
- `wait=False` 分支虽然返回，但 Python 仍会执行 finally，把刚交给 PowerShell 的 runner 删除。子进程的自删除语句无法解决父进程提前删除的问题。
- 触发：识别中通知以 `wait=False` 发出，子进程尚未读取脚本。当前 PID 固定文件名还会让连续通知互相覆盖。
- **隔离运行证据**：替换 Popen 为延迟消费桩，启动时文件存在，`notify` 返回后文件已不存在。
- 影响：识别中反馈随机消失；与旧评审第 (17) 项“父进程不再抢着删”相反。
- 建议：成功派发后转交文件所有权，并使用唯一文件名；只有派发失败或同步等待结束时由父进程清理。

### R09 [P2] OCR 报错路径再次写结果文件失败，会吞掉唯一的失败通知

- 位置：`tools/raycast-scripts/ocr/ocr.py:399`。
- 触发：模型初始化/识别失败，同时 result 文件目录不可写。这正是 detached WMI 路径已经在代码注释中记录过的权限情形。
- 成功路径把写 result 当作可忽略的诊断副产物，失败路径却先无保护地 `write_result`，再通知；二次异常会直接跳出 main。pythonw 无控制台，外层 ps1 又早已退出，用户得不到失败原因。
- **隔离运行证据**：识别桩抛 RuntimeError、写档桩抛 PermissionError，main 逃出 PermissionError，通知调用次数 **0**。
- 建议：错误结果写入也必须独立捕获 OSError，失败不能阻止 Toast 和明确的返回码。

### R10 [P2] TTS 下载异常发生在 finally 之前，仍留下临时音频

- 位置：`tools/tts/tts_player.py:567`、`:575`。
- `await communicate.save(temp_file)` 放在负责清理的 try/finally 外面。网络中断时，外层 except 返回 False，但不会进入 finally。
- **隔离运行证据**：假的 edge_tts 先写部分音频再抛 OSError，函数返回 **False**，临时文件仍存在。
- 影响：连续网络故障累积残片；只验证临时路径唯一性的现有两条测试无法发现此问题。残片还可能被当前按扩展名统计的 LRU 当作普通音频占用额度，清理只在整次朗读结束后才运行。
- 建议：把 await 下载也放进清理保护范围；增加部分写入后异常的行为用例。旧评审第 (14) 项的清理承诺并未覆盖实际失败点。

### R11 [P2] Hi75 IPC 的 timeout 参数无法约束阻塞 readline

- 位置：`tools/rgb/ambient.py:1005`、`:1012`。
- `_read_until` 在循环前检查 deadline，但 `stdout.readline()` 自身没有时间限制。helper 活着却不输出完整行时，8 秒 READY 和 2 秒 RPC 预算都会失效。
- **隔离运行证据**：无 HID 的测试子进程延迟约 0.4 秒才输出 READY，给函数 0.05 秒预算，实际 **约 0.45 秒**后仍返回 READY；如果一直无输出就没有返回上界。
- 影响：主 Ambient 循环卡住，两路灯光更新、flag 开关和优雅退出均无法继续。
- 建议：后台读线程把完整行放进队列，消费者按 deadline 等待；超时后回收并重连 helper。

### R12 [P2] 随仓 OpenRGB 网络实现没有处理包体 EOF，会无限空转

- 位置：`tools/rgb/lib/openrgb/network.py:130`、`:131`，其余 profile/plugin 分支同样存在。
- 触发：服务已经发出声明包体长度的头部，但在包体收齐之前关闭连接。
- socket `recv` 在 EOF 返回 `b''`，代码仍执行 `data += b''`，长度不变，while 永远继续。断连后的空读不需要等待 socket timeout，不能依靠设置的 10 秒超时退出。
- **隔离运行证据**：对实际 NetworkClient.read 方法注入 EOF socket，连续得到 **1000 次空读**，仍未退出或进入断连处理；测试桩主动抛哨兵异常才停止。
- 影响：调用它的 Ambient 线程无法重新连接，且可能持续占用一个 CPU 核心。
- 建议：共用 recv_exact，EOF 立即抛 OpenRGBDisconnected；头部也必须收满，而非假定一次 recv_into 完成。第三方目录中的代码同样进入实际生产调用链，应更新来源版本或维护明确补丁。

### R13 [P2] PowerPolicy 看护接受其他 checkout 的同名脚本，漏掉当前任务恢复

- 位置：`tools/startup/Ensure-ToolboxRunning.ps1:61`、`:62`。
- AHK 看护已经按仓库隔离，PowerPolicy 匹配却只判断 pwsh、`PowerPolicy.ps1` 子串和 `-Run` 子串，没有用已计算的 `$powerScript` 验证完整路径和参数 token。
- **隔离运行证据**：CIM 桩仅返回 `C:\OtherCheckout\...\PowerPolicy.ps1 -Run`，实际 Get-PowerPolicySnapshot 仍返回 **running**。
- 影响：当前配置对应的常驻未运行时，看护跳过拉起任务；也会把不可读命令行直接当作未运行。全局 resident 互斥体能减少重复进程，但不能证明正在运行的是当前部署。
- 建议：验证准确脚本身份、参数边界和运行心跳；状态未知与不存在分开处理。

### R14 [P2] 重启 AHK 的路径兜底仍能结束另一个 checkout

- 位置：`tools/raycast-scripts/restart-autohotkey.ps1:31`、`:124`，结束进程在 `:188`。
- 查询成功时，匹配条件仍保留 `或 lat3ncy-scripts-toolbox\ahk\main.ahk`。另一父目录下的同名 clone 也会进入随后 Stop-Process 的名单。
- **隔离运行证据**：CIM 桩仅返回其他 checkout 的 AHK，实际 Get-ToolboxAutoHotkeyProcess 选中了其 PID **99998**。没有结束任何真实业务进程。
- 影响：旧评审第 (12) 项修掉了按进程名杀全部，但成功查询路径仍没有实现“只重启当前仓库”的契约。
- 建议：与 ToolboxProcess.ps1 共用完整路径匹配器；不要以目录名称片段作为破坏性操作的依据。

### R15 [P2] 常驻光标协议使用有符号 TickCount，但 AHK 只接受正数字段

- 位置：`shared/notify/caret-uia.ps1:253`；消费者 `shared/notify/ime-hud.ahk:387`、`:401`。
- helper 写入 Int32 `[Environment]::TickCount`，高位变为 1 时输出负数；AHK 的时间戳正则只有 `\d+`，CARET/NOCARET 都匹配失败。
- 触发：TickCount 进入有符号负半周期，约 24.9 天的计数边界后。这里指计数值跨界，不把“用户认为的连续运行天数”作为必然条件。
- **运行证据**：向实际 AHK ReadCaretServer 传入 `T|-2147483648|CARET|123|456|20|text-caret`，结果 **Known=0、Ok=0**。
- 影响：稳定常驻助手被当成从未给出答案，每次触发增加等待和 locator fallback。
- 建议：明确统一两端计时宽度和符号，按相同无符号环绕算法计算年龄；只放宽正则仍不足以保证年龄正确。

### R16 [P2] 自启脚本没有给 main.ahk 参数加引号，带空格的 checkout 启动失败

- 位置：`tools/startup/Start-Toolbox.ps1:235`。
- `Start-Process -ArgumentList @($mainScript)` 最终会合成命令行；单元素数组并不自动保留包含空格的路径边界。
- 触发：仓库放在 `C:\Projects\My Tools\...` 或用户名等路径段包含空格。当前无空格的工作区不会暴露该问题。
- **运行证据**：用相同 Start-Process 参数构造运行一个带空格路径的无害 Python 脚本，解释器只收到第一个路径片段，退出码 **2**，测试脚本没有执行。
- 建议：明确引用脚本参数，或使用正确构造的 ProcessStartInfo 参数接口；实际 AHK 启动应补含空格路径回归。

## 2. 初次评审的覆盖范围与验证结果（历史基线）

本次清点 **200 个源码文件 / 53,483 行**：

| 类别 | 文件数 | 行数 | 覆盖方式 |
| --- | ---: | ---: | --- |
| 一方 AHK | 33 | 包含在一方合计 | 入口、路由、features、进程封装、托盘、通知和定位调用链；重点执行了 renderer、状态与协议复现 |
| 一方 PowerShell | 48 | 包含在一方合计 | 全量 5.1 AST/BOM 扫描；启动看护、电源、主题、Raycast、安装与构建路径检查 |
| 一方 C# | 21 | 包含在一方合计 | WinUI 协议和内容模型、宿主/剪贴板/定位、音频互操作、电源 native、指针助手检查 |
| 一方 Python | 10 | 包含在一方合计 | 翻译、TTS、OCR、RGB、安装器和测试；全量 AST 扫描 |
| 一方 VBS | 4 | 包含在一方合计 | 启动和等待/返回码转发检查 |
| 一方合计 | **116** | **35,568** | 全仓结构扫描，核心生产路径深读与针对性复现 |
| 随仓第三方 Python | **84** | **17,915** | 全量语法扫描，检查导入/集成边界，深读 OpenRGB 网络实现；未对 comtypes/dxcam/mss 做完整逐行第三方审计 |

以上不包含输出目录、obj/bin、虚拟环境、临时工作目录、图片/光标资源或二进制逆向。不能把“全仓扫描”理解成全部文件都做了同等深度的逐行审计。硬件插拔、真实睡眠/合盖、蓝牙重协商、UIA 各应用和多显示器 UI 仍需设备回归。

已执行：

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ahk\tests\run-tests.ps1`：**退出码 0**，包括 feature 独立加载、AHK 核心断言、WinUI 源码戳与 self-test、翻译 **33** 条、TTS **10** 条、启动隔离测试。
- 本次额外发现并检查全部 **48** 个 PowerShell 文件：Windows PowerShell **5.1.26100.9818** AST **0** 错误，非 ASCII 文件 BOM **0** 违规。现有主套件使用手写文件名单，未覆盖全部这些文件。
- 一方和第三方全部 **94** 个 Python 文件 AST：**0** 语法错误。
- `tools/power-policy/Test-PowerPolicy.ps1`：**退出码 0**；DryRun 没有改变电源计划，native 通知注册成功。该测试会短暂创建并释放防睡眠请求，没有发送关屏/睡眠命令。
- 针对本次发现运行 Python、PowerShell 和 AHK 隔离复现。系统写入相关复现使用假的 native/powercfg；OCR/TTS 使用桩；没有调用真实翻译/TTS 服务、没有禁用真实设备或安装/卸载任务。
- WinUI 用当前 test-out 程序集复核，没有重新 publish，也没有修改源码戳。

本次没有沿用旧文档的“109 PASS”作为新结论，因为主测试入口最终只输出核心通过标记，并未报告同一口径的总断言数。

## 3. 对旧 REVIEW.md 的修正

- 第 (9) 项的“禁用前存档”与实现顺序相反；设备恢复失败会丢档，唤醒定时器也不在恢复清单。
- 第 (14) 项加了清理 finally，但网络 await 不在其保护范围内；现有测试只验证临时路径，没有验证异常清理。
- 第 (17) 项宣称父进程不再删除异步 runner，但 finally 仍执行删除。
- `renderer.ahk` 不能继续只作为“未逐行审”记录：跨模块接口错误已经通过实际 AHK 调用确认。
- 旧文档关于“测试全绿”的记录可以保留为历史事实，不能据此把上述失败路径视为已验证。

## 4. 复现材料

初次评审的辅助材料保存在忽略目录 `.tmp/review-20261119/`；其中取证脚本对应修复前源码，修复后的验证使用正式测试入口：

```powershell
python .tmp/review-20261119/scan.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .tmp/review-20261119/scan-ps.ps1
python .tmp/review-20261119/repro.py
pwsh -NoProfile -File .tmp/review-20261119/repro.ps1
# 用真实 AHK v2 引擎运行；必须带 --test 隔离 main.ahk 的生产启动行为
AutoHotkey64.exe /ErrorStdOut=UTF-8 .tmp/review-20261119/repro.ahk --test
```

`inventory.json` 记录扫描时每个文件的路径、行数、SHA-256 和第三方标记；`ahk-evidence.txt` 保存当时的 AHK 复现输出。修复阶段日志在 `.tmp/fix-review-20261119/`，长期回归入口及新增测试已经纳入源码。
