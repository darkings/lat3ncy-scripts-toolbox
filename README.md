# lat3ncy-scripts-toolbox

个人 Windows 工具集：AutoHotkey v2 快捷键 + 一组 PowerShell/Python 小工具（翻译、朗读、音频切换、RGB、OCR、主题调度）。

各工具的细节写在 `tools/*/README.md`，这里只给总览和常用命令。

更新已有安装时，先看 [安装、更新与回滚](docs/RELEASING.md)；当前合并范围与验收记录见 [2026-11-21 发布候选](docs/releases/2026-11-21-reliability.md)。

## 快速开始

```powershell
# 需要先装 AutoHotkey v2，并让命令行能找到引擎（自启脚本和测试都依赖它）
Get-Command AutoHotkey.exe

# 启动工具箱
AutoHotkey.exe .\ahk\main.ahk
```

登录自启由启动文件夹里的快捷方式负责，它指向：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\startup\Start-Toolbox.ps1
# 失败原因（含 AHK 启动错误）看这里
Get-Content "$env:LOCALAPPDATA\lat3ncy-toolbox\startup.log" -Tail 20
```

**看护任务（唯一一个，看护两个对象）**：`Lat3ncyToolbox-Watchdog` 在登录时以及之后每 5 分钟检查一次，对象有两个：

1. `ahk/main.ahk` —— 不在就调用 `Start-Toolbox.ps1` 拉起；
2. `tools/power-policy/PowerPolicy.ps1` 的常驻循环进程 —— 不在就 `Start-ScheduledTask PowerPolicy`。

两段逻辑都在 `tools/startup/Ensure-ToolboxRunning.ps1` 里，任一对象异常都以退出码 1 结束并写日志。启动方式是 `wscript.exe //B tools\startup\Watchdog-Launch.vbs`（VBS 里写死路径，任务参数没有嵌套引号），不分配控制台。

> 补充：非提权进程可以启动 `RunLevel=Highest` 的计划任务（本机 2026-10-24 实测），所以看护任务保持 `Limited`，电源策略任务保持 `Highest`，两者不冲突。
>
> 存活判定只认本仓库的 `ahk\main.ahk`：`main.ahk` 正常启动后会创建一个按仓库路径哈希命名的 `Local\Lat3ncyToolboxInstance-*` 互斥体，看护以这个实例标记为准；命令行精确绝对路径只作为旧实例/过渡期后备。相对路径 `.\ahk\main.ahk` 无法证明属于哪个 checkout，不再单独判为 running；CIM 成功但某个 AHK 进程的 CommandLine 不可读时保持 unknown，不启动重复实例。CIM/进程查询失败与“目标不存在”分开处理：查询失败会记 `ahk-query-failed` 并跳过本轮，不会因为一次异常查询就重复启动（`main.ahk` 是 `#SingleInstance Force`，重复启动会替换掉正在运行的实例）。

```powershell
# 注册/更新（需要管理员；任务注册在普通权限下会被拒）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\startup\Install-ToolboxWatchdog.ps1
# 查看
schtasks /query /tn "Lat3ncyToolbox-Watchdog" /fo LIST
Get-Content "$env:LOCALAPPDATA\lat3ncy-toolbox\startup.log" -Tail 20
```

启动文件夹的快捷方式也必须指向仓库自有的 `tools\startup\Toolbox-Launch.vbs`（不要再引用仓库外的 VBS，也不要往快捷方式里塞嵌套引号）。

跑测试（先构建、再测试，避免旧 `out` 造成假通过）：

```powershell
# 首次运行、或改了 tools/ime-hud-winui 的源码后：
# 构建到 tools/ime-hud-winui/test-out（不碰正在运行的 out），再跑全套
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ahk\tests\run-tests.ps1 -BuildImeHud

# 日常回归：test-out 的源码戳必须与当前源码一致，否则会直接报 stale
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ahk\tests\run-tests.ps1
```

测试入口包含：AutoHotkey 各 feature 独立加载及通知/状态行为测试、全量一方 PowerShell AST/BOM、WinUI `--self-test`、光标定位几何自检、Python 编译与自测、翻译/TTS/OCR/RGB 的离线行为测试、看护匹配与含空格路径的真实 AHK 启动、电源备份恢复的隔离测试。离线测试不会禁用设备、修改电源计划或连接 OCR/TTS/RGB 服务。需要 AutoHotkey v2、.NET SDK（`-BuildImeHud`）、Python 3.11+（标准库 `tomllib`）和 Windows PowerShell 5.1。`run-tests.ps1` 本身必须保持 CRLF；非 ASCII 的 `.ps1` 必须带 UTF-8 BOM。

