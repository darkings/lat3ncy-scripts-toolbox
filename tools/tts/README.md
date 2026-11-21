# TTS Player（tools/tts）

`tts_player.py` 读取文本，按中英文语境切片，通过 WinRT 本地 OneCore、SAPI WAV 或 Edge Neural TTS
并发合成并即时播放；带 SHA256 缓存、LRU 容量清理与 Windows SAPI 本地兜底。

2026-11-21 用户已确认朗读基础使用正常；下文 2026-11-20 的听感未确认属于历史记录。专项异常与设备切换仍按独立矩阵验收，安装与恢复流程见 [发布操作](../../docs/RELEASING.md)。

译文面板的播放按钮通过 AHK `SpeakSelectedText.SpeakText(text)` 直接调用同一受管任务入口，不模拟 Caps+S 或复制选区。每次返回的 generation 用于面板朗读归属；面板关闭时只停止仍属于自己的那次朗读，后来独立触发的 Caps+S 不受影响。

## 运行环境

- Windows 10/11。播放使用 `winmm` 的 MCI 接口，非 Windows 平台会跳过播放。
- Python 3.11+（使用标准库 `tomllib`；本仓库实测 Python 3.15）。
- 核心脚本只用标准库，不需要新增依赖。
- 合成引擎依赖为可选项：
  - WinRT 本地离线：`winsdk`；未安装或合成失败时，该片段走 SAPI 兜底朗读。
  - Edge 在线 Neural：`edge-tts`；未安装或合成失败时，该片段走 SAPI 兜底朗读。
    经过真实合成验证的版本为 `edge-tts==7.3.1`；7.2.8 在当前服务返回 HTTP 403。
- Windows 上 `python tools/tts/install-deps.py` 默认在 `%LOCALAPPDATA%\lat3ncy-toolbox\tts-runtimes\<module-key>` 创建独立环境，按 `requirements.lock` 的版本及 SHA-256 安装，不安装到全局 Python。key 与 AHK 共用规范化模块路径的 UTF-8 FNV-1a；owner 标记防止路径碰撞，依赖校验完成后才原子发布 ready 标记。`--check` 只读检查当前环境，未就绪返回非零。
- AHK 优先选择归属匹配且已就绪的用户目录 `Scripts\pythonw.exe`；否则依次使用原模块 `.venv` 和原有全局解释器解析。原 `.venv` 保留；`--location repo` / `--check --location repo` 可维护旧环境。安装失败会撤销新环境的 ready 标记，不让半成品替换旧宿主。
- 新位置使用用户目录的正常继承权限，不修改仓库或解释器 ACL、不提权。本机新环境实测为 medium/RID 8192；已有仓库内 low/RID 4096 的解释器标签保持原样。
- 缓存优先使用 `%LOCALAPPDATA%\lat3ncy-toolbox\tts-cache`；实际写入探针失败时使用本模块 `.cache`。两处都使用原有 LRU 上限，均不调整系统 ACL 或提权。

`auto` 的本地音色路径依次尝试 WinRT、SAPI 文件合成，均失败后才使用 Edge 在线音色（中文 Xiaoxiao、英文 Aria），因此失败回退会发送待朗读文本到语音服务。该行为已于 2026-11-20 获用户明确授权。显式 `engine = "winrt"` 保持离线，不启用在线回退；显式 Neural 音色仍直接走在线引擎。

SAPI 使用系统 Windows PowerShell 5.1 的 `System.Speech`，通过 stdin JSON 接收文本，不把输入放入进程参数或 PowerShell 代码。固定脚本转义 SSML 文本/属性，按请求语言选择已安装的可用声音，优先匹配名称；本机英语为 Zira Desktop，中文请求 Yaoyao 不存在时使用同语言 Huihui Desktop。SSML 处理语速、音高和音量；实际声音效果仍需听感确认。[WAV 输出接口](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.setoutputtowavefile?view=netframework-4.8.1)、[SpeakSsml 接口](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.speakssml?view=netframework-4.8.1)。

SAPI WAV 的缓存键包含独立后端前缀、语言、请求音色和参数，不与 WinRT WAV 或 Edge MP3 混用。取消/合成预算耗尽时结束 SAPI 子进程并等待退出、清理残片；它也继承 AHK 任务的 Windows Job 归属。

