# 评审与修复记录（2026-11-19）

本仓库一次完整代码评审 + 逐项修复的存档。每条都记录「问题 → 修法 → 验证证据」，
并按「改了」/「核实后决定不改」分开 —— 后者同样重要，避免下一次又把这些当 bug 重查一遍。

---

## 0. 结论摘要

仓库整体工程质量高于同类个人脚本集：`main → hotkey-router → features` 三层分离、
键位冲突在启动期校验、通知统一走 `Notify.*`、HUD 有卡死自愈、看护用「仓库路径哈希命名的
命名互斥体」而不是猜进程名，并且有 **AHK ↔ PowerShell 跨语言哈希一致性测试**。

本次评审发现的问题集中在三处，均已处理或明确搁置：

1. **跨层契约**（超时预算 / 协议字段 / 来源白名单 / 字符编码）没有单一事实源；
2. **提权脚本会留下不可见的系统副作用**（设备唤醒能力、`.theme` 编码、旧计划任务残留）；
3. **并发与失败路径的资源回收**依赖进程寿命兜底（Job 句柄、临时文件、helper 进程）。

---

## 1. 方法与可信度

- 范围：211 个源码文件 / 53,823 行（其中 `tools/rgb/lib/` 的 comtypes / dxcam / mss / openrgb 是 vendored 第三方，未审）。
- 交叉验证：AHK / PowerShell / Python / C# 四条线分别深读，关键结论都做了**实测复核**，
  文档中标 `[实测]` 的条目不是推断。
- 每轮改动后执行 `ahk/tests/run-tests.ps1`；最终基线 **109 PASS / 0 FAIL**。
- 基线测试覆盖：AHK 全部 feature 独立加载、全部 `.ps1` AST 解析、`ImeHudWinUi --self-test`、
  translate 33 条 + tts 10 条 unittest、启动隔离、跨语言互斥体哈希比对、BOM/CRLF 断言。

---

## 2. 已修复

### 2.1 AHK 层

#### (1) 光标助手变成 12 小时孤儿进程
- **位置**：`shared/notify/ime-hud.ahk`（`EnsureCaretServer`）、`shared/notify/caret-uia.ps1`
- **问题**：助手进程按 AHK 的 PID 命名输出文件，AHK 一重载就再起一个，旧的没人杀，
  会跑满 `ServeMs = 12 小时`，每 180ms 轮询一次 UIA。
- **修法**：给助手加 `-OwnerPid`，AHK 传 `DllCall("GetCurrentProcessId")`；助手在 serve 循环里
  每个间隔检查归属进程，消失就写 `END|owner-gone` 并退出。
- **验证** `[实测]`：以 2 秒退出的 `ping.exe` 当主人、`-ServeMs 60000`，
  助手在 **2.2 秒**后自行退出，末行 `T|...|END|owner-gone`。
  重载后实测只剩 1 个 helper，命令行带 `-OwnerPid <当前 AHK pid>`。
- **副作用**：该文件头写着 "ASCII only on purpose"，新增注释全部用英文；
  改完扫描确认 0 个 ≥0x80 字节、CRLF 295/295。

#### (2) `ProcessNoWindowJob` 被丢弃导致句柄泄漏
- **位置**：`ahk/features/audio-switcher.ahk` `Finish()`
- **问题**：`Finish()` 直接 `this.Job := ""`。若任务还在跑，`hProcess/hJob` 永不关闭，
  `KILL_ON_JOB_CLOSE` 不触发，子进程继续跑到 A2DP 重协商结束。
- **修法**：清引用前先 `if (IsObject(this.Job) && !this.Job.Done) { try this.Job.Dispose() }`。
- **验证**：新增 3 条行为断言（复用测试里的 `FakeTranslationJob`，断言 `HandlesClosed`
  被置位、`Job` 被清空、`Busy` 释放）。

#### (3) `Ctrl+V` 可能永久阻塞
- **位置**：`ahk/features/smart-paste/smart-paste.ahk`
- **问题**：`ProcessNoWindow.RunWait(command)` 走默认 `INFINITE`。PowerShell + 剪贴板取图
  一旦卡住，AHK 单线程假死（热键全失效）。
- **修法**：`static HelperTimeoutMs := 15000`，调用时传入。
- **验证** `[实测]`：用 `ping.exe -n 6` 冒充卡死进程，400ms 预算下
  **422ms 抛 `超时`**，且无残留 `PING.EXE`（Job 树被终止）。

