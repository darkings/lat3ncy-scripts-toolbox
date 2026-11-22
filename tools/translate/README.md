# translate

划词翻译的一次性 Python 后端。AHK 负责选区、翻译气泡和 Toast；本脚本只做「判方向 → 查缓存 → 请求引擎 → 写结果文件」，进程不驻留。

只使用 Python 标准库（`tomllib` / `urllib` / `hashlib` / `hmac`），无 pip 依赖。宿主入口是 `ahk/features/translate-selected-text.ahk`。

## 用法

### 统一设置与面板操作

在翻译面板“更多操作 → 翻译与朗读设置”，或 Raycast 的 **Toolbox Settings** 打开原生设置窗口。保存从下一次请求生效。设置只写 `%LOCALAPPDATA%\lat3ncy-toolbox\preferences\<仓库身份>\preferences.json` 的非敏感白名单；原有 TOML、环境变量密钥不复制或重写。窗口偏好优先于 TOML；仓库移动后使用新身份，其他路径的显式 CLI 配置保持隔离。

需要回到配置文件时，点 **预览 TOML 设置**（Alt+T）查看翻译与朗读的原配置值，缺失字段使用内置缺省值；此时尚未写入，点 **保存** 才恢复，点 **重新加载** 或关闭窗口可放弃。恢复会清除旧窗口偏好，让后续 TOML 修改生效；预览后手动调整的字段只保存与配置文件不同的值。密钥和个人 TOML 保持不变。另一窗口已保存，或预览后相关 TOML 字段发生变化时，拒绝覆盖并提示重新加载；恢复期间写入失败则保留旧偏好。

更多菜单还提供原文朗读、重试失败段和本次目标切换。目标切换不修改默认语言；重试沿用本次目标和原始锚点。译文播放按钮/Alt+R、原文菜单都可停止当前面板拥有的朗读，不会停止后来独立触发的 Caps+S。

腾讯鉴权失败且允许静默保底时，跨 one-shot 进程冷却 300 秒，继续用 Google，再由 MyMemory 末级保底。冷却到期、腾讯凭证或腾讯配置变化后，下次请求优先试腾讯；已有腾讯缓存仍可使用。状态文件只有身份摘要和截止时间，位于翻译缓存的 `state` 子目录，不含密钥或供应商错误。缺密钥直接按现有开关回退，严格鉴权模式忽略冷却。

### 长文

在设置中开启“允许长文分段翻译”，或 CLI 使用 `--long-text`；`--no-long-text` 仅对本次禁用。默认仍为短文上限 `max_chars=2000`，不静默截断。长文总上限 20000 字符、200 段、120 秒，按段落、句子和 UTF-8 字节拆分；Google 每片不超过 4000 字节，MyMemory 保底再按 480 字节拆分。

长文先交付 `status=progress`、`version=1`、`request_id`、`completed/total/failed`，终态为 `ok` 或 `partial`。`partial` 明确标记未完成及失败段，不当作完整译文启用朗读；可在面板重试补全，完成后复制完整译文。进度仅接受匹配请求号，AHK 硬上限 125 秒；关闭/换请求通过必需 Windows Job 取消父子进程。

CLI 可传 `--request-id <无文本编号>`、`--resume-file <本次临时 JSON>` 复用同一原文、目标、引擎和分段方案的已完成段。重试文件含译文，不含原文、凭证或异常，不能对外分享；CLI 调用者自行清理，AHK 面板在正常关闭、替换和退出时清理自己的文件。

AHK 的输入、结果、摘要和检查点放在 `%TEMP%\lat3ncy-translate-<仓库身份>\<PID>-<创建时间>-<随机编号>`，每个尝试有独立目录。当前面板保留检查点的独占 lease，重试时转移 lease，新尝试的输入/结果不会复用旧路径。即使旧回调迟到清理，也不能删除新输入或仍被重试持有的检查点。

启动及后续请求会有限扫描本仓库目录：仅在确认原进程已结束或 PID 创建时间不同、归属元数据匹配且 lease 无人在用时回收已知文件；不读正文，不跟随目录链接，不递归删除。在用、权限导致身份未知或文件锁未释放的目录会保留，等待后续检查。含陌生内容、异常元数据或超限的目录保留供人工检查。每次最多检查 64 项，100ms 入口预算，每目录最多 32 项；不是实时清理保证。目录句柄保护扫描期间的路径，文件删除失败不会伪报完成。