实际 MCI 或 SAPI 失败不会再记为播放成功；所有后备路径都失败时，进程返回非零退出码。

## 任务、取消与时间预算

AHK 现在持有要求成功绑定 Windows Job 的异步任务，创建时先挂起、绑定后恢复。取消或退出会结束整组进程，包含 SAPI 子进程；不能建立进程组时拒绝启动，不退回只杀父 PID。播放资源随所属进程回收，不再从 AHK 调用全局 `close all`。

每次请求在 `.cache/requests/<id>/` 创建独立输入和结果文件。id 包含 AHK PID、创建 FILETIME 与随机量；只接受当前请求、当前 generation 的完成结果。音频残片同样带 request id，清理不会扫描删除其他请求的文件。取消后异步重试文件清理；AHK 被强制结束留下的请求，会在后续朗读启动时核验旧 owner 的 PID/创建时间后回收，未知或活跃 owner 保留。

默认每片合成预算 30 秒，包含本地尝试及在线回退；排队时间另计。Python 总任务预算 1795 秒，AHK 进程组硬上限 1800 秒（30 分钟），避免原生播放或线程退出拖住整个请求。合成/等待超时会取消未完成的合成并执行清理；外层硬上限仍可结束整个进程组。较长朗读需考虑该上限。

内部调用参数为 `--request-id`、`--result-file`、`--synthesis-timeout`、`--task-timeout`。终态文件是最多 1 KiB 的 UTF-8 固定字段协议：

```text
version=1
request_id=<当前请求编号>
status=success|failed|timeout|cancelled
error_kind=none|input|synthesis|playback|timeout|internal|cancelled
stage=input|synthesis|waiting|playback|complete
```

Python 原子发布结果；AHK 校验字段、请求归属及退出码，拒绝重复/缺失/矛盾结果。失败映射为固定中文通知，不透传异常原文。主动取消保持安静；过期任务不能清除新任务或覆盖新结果。文件不含选中文本。直接运行脚本时可省略这组内部参数。

## 用法

```powershell
# 安装后取得当前仓库独立宿主的绝对路径
$python = (python tools/tts/install-deps.py --check | ConvertFrom-Json).python
# 直接朗读文本
& $python tools/tts/tts_player.py --text "今天用 Windows 语音合成"

# 从 UTF-8 文件读取
& $python tools/tts/tts_player.py --input-file .\note.txt

# 指定配置文件
& $python tools/tts/tts_player.py --config .\tools\tts\config.toml --text "..."
```

## 本地语音的上下文诊断与恢复

2026-11-20 的对照：全局 Python 3.15 为 medium（RID 8192），其 PowerShell 子进程能用 SAPI 生成 WAV；模块虚拟环境 Python 为 low（RID 4096），SAPI 能枚举声音但无法合成，默认 TEMP 写入被拒绝。两者都不是 AppContainer 或 restricted token，且子进程均为 STA/FullLanguage。当前 3.15 环境还没有可用的旧 `winsdk`。这些是独立记录的环境限制，不应误报为没有安装任何声音。