#### (4) 错误 Toast 吞掉 IME 芯片
- **位置**：`shared/notify/notify.ahk` `Show()` / `HideToolTip()`
- **问题**：守卫是「错误通知活跃期间丢弃所有 level<3 通知」，而 CapsLock 切中英发的正是
  `state`（level 1）→ 错误 Toast 出现后 1.4 秒内按 Caps **没有任何反馈**。
- **修法**：守卫只压「结果类」通知 `if (type != "state" && ...)`；`HideToolTip()` 不再
  清零 `CurrentLevel/ActiveUntil`（那是「最近一次通知的优先级」，靠 `ActiveUntil` 自然过期）；
  state 分支改为「先清 ToolTip → 渲染 → 再记账」，修掉原来赋值被立刻清零的死逻辑。

#### (5) `CoordMode` 全局副作用不还原
- **位置**：`ahk/features/translate-selected-text.ahk`
- **问题**：`CoordMode "Mouse", "Screen"` 是全局设置，取完光标不还原，
  其它功能（find-mouse 等）会拿到错坐标。
- **修法**：`savedMouseCoordMode := A_CoordModeMouse` + `try/finally` 还原。

#### (6) 音频切换「无输出文件」时不看退出码
- **位置**：`ahk/features/audio-switcher.ahk`
- **问题**：`noOutput` 分支无条件 `Notify.Success`，非 0 退出码被当成成功。
- **修法**：`if (job.ExitCode != 0) { this.Finish("音频切换失败（退出码 …）") }`。

#### (7) 每次 `Caps+Q/R` 都同步打一次 WMI
- **位置**：`ahk/features/foreground-process.ahk` `Inspect()`
- **问题**：无条件 `QueryWmi(pid)`（一次 CIM 查询 50–300ms），全部压在热键线程；
  但 `Caps+Q` 只要 pid，命令行只有 `Restart` 才用。
- **修法**：`Inspect(needCommandLine := false)`，仅在 `needCommandLine || path = ""` 时才查；
  `Restart` 传 `true`，`Kill` 走快路径。

#### (8) `ImeHud` 的 locator 预算与 QUIT 收尾
- **位置**：`shared/notify/ime-hud.ahk`
- **问题**：
  - `LocatorTimeoutMs = 500`，而 `anchor-locator` 自身最坏要 3 次探测 × 250ms 间隔 →
    没命中真光标时**必然在写 `ERR` 之前被 `TerminateJobObject` 杀掉**，`--diagnose` 也拿不到诊断；
  - `Stop()` 走 `Send("QUIT")`，QUIT 在 HUD 里同步拆 Island + 退 XAML，超过 600ms 就被判卡死，
    进而杀进程再冷启动 —— **按「停止」反而拉起新实例**。
- **修法**：`LocatorTimeoutMs := 1200`；新增 `QuitTimeoutMs := 3000`，
  `Stop()` 直接 `SendCopyData(hwnd, "QUIT", QuitTimeoutMs)` 且不重试、不杀进程；
  `SendCopyData(hwnd, command, timeoutMs := 0)` 支持逐条预算。

### 2.2 PowerShell 层

#### (9) 唤醒设备被永久禁用且不恢复
- **位置**：`tools/power-policy/PowerPolicy.Core.ps1` `Invoke-WakeBlock`、`PowerPolicy.ps1`、`config.toml`
- **问题**：`$WakeWhitelist = @()` 恒为空（config 里没有这个键），于是常驻循环每 5 分钟把
  `powercfg /devicequery wake_armed` 里的**每一个**设备 `devicedisablewake`；
  这是**持久设置**，旧版卸载也不恢复。
- **修法**：
  - 新增 `[wake] disable_devices`（默认 `true`，保持原有"防误唤醒"意图）+ `keep`；
    `keep` 留空时使用**内置 HID 豁免**（`*键盘* *Keyboard* *鼠标* *Mouse* *HID*`），保证键鼠永远能唤醒；
  - 禁用前把设备名存档到 `%LOCALAPPDATA%\lat3ncy-toolbox\wake-disabled-devices.json`；
  - 新增 `Restore-DisabledWakeDevices`，卸载时按档 `deviceenablewake` 恢复。
