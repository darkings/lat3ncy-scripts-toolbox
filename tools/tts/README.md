# TTS Player（tools/tts）

`tts_player.py` 读取文本，按中英文语境切片，通过 WinRT 本地 OneCore 或 Edge Neural TTS
并发合成并即时播放；带 SHA256 缓存、LRU 容量清理与 Windows SAPI 本地兜底。

## 运行环境

- Windows 10/11。播放使用 `winmm` 的 MCI 接口，非 Windows 平台会跳过播放。
- Python 3.11+（使用标准库 `tomllib`；本仓库实测 Python 3.15）。
- 核心脚本只用标准库，不需要新增依赖。
- 合成引擎依赖为可选项：
  - WinRT 本地离线：`winsdk`；未安装或合成失败时，该片段走 SAPI 兜底朗读。
  - Edge 在线 Neural：`edge-tts`；未安装或合成失败时，该片段走 SAPI 兜底朗读。
    经过真实合成验证的版本为 `edge-tts==7.3.1`；7.2.8 在当前服务返回 HTTP 403。
- `python tools/tts/install-deps.py` 创建模块自己的 `.venv` 并按 `requirements.lock` 的版本及 SHA-256 安装；不会安装到全局 Python。`--check` 只检查该环境，不会把全局包当作已满足依赖。AHK 优先使用 `.venv\Scripts\pythonw.exe`，缺失时保留原有全局解释器回退。
- 缓存优先使用 `%LOCALAPPDATA%\lat3ncy-toolbox\tts-cache`；实际写入探针失败时使用本模块 `.cache`。两处都使用原有 LRU 上限，均不调整系统 ACL 或提权。

`auto` 模式先尝试指定本地音色；本地合成失败后使用 Edge 在线音色（中文 Xiaoxiao、英文 Aria），因此会发送待朗读文本到语音服务。该行为已于 2026-11-20 获用户明确授权。显式 `engine = "winrt"` 保持离线，不启用在线回退。在线结果以独立 MP3 缓存保存，不写入本地 WAV 缓存。

实际 MCI 或 SAPI 失败不会再记为播放成功；所有后备路径都失败时，进程返回非零退出码。

## 用法

```powershell
# 直接朗读文本
tools/tts/.venv/Scripts/python.exe tools/tts/tts_player.py --text "今天用 Windows 语音合成"

# 从 UTF-8 文件读取
tools/tts/.venv/Scripts/python.exe tools/tts/tts_player.py --input-file .\note.txt

# 指定配置文件
tools/tts/.venv/Scripts/python.exe tools/tts/tts_player.py --config .\tools\tts\config.toml --text "..."
```

## 本地语音的上下文诊断

2026-11-20 的对照：全局 Python 3.15 为 medium（RID 8192），其 PowerShell 子进程能用 SAPI 生成 WAV；模块虚拟环境 Python 为 low（RID 4096），SAPI 能枚举声音但无法合成，默认 TEMP 写入被拒绝。两者都不是 AppContainer 或 restricted token，且子进程均为 STA/FullLanguage。当前 3.15 环境还没有可用的旧 `winsdk`。这些是独立记录的环境限制，不应误报为没有安装任何声音。

```powershell
python tools/validation/process_context.py
tools/tts/.venv/Scripts/python.exe tools/validation/process_context.py
tools/tts/.venv/Scripts/python.exe tools/validation/integration_smoke.py tts
```

最后一条使用固定测试文本验证真实合成和 `auto` 回退，只解码文件时长，不播放声音；SAPI 不可用时总体报告仍为 partial。不能将在线恢复成功写成本地合成已修复，也不能将文件合成通过写成实际播放或听感已验收。

依赖升级应重新验证真实合成，并重新生成带哈希的锁文件。参考 [上游 7.3.0 的协议修复](https://github.com/rany2/edge-tts/releases/tag/7.3.0)、[7.3.1 的日期解析修复](https://github.com/rany2/edge-tts/releases/tag/7.3.1)。

AHK 的“朗读选中文本”入口（`ahk/features/speak-selected-text.ahk`）会把选区写入临时文件，
再调用本脚本的 `--input-file`；本脚本不负责创建/删除该临时文件。

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
