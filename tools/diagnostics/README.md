# 统一离线诊断

在仓库根目录使用 Python 3.11+，无需管理员权限：

```powershell
python tools/diagnostics/doctor.py
# 机器可读输出；仅在显式指定 --output 时保存报告
python tools/diagnostics/doctor.py --json --output .tmp/diagnostics/report.json
# Shareable archive: new destination only; no paths, raw logs, text or keys
python tools/diagnostics/doctor.py --bundle .tmp/diagnostics/support.zip
```

默认检查配置 TOML 语法、引擎名、翻译源／目标语言枚举与回退开关、当前仓库 AHK/HUD/光标助手/PowerPolicy 状态、OCR/翻译/TTS 解释器和依赖元数据、进程完整性及 TEMP 写入能力，并列出日志位置与最近可识别的终态/失败类别。语言仅输出归一后的 `auto` / `zh` / `en`；回退开关仅接受布尔值，非法值只报告字段名。`ok` 表示这些离线检查通过，退出码为 0；缺失、过期、依赖不匹配或无法判断时为 `attention`，退出码为 1。启动失败也返回 1。

翻译/朗读摘要使用实际生效的本仓库非敏感偏好；应用覆盖时标记 `preferencesApplied=true`，并展示长文开关。ZIP 内只有重建白名单后的 `summary.json` 和范围说明，不含用户名/路径、PID、命令行、音色自由文本、原始日志、原文/译文或凭证。已有 ZIP 不会覆盖。普通 `--output` 本地报告仍含路径和 PID，与分享包用途不同。

`logs.translate.statistics` 汇总保留日志窗口中的请求数、各终态数量、平均/p95/最大耗时、完整成功中的缓存命中、成功/部分成功的回退请求数和复用段数。它不是生命周期总数、逐网络调用计时或物理 UI 验收；旧日志没有 metric 时样本数为零。部分失败单独记录为 `partial`，不会冒充完整成功。

`logs.translate.lastEngineRoutes` 独立保存各引擎最近一条摘要，`lastEngineFailures` 保留各引擎最近有失败的摘要，后续缓存/成功不会清掉历史失败。包含调用/失败/缓存/跳过次数、累计耗时和固定 kind；Google 的 `tls` 不再被首选腾讯的 `credentials` 原因掩盖。它们不自动拼成同一次请求或影响环境健康；本地记录有请求号，分享包移除请求号及所有自由字段。

Google 在线排查须显式运行 `python tools/translate/probe_google.py --online`，仅发送固定样本。默认 doctor 仍完全离线，不验证服务可达性，不输出代理地址。

内部解释器探针以 JSON 交付观察结果，交付成功时退出 0，即使发现依赖不匹配或低完整性；外层命令再按这些字段返回健康退出码。这样依赖异常不会被丢弃为笼统的子进程失败。

运行边界：

- 复用现有进程身份、心跳与 HUD PING；不启动、停止、重载常驻，不修改任务、配置、ACL 或依赖。
- 不联网、不加载 OCR 模型、不截图、不读取剪贴板、不播放声音。TEMP 可写性会创建并立即清理一个随机探测文件；Python 可能生成普通导入缓存。
- 解释器选择依据**运行此命令的环境**。AHK 已启动时持有的 PATH 可能不同。报告分别列出所选 `pythonw.exe` 与用于元数据检查的同目录 `python.exe`，完整性也是后者的实测；不把它等同于后台宿主的端到端验证。`pyw.exe` 没有确定的 console sibling 时保留无法判断。
- OCR 复用生产 `Get-OcrLaunchSpec`；同版基础宿主以 `-I -S` 验证并激活原依赖目录。系统 OCR 模式不需要 Python 模型依赖，标记 `not-applicable`；这不验证 Windows 截图应用的安装和使用。
- TTS 优先就绪且仓库归属匹配的用户目录环境，其次旧 `.venv`、全局解释器。OCR 和 TTS 均逐项比较完整 `requirements.lock` 的包版本；OCR 锁目标为 Windows Python 3.14。翻译使用标准库，无第三方依赖要求。元数据正常不保证原生 DLL/模型可加载，OCR 安装器 `--check` 另外验证实际导入。
- 配置检查不验证密钥是否存在或有效，也不调用服务；无法判断进程身份时为 `query-failed`，不会推断进程缺失或自动修复。HUD 会执行最多 2.5 秒的 PING；PowerShell 快照与每个解释器探针各限时 15 秒。