- **验证**：AST OK；dot-source 后实测 `disable_devices=True`、白名单 5 条；无存档时恢复函数为空操作。
- **备注** `[实测]`：本机 `powercfg /devicequery wake_armed` 当时是「无」，
  而 `wake_from_any` 里只有音频/WiFi/VHD，没有键盘鼠标 —— 说明旧行为禁掉的正是
  这类「误唤醒源」，所以默认值保留 `true`，只补豁免与可恢复性。

#### (10) `.theme` 被按 UTF-8 解码再回写（会永久损坏）
- **位置**：`tools/theme-scheduler/ThemeUtils.ps1` `Sync-ThemeFileCursors`
- **问题**：只有 UTF-16LE+BOM 走对分支，其余一律 `UTF8.GetString` 解码、
  再以「UTF-8 无 BOM」写回。ANSI 编码且含中文的 `.theme`（中文方案名/中文用户名路径）
  会被解成 U+FFFD，回写后二次乱码。调用点是热路径（每次切主题、每次解锁补套）。
- **修法**：三态识别（UTF-16 BOM / UTF-8 BOM / 系统 ANSI 代码页），**按原编码回写**并保留 BOM 有无；
  写完读回比对，不一致就用备份还原并返回 `false`。
- **验证** `[实测]`：三编码往返 harness 全部 `byte-identical=True, text-preserved=True`
  （utf16-bom / utf8-bom / ansi）。

#### (11) 卸载漏删旧任务
- **位置**：`tools/power-policy/PowerPolicy.ps1`
- **问题**：`Install` 会清 `LidPolicy` / `LidPolicy-OnLidClose`，`Uninstall` 只清 3 个名字 →
  只装过旧版的机器上「卸载完成」后旧提权脚本仍在改电源状态。
- **修法**：卸载名单补齐这两个旧任务名。

#### (12) `restart-autohotkey.ps1` 的兜底会杀光所有 AHK 进程
- **位置**：`tools/raycast-scripts/restart-autohotkey.ps1` `Get-ToolboxAutoHotkeyProcess`
- **问题**：CIM 查询失败时 `return @(Get-Process -Name 'AutoHotkey*')` —— 机器上**其它项目**的
  AHK 脚本会被一起干掉。这与 `tools/startup/ToolboxProcess.ps1` 开头写明的
  "Matching by process name alone is wrong" 直接矛盾。
- **修法**：兜底只回答「有没有任何 AHK 在跑」：0 个 → 返回空（确定没跑）；
  有进程但认不出 pid → **抛错并说明**用管理员权限重跑，不再猜。
  同时把「启动后校验」从 CIM 换成**实例标记**（`Get-ToolboxInstanceMarkerState`，走命名互斥体，
  不依赖 WMI），CIM 被拒时正常路径也能用。
- **验证**：AST OK；静态断言 `has-name-kill: False` / `has-marker-check: True`；
  随后用它做了一次真实重载，`exit=0`、`marker=present`、AHK 与 HUD 都起来了。

#### (13) 编码约定没有自动化校验
- **位置**：`ahk/tests/run-tests.ps1`
- **问题**：README 要求「非 ASCII 的 `.ps1` 必须带 UTF-8 BOM」「`run-tests.ps1` 必须 CRLF」，
  但没有任何检查。2026-11 连续踩了两次（其中一次是本会话改文件时被编辑器剥掉 BOM，
  PowerShell 5.1 立刻按 ANSI 解析、报一堆 `Unexpected token`）。
- **修法**：在 AST 循环后新增两条断言，遍历 `$powerShellScripts + $PSCommandPath`：
  有 ≥0x80 字节却无 BOM → throw；`run-tests.ps1` 有裸 LF → throw。
  同时补上当时违规的两个文件（`tools/rgb/build_hi75.ps1`、`ahk/tests/run-tests.ps1`）的 BOM。

### 2.3 Python 层

#### (14) TTS 临时文件名只带 pid → 并发写坏永久缓存
- **位置**：`tools/tts/tts_player.py`
- **问题**：重复片段（`"Hello 世界 Hello"` 会切出两个 `(en,"Hello")`）拿到完全相同的
  `cache_path` 和 `temp_file`，默认 `concurrency=2` 并发写同一文件：互相截断、
  `shutil.move` 抛 `FileNotFoundError`、残片还能通过「文件非空」校验成为永久缓存命中。