强杀/断电后的新格式遗留可在下一次启动或翻译请求回收。仓库路径或 TEMP 变化会使用新目录，不跨目录批量回收。旧版平铺 `lat3ncy-translate-in/out-*` 缺乏可靠 PID/创建时间归属，不自动批量删除。若分配未完成就中断，仅可能留下空目录或不完整元数据；正文只在归属与 lease 建立后写入。

### Google 与逐引擎诊断

显式检查 Google，仅发送内置的两段固定英文，不读取选区、配置密钥或缓存，不改变代理和 TLS 设置：

```powershell
python tools/translate/probe_google.py --online --output .tmp/google-check.json
```

没有 `--online`、超时参数不在 0.25–12 秒内或输出已存在时，在请求前拒绝。报告只含固定样本标签、字符/字节数、耗时、错误类别、是否配置代理等元数据，不输出译文、代理地址、请求 URL 或异常原文。两项均通过退出 0；部分成功标为 intermittent，全部失败标为 failed，退出 1。它只代表该次采样，不证明服务长期恢复；`--timeout` 是网络操作参数，不是整个探针的硬期限。

AHK 每次翻译附加 `--trace-file <结果路径>.trace` 与 `--request-id`。后端对腾讯/阿里/Google/MyMemory 分别记录调用、失败、缓存、跳过次数、累计耗时及固定原因（credentials/cooldown/auth/timeout/tls/http/network/response/too_long/internal）。`calls` 按每段向一个引擎的尝试计数，MyMemory 内部 HTTP 切片不另计。长文各段共享本次摘要，复用检查点不虚构新请求。

摘要只含白名单值，原子写入，诊断写失败不阻止译文交付；与结果正文协议独立，原成功/失败字段保持兼容。AHK 校验版本、请求号、大小和计数后才记日志，最终清理自己的摘要和临时文件。诊断路径不能与输入、结果、检查点或配置文件重合。CLI 单独使用时自行清理摘要文件。

Google 失败后即使 MyMemory 成功，`doctor.py` 仍能看到 Google 的独立 TLS/超时等失败；首个 `fallback_reason=credentials` 继续表达腾讯缺密钥，不覆盖其他引擎的实际错误。不会因此发成功回退通知。

```powershell
python tools/translate/translate.py `
  --text "hello" `
  --output-file "$env:TEMP\translate-out.txt" `
  --config tools/translate/config.toml