`icacls` 进一步确认：仓库目录包含可继承的 `Low Mandatory Level:(OI)(CI)(NW)`；venv 的 python.exe/pythonw.exe 含继承的 Low 标签，全局解释器没有该标签。Windows 创建进程时取用户与可执行文件完整性的较低者，因此该 venv 会以 Low 运行；不是缺失声音、32/64 位不匹配或 PowerShell 语言模式问题。未修改文件标签、ACL 或尝试提权。机制参考 [Microsoft MIC 文档](https://learn.microsoft.com/en-us/windows/win32/secauthz/mandatory-integrity-control)。

```powershell
python tools/validation/process_context.py
tools/tts/.venv/Scripts/python.exe tools/validation/process_context.py
tools/tts/.venv/Scripts/python.exe tools/validation/integration_smoke.py tts
# 新用户目录宿主：真实离线合成，禁止在线调用，仅解码 WAV，不播放
$python = (python tools/tts/install-deps.py --check | ConvertFrom-Json).python
& $python tools/validation/process_context.py
& $python tools/validation/integration_smoke.py local-tts
```

2026-11-20 后续恢复：新用户目录宿主实测 medium/RID 8192，真实中英文 SAPI WAV、带参数/转义文本、`auto` 受管流水线全部通过，禁止在线调用时仍成功且 onlineCalls=0；实际 AHK 选择的新 pythonw 在必需 Job 内也通过，终态及请求清理正常。旧 Low 环境仍失败，WinRT 依赖仍不可用；恢复的是 SAPI 离线路径。联合探针的真实 Edge 与 SAPI 文件均通过，不等于新路径听感已验收。

依赖升级应重新验证真实合成，并重新生成带哈希的锁文件。参考 [上游 7.3.0 的协议修复](https://github.com/rany2/edge-tts/releases/tag/7.3.0)、[7.3.1 的日期解析修复](https://github.com/rany2/edge-tts/releases/tag/7.3.1)。

AHK 的“朗读选中文本”入口（`ahk/features/speak-selected-text.ahk`）会把选区写入临时文件，
再调用本脚本的 `--input-file`；本脚本不负责创建/删除该临时文件。输入文件接受带 BOM 或不带 BOM 的 UTF-8，BOM 不计入文本，只有 BOM/空白的受管请求按输入错误返回。

## 配置

默认读取同目录的 `tools/tts/config.toml`，字段说明（含可用音色）以该文件内的中文注释为准。

| 字段 | 说明 |
| --- | --- |
| `engine` | `auto` / `winrt` / `edge` |
| `zh_voice` / `en_voice` | 中英文音色名 |
| `rate` / `pitch` / `volume` | 语速 / 音调 / 音量，如 `+0%`、`+0Hz` |
| `concurrency` | 最大同时合成数，夹紧到 1–10 |
| `cache.max_size_mb` / `cache.max_files` | 缓存容量与文件数上限，超出后按 LRU 清理 |
| `log_text` | 文本日志开关，默认 `false`（隐私安全）；仅排查时显式改为 `true` |

## 日志与隐私

日志路径：`tools/tts/tts.log`（已被 `.gitignore` 忽略，属于本机用户数据）。

默认 `log_text = false` 时，日志只记录必要元数据：

- 字符数、切片数、中英文切片数；
- 引擎与音色名称、并发数；
- 每个切片的缓存命中/未命中、合成成功/失败、字符数与耗时；
- 退出状态；
- 错误类型 + 脱敏、截断后的错误消息（原文与切片替换为 `<text>`）。

默认日志**不会**写入输入原文或任何切片；底层库异常消息里若包含原文，也会先脱敏再记录。

只有显式设置 `log_text = true` 才会把原始文本/切片写入日志（完整调试信息）。此选项可能
把敏感内容落盘，仅应在本机临时排查时开启，排查后改回 `false`。

### 轮转

文件日志使用 `logging.handlers.RotatingFileHandler`：

- 追加模式（`mode="a"`），不会在启动时清空已有日志；
- 单文件上限 **1 MiB**，保留 **2** 个备份：`tts.log.1`、`tts.log.2`；
- 达到上限时旧文件被重命名轮转，当前日志内容不会被静默删除；只有超出备份数的
  最旧备份会在后续轮转中被覆盖；
- 上限是代码内置常量（`LOG_MAX_BYTES` / `LOG_BACKUP_COUNT`），不提供配置项，避免
  因配置失误导致日志无限增长；
- stdout 仍会同步输出日志（自检时看到的 warning 属于预期）。

自检与单元测试都使用临时日志路径，不会写入仓库内的 `tools/tts/tts.log`。

## 自检与测试

```powershell
# 内置自检：纯函数/文件系统检查，不合成、不播放、不联网
python tools/tts/tts_player.py --self-test

# 单元测试
python -m unittest discover -s tools/tts -p "test_*.py" -v

# 语法检查
python -m py_compile tools/tts/tts_player.py
```

自检会故意用非法配置触发夹紧 warning（`concurrency=99`、`max_size_mb=0`、`max_files=-3`），
这是预期输出。测试覆盖：默认日志不含原文但保留计数/音色元数据、`log_text=true` 显式包含原文、
错误消息默认脱敏、日志轮转上限与实际重命名、`load_config` 的 `log_text` 默认值与显式开关，
以及内置自检仍然通过。测试过程不执行合成或播放。