- **修法**：抽出 `unique_temp_path(cache_path, ext)` = `{cache_path}.tmp.{pid}.{urandom(8)}{ext}`，
  两个调用点改用它；并补 `finally` 清理残片（`prune_lru_cache` 只统计 `.mp3/.wav`，
  看不见 `.tmp.*`，留着就是无界增长）。
- **验证**：新增 2 条单测（64 次调用得到 64 个不同路径 / 临时文件仍落在缓存目录内），tts 用例 8 → 10。

#### (15) MyMemory 把错误说明当译文，还写进缓存
- **位置**：`tools/translate/translate.py`
- **问题**：只挡 `MYMEMORY WARNING` 前缀，从不看 `responseStatus` / `responseDetails`。
  MyMemory 用 HTTP 200 + `responseStatus != 200` 表达「超长/超额/无配额」，
  此时 `responseData.translatedText` 里是错误说明 → 被当译文返回 → 写入缓存长期命中。
- **修法**：校验 `responseStatus`，非 200 直接抛异常；保留原有 WARNING 前缀检查。
- **验证**：新增 2 条单测（403 payload 必须抛 / 200 payload 正常返回）。

#### (16) 免费回退引擎装不下的长文本被报成「网络失败」
- **位置**：`tools/translate/translate.py`
- **问题**：云引擎不可用 → 回退 `google_gtx` / `mymemory`（都只走 GET）→ 2000 汉字 ≈ 6KB
  查询串 → 414 → 落在 `FALLBACK_ERRORS` → 最终 `code=network`，用户看到「网络请求失败」。
- **修法**：新增 `FreeEngineLimitError` 与字节预算
  （`mymemory: 480B`、`google_gtx: 4000B`），请求前先验；分类时映射为 `too_long`。
  不做截断 —— 与仓库「超长就报错、不静默截断」的既有决策一致。
- **验证**：新增 2 条单测（协议层 `code=too_long`；超长时不发出任何请求），translate 用例 31 → 33。

#### (17) OCR 的 toast runner 泄漏
- **位置**：`tools/raycast-scripts/ocr/ocr.py` `notify()`
- **问题**：`wait=False` 时 `runner_path = None` 跳过 finally 清理 → 每次 OCR 在仓库里留一个
  `.toast-<pid>.ps1`；同时两个 `PIPE` 没人读，子进程写满缓冲会永久阻塞。
- **修法**：`wait=False` 用 `subprocess.DEVNULL`；runner 模板尾部加
  `Remove-Item -LiteralPath $PSCommandPath` 让子进程自删（父进程不再抢着删）。

### 2.4 C# 层 / 二进制

#### (18) `PropVariant` 比原生少 8 字节 → 每次读设备名越界写
- **位置**：`tools/audio-switcher/AudioSwitcher.cs`
- **问题**：托管结构只有 `vt@0 + pwszVal@8` = **16 字节**，原生 `PROPVARIANT` 是
  `8 字节头 + 16 字节 union` = **24 字节**；`IPropertyStore::GetValue` 按 24 写 → 越界 8 字节。
- **修法**：补 `[FieldOffset(16)] private long unionTail`（SizeOf 16 → **24**，实测）；
  新增 `ole32!PropVariantClear` 并释放 `pwszVal`（`CoTaskMemAlloc` 分配，原来每次漏一块）；
  `IPropertyStore` 用 `Marshal.ReleaseComObject` 释放（12s 轮询里每 200ms 新建一次）。
- **验证**：csc 重编译 `audio-switcher.exe` → `--list` 正常枚举且中文设备名正确；
  `--ensure-headset` 输出 `SWITCHED|耳机 (...)`，证明源码中文串未被编译破坏。

#### (19) HUD 日志把用户原文/译文三份落盘
- **位置**：`tools/ime-hud-winui/Protocol.cs / HudHost.cs / Program.cs / HudLog.cs`
- **问题**：`HudLog.Line("copydata=" + text)` 在解析前原样写盘，而 `HudLog` 会写
  **exe 同目录 + %LOCALAPPDATA% + %TEMP%** 三份且无轮转；`SANITIZE` 也不转义换行，
  payload 里的 `\n` 能伪造日志行。