日志每份最多读取末尾 64 KiB，只提取固定格式的时间、终态、错误类别、退出码；未识别的格式不作推断。OCR 日志仅有本地时分秒，`completed` 可能包含空结果或取消。历史失败独立于最新终态，并且不影响本次环境检查结论。报告不包含日志原文、选中文字、译文、密钥、进程命令行或异常消息；包含本机路径与 PID。

翻译报告另外提供：

- `configs.translate.fallback_without_credentials` / `fallback_on_auth_error`：当前配置是否允许缺密钥／鉴权失败回退，缺省 false；不检查密钥值。
- `logs.translate.lastTerminalEvent`：成功记录的实际 `engine`、布尔 `cached` 和 `presentation=panel/popup`；启动或显示失败统一为 `status=fail`、`kind=internal`，并以 `stage=launch/delivery` 区分。
- `logs.translate.lastFallbackEvent`：最近可识别的 `preferredEngine`、实际回退 `engine`、固定 `reason` 和时间。它与终态独立保存，单独一条回退记录不代表交付成功或失败，也不自动归属最近终态。
- `logs.translate.lastFailure`：最近失败，即使后续成功也保留；支持鉴权、输入、I/O 等固定类别，绝不输出异常原文。

不加 `--json` 的普通输出也会显示回退开关、最近回退路线和失败阶段。诊断不发通知、不调用服务、不更改回退策略；历史回退或失败不会自动将当前环境标为 `attention`。

排查顺序：

| 结果 | 下一步 |
| --- | --- |
| `missing` / `interpreter-not-found` | 检查报告中的运行环境和模块安装说明 |
| `mismatches` 非空 | 按该模块现有安装入口恢复锁定依赖；诊断命令不自动安装 |
| `invalid` 配置 | 检查对应 `config.toml` 的语法、引擎、语言和回退布尔开关 |
| `outdated` | 对照源码/配置变更，使用已有正式重载入口 |
| `query-failed` / `probe-timeout` | 结合报告时间、当前权限及日志路径排查，保留未知状态 |
| 环境正常但功能失败 | 查看最新终态和错误类别，再运行模块的显式集成探针 |

2026-11-21 用户已实测确认 OCR、翻译、朗读基础使用正常。多屏/DPI、特定异常恢复、物理设备切换仍按各自验收矩阵执行，不因本命令通过而自动补为通过。

设置窗口的常规页增加“运行状态与版本”手动刷新入口。`tools/toolbox_status.py` 使用 `Collect-Runtime.ps1 -ResidentsOnly` 查询当前仓库常驻状态，另返回提交和已部署 HUD 源码戳；仅输出固定状态/标签/版本散列，不返回路径、PID、命令行、正文、原始日志或凭证。氛围灯仅核实进程，不能推断设备正常。原 doctor 的完整检查范围与健康退出码保持原语义。

光标助手另有仓库内忽略的 `caret-status.json` 归属心跳，由既有 AHK 控制定时循环发布。设置诊断验证仓库哈希、拥有者和子进程创建时间以及 20 秒新鲜窗口，从而在 WMI 受限时仍能提供正面证据；不会读取 UIA 坐标缓存，也不增加线程或常驻程序。

设置常规页的“维护操作 → 完整离线检查”调用 `toolbox_status.py --full`，使用 `collect(include_logs=False)` 跳过所有日志读取，仅返回固定模块、配置/环境状态及依赖不匹配数量。不返回路径、进程参数、凭证或异常原文；不调用网络或加载模型。默认命令行 doctor 仍保留原有脱敏日志摘要行为。