## 故障诊断

在仓库根目录运行 `python tools/diagnostics/doctor.py`，一次查看当前仓库常驻状态、OCR/翻译/朗读的解释器、依赖、配置语法及日志位置。无需管理员权限，不联网、不触发截图或朗读；使用 `--json --output .tmp/diagnostics/report.json` 可保存元数据报告。检查范围和结果解释见 [统一离线诊断](tools/diagnostics/README.md)。

2026-11-21 用户已确认 OCR、翻译和朗读基础使用正常；专项异常、多屏和设备场景单独保留验收记录。

## 快捷键

改键只编辑 `ahk/shortcuts.ahk`；`ahk/hotkey-router.ahk` 负责校验和注册，`ahk/features/` 只实现功能。两个功能抢占同一快捷键会在启动时报错，不会静默覆盖。

| 快捷键 | 功能 |
| --- | --- |
| `CapsLock` | 短按切中/英（记住，切窗口后恢复）；250–500ms 松开取消；长按进大写 |
| `Caps + S` | 朗读选中文字，再按一次打断 |
| `Caps + F` | 划词翻译（无选区则译剪贴板），光标处弹译文面板 |
| `Caps + I` | 框选截图并翻译；识别期间再次按下取消任务 |
| `Caps + G` | Google 搜索选中文字 |
| `Caps + O` | 打开选中的文件、目录或 URL |
| `Caps + E` | 在资源管理器中定位选中目标 |
| `Caps + T` | 活动窗口置顶 / 取消置顶 |
| `Caps + H` | 按 Z-order 逐个最小化可见窗口 |
| `Caps + .` / `Caps + ,` | 切换隐藏文件 / 切换当前文件夹顶层点文件 |
| `Caps + X` | 切换文件扩展名显示 |
| `Caps + Q` / `Caps + R` | 结束 / 重启前台窗口的进程 |
| `Caps + D` | 切换音频输出 `G27Q2 ↔ AirPods`（自动连接） |
| `Ctrl + V` | 智能粘贴：剪贴板是图片时存成本地 PNG，其余原样透传 |
| `Alt` + 反引号 / `Shift + Alt` + 反引号 | 同一应用窗口间正 / 反向循环（Zed 走项目切换） |
| 无快捷键 | 快速左右摇鼠标 → 指针临时放大（1.4s 后恢复）**已暂时停用**：`FindMouse.Enabled := false`，改回 `true` 即恢复 |

## 工具

| 工具 | 说明 |
| --- | --- |
| `tools/translate/` | `Caps+F` 的翻译后端，腾讯云 TMT 为主，可回退 |
| `tools/tts/` | `Caps+S` 语音朗读，Edge Neural + 本地音色，本地缓存；日志默认不含原文 |
| `tools/audio-switcher/` | `Caps+D` 音频切换（`--toggle` / `--ensure-headset` / `--recover` / `--list`） |
| `tools/rgb/` | 桌面取色联动风扇与键盘灯，OpenRGB 走系统服务 |
| `tools/ime-hud-winui/` | CapsLock 状态芯片与翻译面板（WinUI 3），改了必须重载 |
| `tools/raycast-scripts/` | Raycast Script Commands，见下表 |
| `tools/theme-scheduler/` | 按日出日落切深浅色 / 壁纸 / 鼠标方案 |
| `tools/power-policy/` | 合盖/空闲的睡眠与休眠策略，Caffeine 感知（动态切 `LIDACTION`） |
| `tools/startup/` | 登录自启入口 + 看护任务（看护 AHK 与 power-policy） |
| `resources/cursors/` | 9 套鼠标配色，供 theme-scheduler 使用 |
| `resources/icons/` | 托盘图标：Caffeine 咖啡杯黑/白两版（`coffee_power_{black,white}.ico`，源图 `coffee_power.svg`） |

Raycast 里添加 `tools/raycast-scripts` 目录即可用，可逐个绑 Hotkey：