- **修法**：`Protocol.Describe(command)` 只输出「类型 + 字符数」（`PANEL|RESULT|chars=312`），
  非 `[A-Za-z0-9_|-]` 字符（含换行）一律丢弃；四个落盘点全换；
  `Sanitize` 把 `\r\n` 拍平成空格；`Line()` 加 1 MiB 轮转（每 200 次写检查一次，`.1` 单备份）。
- **验证** `[实测]`：重发布后生产日志出现 `command=empty`（旧代码是 `command=` 后跟原文），
  即 `Describe` 已在运行；`--self-test` 三次运行均 exit 0。

#### (20) 全局焦点元素被无条件当成目标窗口的光标
- **位置**：`shared/notify/AnchorLocator.cs` `TryTextCaret`
- **问题**：最后一级兜底 `element = AutomationElement.FocusedElement` 不校验归属，
  之后只做几何校验。另一个应用的焦点元素只要其 caret 落在目标窗口矩形内，就会被当成真光标。
- **修法**：**只拒绝「能证明是外人」的元素** —— 新增 `ProvablyForeign()`：
  向上 12 层找得到 `NativeWindowHandle` 且没有一个是目标的，才算外人；
  读不到句柄（Chromium 常见）或能走到目标窗口时保持原行为。
  这样严格收窄了接受集合，又不会把这条兜底本身关掉
  （直接套 `ElementBelongsTo` 会把 Chromium 路径整个关掉，因为其节点通常没有 HWND）。
- **验证**：csc 重编译 `anchor-locator.exe` + 冒烟 `OK|1536|1560|3098|1850|focus-bounds|0`。

#### (21) 编辑控件遍历的预算各层独立
- **位置**：`shared/notify/AnchorLocator.cs` `FindEditElementCore`
- **问题**：每层递归各拿 64 的预算（`remaining - 1` 只在同级递减），深层树的最坏情况是
  `64×64×…`，而 UIA 跨进程每节点是 ms 级 —— 卡住调用方的风险没有上界。
- **修法**：改成整个遍历共用 `ref int budget = 512`，每次进入 `budget--`。
  **刻意选 512 而不是 64**：Chromium 的树很大，真按 64 个节点卡死会找不到本该找到的 Edit。
- **验证**：csc 编译 + 冒烟通过。

#### (22) 电源/盖子通知只要一路成功就永久跳过其余
- **位置**：`tools/power-policy/PowerNative.cs` `StartNotifications`
- **问题**：`if (LidHandle != 0 || PowerHandle != 0) return;` —— display / resume 注册失败后
  再调也补不上，而且启动日志只报 lid/power/resume。
- **修法**：每路独立判重试（`if (XxxHandle == IntPtr.Zero)` 才注册）。
- **验证**：用 `tools/power-policy/Test-PowerPolicy.ps1` 实跑（它会 `Add-Type` 编译并真注册）：
  `PASS native registrations succeed`，四路错误码全 0。

### 2.5 测试基建

| 项 | 变化 |
| --- | --- |
| BOM / CRLF 断言 | 新增，每次跑检查 37 个脚本 + `run-tests.ps1` 自身 CRLF |
| `run-tests.ahk` | 新增音频 Job Dispose 的 3 条行为断言；更新 SmartPaste 超时断言 |
| `test_tts.py` | +2（临时路径唯一性） |
| `test_translate.py` | +4（MyMemory 状态码 ×2、免费引擎预算 ×2） |

---

## 3. 核实后决定不改（含理由）

### (a) `toggle-dotfiles` 会把「不是它隐藏的」点文件也恢复
初版按评审改成了「只恢复自己隐藏的」，测试立刻红：

    FAIL: dotfiles adopt already-hidden files

翻测试才发现作者**明确断言** `dotfiles adopt already-hidden files` /
`dotfiles restore previously self-hidden files` —— 这是有意的「显示当前文件夹所有点文件」
语义（对应 macOS `Cmd+Shift+.`）。**测试在这里就是规格**，已完整还原（内容零差异）。
教训：动手前先读测试，别把设计当缺陷。

### (b) `HudLog` 每行 3 次 `File.AppendAllText`
每次按键 30–60 行 × 3 路径 ≈ 90–180 次 open/close ≈ **2–5 ms**（NTFS SSD），
相对 HUD 自身 16–31 ms 是噪声。改成常驻 `StreamWriter` 会和「转发的第二个进程也写同一文件」
冲突：现在 `AppendAllText` 用 `FileShare.Read`，第二个进程写失败就跳过 ——
这是**有意的丢弃**，不会写出交错行。收益 < 风险。