```

| 参数 | 说明 |
| --- | --- |
| `--text` | 直接传入待译文本 |
| `--input-file` | 从 UTF-8 文件读取；读取成功后尝试删除该文件。与 `--text` 同时给时文件优先 |
| `--output-file` | **必填**，结果写到该文件（key=value 协议） |
| `--config` | 配置文件路径；缺省用本目录的 `config.toml` |
| `--source-language` / `--target-language` | 只覆盖本次源／目标语言；不会写回配置。支持 `auto` / `zh` / `en` |
| `--self-test` | 离线自测：不联网、不读 HKCU、不写真实缓存 |

## 输出协议

AHK 按行解析 `key=value`。**`text` 永远最后一行开始，值里允许换行**；其它字段都压成单行。

成功：

```text
status=ok
direction=zh-en
engine=tencent
cached=0
text=译文（可含换行）
```

失败：

```text
status=error
code=too_long
message=文本过长（上限 2000 字符）
engine=tencent
detail=
length=2345
max_chars=2000
```

- `engine` 成功时是**实际使用**的引擎；失败时是配置里的首选引擎。
- 固定目标与有效源语言相同：`engine=identity`，`cached=0`，直接返回去除首尾空白的完整原文，不读凭证、不访问服务或缓存；长度上限仍适用。
- `cached=1` 时仍然报告缓存记录里产生译文的引擎。
- 回退成功会额外交付 `preferred_engine` 和 `fallback_reason`（`credentials` / `auth` / `timeout` / `network` / `too_long`）；原因来自本次请求，不存入译文缓存。未回退的成功协议保持原样，`text` 仍在最后。
- `detail` 是脱敏后的诊断串（异常类型 + 截断消息）；原文、密钥、`Authorization` / `q=` 参数都会打码。输入类错误（`empty` / `detect` / `too_long`）的 `detail` 为空。
- 写结果文件失败无法再回报协议，进程返回 1。

### 错误码

| code | 含义 |
| --- | --- |
| `auth` | 云厂商密钥/签名无效；默认报错，显式 `fallback_on_auth_error = true` 后可回退 Google |
| `config` | TOML 解析失败、配置节类型错、非法数值（`max_chars` / `timeout_s` / `cache.*` / `tencent.project_id`）、显式云引擎缺密钥 |
| `network` | 网络失败、HTTP/服务端错误、配额错误、响应格式异常 |
| `timeout` | 请求超时（含 `URLError(reason=TimeoutError)`） |
| `too_long` | 文本超过 `max_chars`，附 `length` / `max_chars` |
| `io` | 读取输入文件失败（不存在、权限、非 UTF-8） |
| `internal` | 未预期的内部异常；消息固定，不泄露原文/密钥 |
| `empty` / `detect` | 输入状态：没有可翻文字 / 无法判定中英方向（非异常分类） |

## 引擎与回退

顺序：首选引擎 → `google_gtx` → `mymemory`；首选是免费引擎时另一个免费引擎兜底。

| 情况 | 行为 |
| --- | --- |
| 显式配置 `tencent` / `aliyun`，但密钥为空 | 默认返回 `code=config`，提示「未配置…密钥」 |
| 同上，且 `fallback_without_credentials = true` | 跳过该云引擎，直接用 `google_gtx` / `mymemory` |
| 密钥已填但鉴权失败（`AuthError`） | 默认返回 `code=auth`；`fallback_on_auth_error = true` 时回退免费引擎 |
| 网络 / 超时 / 配额错误 | 回退免费引擎；成功时 `engine=` 是实际生效的免费引擎 |
| 免费引擎也失败 | 按最后一次失败类型返回 `network` / `timeout` |

免费引擎失败不会连累另一家云 MT：默认回退表里只有两家免费接口，避免另一家未配置的密钥把网络错误变成鉴权 Toast。

腾讯云优先、Google 保底可在配置顶层设置：

```toml
engine = "tencent"
fallback_without_credentials = true
fallback_on_auth_error = true
```

没有密钥时直接跳过腾讯云；密钥无效或签名失败时先尝试腾讯，再使用 Google，Google 不可用时沿用 MyMemory 末级回退。密钥恢复后下次请求自动优先腾讯，不会被旧 Google 缓存遮住。成功回退不发系统通知，不把腾讯错误放进译文；AHK 只记录固定引擎名和原因。全部引擎失败仍按现有错误路径处理。两个开关默认 false，已有配置不会被自动改写。

## 缓存

目录：`%LOCALAPPDATA%\lat3ncy-toolbox\translate-cache\`（测试里 monkeypatch `cache_dir` 即可换目录）。

- 键 = 实际引擎 + 方向 + 原文 + **影响输出的配置**：`tencent` 含 `endpoint` / `region` / `project_id`，`aliyun` 含 `endpoint`，免费引擎无附加项。切换引擎或改这些配置不会复用旧译文。
- 记录是 JSON：`{"version":2, "engine":"tencent", "direction":"zh-en", "translated":"..."}`。版本或引擎不匹配、空译文、损坏 JSON 一律视为未命中。
- 旧版 `.txt` 纯文本缓存**从不按新格式读取**；`prune_cache` 会顺带清理它们。
- 写入走「同目录临时文件 + `os.replace`」，并发读者只会看到旧文件或完整新文件；失败时清理临时文件。
- 读取规则：计划中的首选引擎先查缓存；回退引擎的缓存只在前面真的失败后才查。这样免费引擎的旧缓存不会遮住可用的付费引擎。
- 缓存是尽力而为：读/写失败不影响翻译结果。

## 长度限制

超过 `max_chars` 返回 `code=too_long`，**不截断、不做分段翻译**。边界严格：`len == max_chars` 正常翻译，`len == max_chars + 1` 报错。`length` 是去除首尾空白后的实际字符数。

## 配置

划词翻译（Caps+F）与截图翻译（Caps+I）共用本目录的 `config.toml`，每次请求读取，修改后无需重载 AHK。完整无密钥模板见 [config.example.toml](config.example.toml)；不要用模板覆盖已有凭证和个人设置。

把下面两项放在 `config.toml` 顶层（第一个 `[cache]` / `[tencent]` 等配置节之前）：

```toml
source_language = "auto"
target_language = "zh"
```

| 需要的行为 | source_language | target_language |
| --- | --- | --- |
| 原有中英自动互译（默认） | `auto` | `auto` |
| 固定译为中文；中文直接返回 | `auto` | `zh` |
| 固定译为英文；英文直接返回 | `auto` | `en` |
| 混合文本明确按英文译中文 | `en` | `zh` |
| 混合文本明确按中文译英文 | `zh` | `en` |

`source_language=auto` 沿用本地汉字／拉丁字母计数规则，不是多语言检测；`target_language=auto` 表示译为有效源语言的另一种语言。显式源语言优先于计数。当前只支持中英，`zh-CN` / `zh-Hans` 归一为 `zh`，大小写和两端空白会被规范化。日语等其他代码、非法类型或空值返回 `code=config`，不默默转换为英文。纯数字／符号仍返回 `detect`。

缓存继续按最终有效方向隔离：同一文本翻向不同语言不会混用，默认方向和等价的显式方向可复用旧缓存；`direction` 新增同语种 `zh-zh` / `en-en`，原有成功字段及 `text` 最后交付约定保持。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `engine` | `tencent` | 首选引擎；支持 `tmt` / `ali` / `google` 等别名 |
| `source_language` | `auto` | `auto` / `zh` / `en`；显式指定时覆盖中英计数判定 |
| `target_language` | `auto` | `auto` 自动互译，或固定 `zh` / `en` |
| `fallback_without_credentials` | `false` | 缺密钥时是否允许回退免费引擎 |
| `fallback_on_auth_error` | `false` | 鉴权失败时是否回退 Google；成功回退仅记诊断，不发通知 |
| `timeout_s` | `4` | 单次请求超时（>0 的有限数） |
| `max_chars` | `2000` | 超过即 `too_long`（正整数） |
| `cache.max_size_mb` | `10` | 缓存目录上限 |
| `cache.max_files` | `500` | 缓存文件数上限 |
| `tencent.*` | 见 `config.toml` | `endpoint` / `region` / `project_id` |
| `aliyun.*` | 见 `config.toml` | `endpoint` |

非法数值不会被夹紧或默默改成默认值，直接 `code=config`。

## 密钥

按「进程环境 → HKCU\Environment → config.toml」读取，不写日志：

- 腾讯云：`TENCENTCLOUD_SECRET_ID` / `TENCENTCLOUD_SECRET_KEY`，兼容 `TENCENT_*`、`QCLOUD_*`
- 阿里云：`ALIBABA_CLOUD_ACCESS_KEY_ID` / `ALIBABA_CLOUD_ACCESS_KEY_SECRET`，兼容 `ALIYUN_*`、`ALIBABA_*`

仓库里的 `config.toml` 不应出现真实密钥。

## 测试

```powershell
python -m unittest discover -s tools/translate -p "test_*.py" -v
python tools/translate/translate.py --self-test
python -m py_compile tools/translate/translate.py tools/translate/test_translate.py
```

`test_translate.py` 全部使用 stub 引擎、mock 的 `http_json` 和临时缓存目录（默认在仓库 `.lat3ncy-tools-tmp` 下），不发网络请求、不读 HKCU、不使用真实密钥。

## 取消与正常退出

AHK 翻译后端必须绑定 Windows Job，绑定失败时不放行挂起的工作进程。普通取消让请求编号失效，并由定时器等待进程停止后删除任务文件。

首次启动任务即注册退出清理，工作流关闭也会调用相同的幂等清理。正常退出／重载时先停止结果定时器、拒绝新请求、取消所有在途任务；轮询与文件重试共用 1.5 秒预算，随后强制释放剩余 Job 句柄，并只清理该批任务已知的输入／结果文件，不显示结果或发退出通知。日志仅记录任务数和 `cleanup=complete/incomplete`。

这覆盖正常退出与重载，不承诺断电、强制结束进程或外部文件锁下必然完成删除；未能清理时记录 incomplete。AHK 全量套件使用持有输入文件句柄且带子进程的固定后端，验证退出、取消、重复关闭、拒绝迟到任务、预算耗尽后的释放及任务文件回收，无网络、桌面或声音操作。