| 脚本 | 功能 |
| --- | --- |
| `restart-autohotkey.ps1` | 重启本工具箱的 `main.ahk` |
| `screenshot.ps1` / `record-screen.ps1` | 截图 / 录屏框选 |
| `screenshot-ocr.ps1` | 屏幕区域 OCR（RapidOCR（默认，走 `ocr/.venv314`）或 `system`；引擎见 `ocr/config.toml`） |
| `screenshot-translate.ps1` | 截图翻译，与 Caps+I 使用同一流程 |
| `toggle-rgb.ps1` | 开关风扇 + 键盘灯 |
| `next-wallpaper.ps1` | 换成图池里的下一张壁纸（同时设锁屏） |

> Codex 开关**已迁出本仓库**，改成独立 Raycast 扩展：
> `C:\Users\Jie\Projects\codex-switch-raycast`（单入口，可在扩展里增删中转）。

## 需要配置的地方

几个 TOML，都在各自工具目录里，仓库里的模板留空：

- `tools/translate/config.toml`：`engine = "tencent"`。密钥优先读用户环境变量 `TENCENTCLOUD_SECRET_ID` / `TENCENTCLOUD_SECRET_KEY`，其次读配置文件。显式配置云引擎但缺少密钥时返回 `config` 错误（不会静默回退）；只有显式设置 `fallback_without_credentials = true` 才允许改用免费接口。鉴权失败（`auth`）永不回退；网络/超时可按引擎顺序回退，结果会带实际使用的 `engine`。`max_chars` 现在是硬上限：超长直接报 `too_long`，不再静默截断。详见 `tools/translate/README.md`。
- `tools/theme-scheduler/config.toml`：`switch_type`、`schedule.trigger_mode`（`sun` / `fixed`）、壁纸目录、`[cursor]` 配色、`[keyboard_backlight]` ThinkPad 键盘灯联动。
- `tools/tts/config.toml` / `tools/audio-switcher/config.toml`：音色、设备关键字。

装依赖（按需）：

```powershell
python .\tools\tts\install-deps.py                 # 朗读
python .\tools\raycast-scripts\ocr\install-deps.py # OCR 的锁定 Python 3.14 环境，需要 uv
python .\tools\raycast-scripts\ocr\install-deps.py --check # 只检查版本和实际导入
```

OCR 依赖固定在专用 `.venv314`，使用 `requirements.lock` 的版本及 SHA-256，避免全局 Python 升级影响原生包。安装器不会更改 OCR 模式或模型配置；可用 `--mobile-models` 显式下载原有的哈希校验模型。仅安装/检查依赖不会加载模型或读取剪贴板。

## 截图翻译与译文朗读

按 `Caps+I` 或运行 Raycast 的 **Screenshot Translate**，在 Windows 截图工具中框选区域。识别后面板显示原文并自动翻译；完成后可点标题栏的播放按钮 **朗读译文**（面板内 `Alt+R`），再次点按 **停止朗读**。复制按钮仍复制译文，原文可选中后复制。

截图翻译使用本地 RapidOCR，要求上述锁定环境；原有独立 OCR 命令仍按自己的 `ocr` 模式工作。翻译沿用现有引擎、凭证和字数上限；失败时保留识别原文，朗读按钮保持禁用。文字通过任务文件交付，不用剪贴板中转，不模拟快捷键；Windows 截图工具自身仍会将截图放入系统剪贴板。

截图识别阶段再次按 `Caps+I` 取消当前任务；未完成截图约 30 秒后静默取消，OCR 进程组硬预算 90 秒。翻译阶段沿用 14 秒预算，关面板或开始新翻译会取消旧请求。关闭或替换面板会停止该面板发起的朗读，但不会停止后来独立发起的 Caps+S 朗读。停止与完成后清理任务文件，进程异常退出留下的文件在后续启动核验旧 PID/创建时间后回收。

朗读沿用既有本地/在线策略；点击播放才开始朗读，不自动播放译文。翻译会将识别出的文本发送给所选翻译服务。