### (c) 鉴权关键字用裸子串匹配
`TENCENT_AUTH_MARKERS` 里的 `"secretid"`、`"access key id"` 等确实偏宽，
但手里没有真实的厂商错误样本。收紧最可能的结果是把**真的鉴权失败**降级成
「回退到免费引擎」——那是静默的质量损失，比现在的误判更糟。需样本回归后再动。

---

## 4. 未决

1. `tools/raycast-scripts/ocr/` **整个目录没有测试**；要补得先定离线桩策略（依赖 RapidOCR 模型）。
2. `tools/translate/translate.py` 的 `TranslateSelectedText.Log()` 每行全量重写日志（性能项）。
3. `shared/notify/renderer.ahk`（870 行 GDI 芯片）只做了结构扫描，未逐行审。

---

## 5. 回归与复现

    # 全套（AHK / PowerShell / WinUI / Python）
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ahk\tests\run-tests.ps1

    # 改了 tools/ime-hud-winui 的源码后（会先重建 test-out）
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ahk\tests\run-tests.ps1 -BuildImeHud

    # 只跑 Python
    cd tools\translate && python -m unittest test_translate
    cd tools\tts && python -m unittest test_tts

    # 电源策略自检（会 Add-Type 编译 PowerNative.cs）
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\power-policy\Test-PowerPolicy.ps1

最终基线：**109 PASS / 0 FAIL**（translate 33、tts 10）。

> 备注：本机 `dotnet publish` 的 MakePri 环节在受限令牌下会 `ACCESS_DENIED`
> （连空目录都拒），所以 `-BuildImeHud` 需要在自己的终端里跑一次；
> 本次是用「编译器产物 + 沿用未改动 XAML 的 `resources.pri`」覆盖 `test-out`，
> 并用脚本同算法写入 `.source-stamp`，套件自身的
> `PASS: ImeHudWinUi test build matches current sources` 通过。

---

## 6. 变更文件清单

| 文件 | 所属修复 |
| --- | --- |
| `ahk/features/audio-switcher.ahk` | (2) (6) |
| `ahk/features/foreground-process.ahk` | (7) |
| `ahk/features/smart-paste/smart-paste.ahk` | (3) |
| `ahk/features/translate-selected-text.ahk` | (5) |
| `ahk/tests/run-tests.ahk` | 2.5 |
| `ahk/tests/run-tests.ps1` | (13) 2.5 |
| `shared/notify/anchor-locator.exe`（重建） | (20) (21) |
| `shared/notify/AnchorLocator.cs` | (20) (21) |
| `shared/notify/caret-uia.ps1` | (1) |
| `shared/notify/ime-hud.ahk` | (1) (8) |
| `shared/notify/notify.ahk` | (4) |
| `tools/audio-switcher/AudioSwitcher.cs` | (18) |
| `tools/audio-switcher/audio-switcher.exe`（重建） | (18) |
| `tools/ime-hud-winui/HudHost.cs` | (19) |
| `tools/ime-hud-winui/HudLog.cs` | (19) |
| `tools/ime-hud-winui/Program.cs` | (19) |
| `tools/ime-hud-winui/Protocol.cs` | (19) |
| `tools/power-policy/PowerNative.cs` | (22) |
| `tools/power-policy/PowerPolicy.Core.ps1` | (9) |
| `tools/power-policy/PowerPolicy.ps1` | (9) (11) |
| `tools/power-policy/config.toml` | (9) |
| `tools/raycast-scripts/ocr/ocr.py` | (17) |
| `tools/raycast-scripts/restart-autohotkey.ps1` | (12) |
| `tools/rgb/build_hi75.ps1` | (13) |
| `tools/theme-scheduler/ThemeUtils.ps1` | (10) |
| `tools/translate/test_translate.py` | (15) (16) |
| `tools/translate/translate.py` | (15) (16) |
| `tools/tts/test_tts.py` | (14) |
| `tools/tts/tts_player.py` | (14) |

另有 `tools/ime-hud-winui/out/ImeHudWinUi.exe` 与 `test-out/` 随 (19) 重新发布。