划词和截图翻译共用语言设置：在 `tools/translate/config.toml` 顶层设置 `source_language = "auto"`、`target_language = "zh"` 可固定译为中文；目标改成 `en` 固定译英文，两项均为 `auto` 保留原有中英互译。每次请求读取，无需重载；同语种直接返回原文。完整选项见 [翻译说明](tools/translate/README.md#配置)。

腾讯云首选、Google 保底：顶层设置 `fallback_without_credentials = true` 和 `fallback_on_auth_error = true`，缺密钥或鉴权失败时使用 Google。回退成功不发系统通知，只记录后台诊断；密钥恢复后自动优先腾讯。完整回退顺序见 [翻译引擎与回退](tools/translate/README.md#引擎与回退)。

固定图片的连续联动验收入口为 `python tools/validation/text_workflow_smoke.py --ahk <AHK-v2路径>`，默认不联网、不播放声音，会替换并关闭当前翻译面板；覆盖真实 OCR、翻译进程、面板回传及失败/取消清理。显式 `--online` 才使用现有引擎发送固定测试文本，操作及验收边界见 [联动探针](tools/validation/README.md#连续联动探针)。

## 主题、RGB 与设备

主题调度的五个计划任务用脚本注册，不要手写 `schtasks /create`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Install-ThemeScheduler.ps1
schtasks /run /tn "Theme-Light"   # 立即切浅色；同理 Theme-Dark
```

> **注册脚本必须提权运行**：`Theme-Apply-Now` / `Theme-Apply-Cursors` 是提权创建的，非管理员重注册会对它们报 `Access is denied`（其余三个能过）。提权重跑一次即可全部更新。
>
> **任务是无窗口的，靠 `wscript.exe` 外壳实现**：任务计划程序不能直接跑 `powershell.exe`——它是控制台程序，以交互方式在用户会话里启动时会分配真实控制台，导致**睡眠唤醒/解锁时屏幕上蹦出一个终端窗口**；任务的 `-Hidden` 只作用于任务自身，管不到子进程。
> `Get-ThemeHiddenAction` 会为每个脚本生成一个 VBS shim（`%LOCALAPPDATA%\lat3ncy-toolbox\theme-tasks\<脚本名>.vbs`），任务改为 `wscript.exe "<shim>"`；shim 里用 `WshShell.Run(cmd, 0, True)` 静默等待 PowerShell 跑完，任务状态仍准确。
> **不要再用 `conhost.exe --headless` 当外壳**——`--headless` 不是"隐藏窗口"开关（它是 ConPTY/终端集成的标志），直接由计划任务启动时照样会出窗口；这个坑 2026-10-02 已修复并复验。
>
> **唤醒后为什么会立刻对齐**：休眠唤醒不是"登录"，`Theme-Apply-Now` 的 AtLogOn 触发器永远不会补位；而任务计划程序的漏跑补偿（`StartWhenAvailable`）实测要 6 分钟到 24 分钟不等（2026-10-31 08:29:09 从 S4 唤醒、08:35:08 才补跑 `Theme-Light`，期间一直是深色）。所以"按当前时间对齐颜色"放在了 `Apply-CursorsNow.ps1` 里——它由 `SessionUnlock` / `ConsoleConnect` 触发，实测唤醒后 0.5 秒内就能被拉起。顺带：`-WakeToRun` 在本机是空转的，电源方案里"允许使用唤醒定时器"交流/直流都是禁用，休眠恢复时不会编任何唤醒定时器。
>
> **一次切换被拆成两段**：`Set-Theme-Light/Dark.ps1` 只负责"写注册表 + 刷新 Shell + 广播"，然后立刻派发 `Set-Theme-Tail.ps1` 去处理壁纸 / 鼠标方案 / 键盘背光 / 锁屏。尾巴实测 5~17 秒（锁屏 p90 10s、壁纸 1.5~2s），现在跑在独立进程里，任务状态反映的是"颜色切完了"；而且只有颜色真的变了才派发尾巴，避免幂等补跑把壁纸连跳两张。
>
> 2026-10-31 实测收益：完整浅色切换从任务启动到主脚本退出 **1.4 秒**（改前典型 13 秒、峰值 36 秒）；`Get-ThemeScheduleTimes` 从 1.65~2.3 秒降到 **~80ms**（不再用 `Get-ScheduledTask` 做全量 CIM 枚举，改读任务定义 XML，`Get-ScheduledTask` 单次实测 814~1155ms）；全局广播改用 `SendNotifyMessage` 投递不等待，消掉"最坏等待 = 超时 × 顶层窗口数"的长尾（日志里出现过 111 秒和 560 秒）。

RGB Ambient（首次需管理员装官方 OpenRGB 服务，之后日常不用管）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\install.ps1
python tools\rgb\ambient.py --dry-run --time 5
```

## 异步与日志

- `Caps+F` 翻译改为异步：热键线程只负责取选区、打开面板和启动 `translate.py`，完成状态由 100ms 定时器轮询。连续触发会取消旧请求；旧请求完成时按请求序号丢弃，绝不会覆盖或关闭新请求的面板。用户先关掉面板时，迟到结果直接丢弃（不重新打开）；14s 超时会杀子进程树并回收句柄。面板不可用时才退到 AHK popup。诊断只写 `%TEMP%\lat3ncy-translate.log`，不含原文和密钥。
- `Caps+D` 音频切换和 `Caps+S` 的可选耳机预热也不再同步 `WaitForSingleObject`：子进程异步启动，HUD 先出，完成后由定时器收尾；起止时间、输出协议和超时预算保持不变。
- `tools/tts/tts.log` 默认只记长度、切片数、引擎/音色、缓存命中、耗时和错误类型，不记原文或片段；只有 `log_text = true` 才允许写全文。日志使用 1 MiB × 2 备份的追加轮转，已有日志不会被清空。

## 通知约定

- **HUD 卡死自愈**：`ImeHudWinUi.exe` 在锁屏/切显示器后可能死锁（窗口还在、消息循环不响应 → 中英文切换没有提示）。客户端发送前检测 `IsHungAppWindow`，超时后结束卡死进程并冷启动重试，并每 20 秒巡检一次。HUD 日志按 `out\ImeHudWinUi.log` → `%LOCALAPPDATA%\lat3ncy-toolbox\` → `%TEMP%` 依次尝试写；受限令牌下只有 exe 同目录可写。AHK 侧日志在 `%TEMP%\ImeHudClient.log`（`hud-hung` / `hud-restart` / `send-failed`）。
- **首次显示延迟（2026-10-24 实测）**：稳态 `CapsLock → 芯片` **16–31ms**。已修掉两个慢路径：① 光标助手原来 15 分钟过期，之后第一次按键要等它重启并建无障碍树（实测 **859ms**）→ 改为 12 小时寿命 + 20 秒巡检保活；② 无光标时助手一轮发布间隔超过新鲜窗口，导致每次都被判成“没有答案”，白等 350ms 再白调 500ms locator → 助手改 `-Attempts 1`、新鲜窗口 700ms，且新鲜的 `NOCARET` 直接跳过等待与 locator。HUD 冷启动也改成“等能应答再发”（600ms × 3 次重试，而非 2.5s × 2）。唯一残留慢路径：AHK 刚启动不到 1 秒就按键，要等助手首次建树（约 1s）。
功能模块统一用 `Notify.State() / Info() / Success() / Error()`，不要自己造 GUI 或直接 `ToolTip`。状态类走 WinUI HUD（失败回退 AHK 芯片），成功/失败走系统 Toast。改了锚点或 HUD 代码后必须重编译锚点、重发布 HUD 再重载 AHK，否则常驻进程里跑的还是旧 exe。

## 仓库结构

```text
ahk/                 main.ahk 入口、shortcuts.ahk 快捷键、hotkey-router.ahk 路由、features/、tests/
shared/              python.ahk（pythonw 解析）、notify/（HUD、Toast、锚点）
tools/               各工具与 Raycast 命令（见上表）
resources/           鼠标配色、托盘图标
findings.md          研究与决策记录
progress.md          会话进度
task_plan.md         阶段任务计划
```

## 已知坑

- 发布、回滚、电源重载及离线 CI 的完整操作见 `tools/startup/README.md`。正式入口为 `tools/startup/Deploy-Toolbox.ps1`，电源重载为 `tools/power-policy/Restart-PowerPolicy.ps1`；真实设备验收矩阵与自动化通过结果分开记录。
- 锚点和音频助手的隔离编译、源码/产物 SHA-256 来源核对见 `tools/build/README.md`；该入口不覆盖生产助手。

- 命令行找不到 `AutoHotkey.exe` 时，自启脚本和测试都会失败；把安装目录加进 `PATH` 后重开终端。
- Scoop 的 `apps\autohotkey\current` 正常应是 junction，变成实目录后 `scoop update` 会半删除它：先停 AHK，删掉 `current`，再用 `New-Item -ItemType Junction` 指回版本目录。
- 锁屏壁纸脚本必须由 Windows PowerShell 5.1 执行（WinRT 互操作），文件要保持 UTF-8 BOM；`ahk/tests/run-tests.ps1` 需要 CRLF。
- 锁屏图片只能走 `LockScreen.SetImageStreamAsync`（自己读文件 → 包装成流交给系统）。别退回 `StorageFile.GetFileFromPathAsync`：它受存储代理的「应用可访问位置」检查，从 MSIX 打包应用（Raycast）派生的子进程会被 `E_ACCESSDENIED` 拒绝，且报错只说「文件不在应用可访问位置」。
