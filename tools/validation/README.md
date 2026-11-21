# 干净候选与真实集成验证

日常故障先运行 `python tools/diagnostics/doctor.py`，统一检查常驻身份、配置语法、解释器和依赖元数据，并定位日志；完整边界见 [诊断说明](../diagnostics/README.md)。它不替代下列集成测试。

2026-11-21 用户反馈 OCR、翻译及朗读基础使用均正常，基础使用验收已确认。下文 2026-11-20 的工具阻塞和听感未确认是历史记录；未获逐项确认的异常路径、多屏、物理设备及自动保护探针保留各自状态。

```powershell
# 不读取现有 out/obj/venv；个人 config.toml 改动使用 HEAD 中的版本替代
python tools/validation/clean_checkout.py --full
# 对照两个解释器的实际令牌完整性及 TEMP 写入能力，不提权、不改 ACL
python tools/validation/process_context.py
tools/tts/.venv/Scripts/python.exe tools/validation/process_context.py
# 真实 OCR 模型：只读取合成文字图片；剪贴板交付被捕获，不改实际剪贴板
tools/raycast-scripts/ocr/.venv314/Scripts/python.exe tools/validation/integration_smoke.py ocr
# 真实 TTS：固定测试文本，在线合成/auto 回退及本地 WAV 探针；不播放
$python = (python tools/tts/install-deps.py --check | ConvertFrom-Json).python
& $python tools/validation/integration_smoke.py tts
# 仅本地：真实中英文 SAPI WAV、SSML 转义/参数、禁止在线的 auto 流水线
& $python tools/validation/integration_smoke.py local-tts
# 显式执行真实 MCI 播放/中断探针：使用静音 PCM，不朗读或改变音量
& $python tools/validation/integration_smoke.py playback
```

`clean_checkout.py` 从当前候选源码导出快照，在忽略目录创建独立 Git 仓库并做一次本地 clone，路径包含空格。它不修改原仓库的 index、分支、提交或 remote；源码可包含当前未提交修改，配置使用 HEAD 基线，未跟踪的个人配置跳过。文件清单、来源哈希、每阶段日志及 report.json 保留在输出目录。

默认验证离线套件与两个 C# 助手编译。`--full` 额外从源码构建 WinUI 并执行 AHK 全量套件。明确排除 `.tmp`、venv、bin/obj/out/test-out/dist 和运行日志，避免复用已有生产产物。子进程使用 Windows PowerShell 5.1 的系统模块路径，避免继承 PS7/Codex 模块。

这是本机新 clone 验证，仍使用本机已安装的 SDK、AHK、Python 及 NuGet 缓存；不是干净操作系统或远端 CI 的替代品。远端 workflow 分为 offline 和 winui 两个任务；WinUI 使用独立构建入口及已验证的 .NET 10.0.404。

`integration_smoke.py` 是显式执行的集成探针，不在离线 CI 自动运行。OCR 需要已安装的 RapidOCR/Pillow；`tts` 需要锁定环境和网络，`local-tts` 禁止在线边界、要求当前上下文的 SAPI 可用。记录 passed/failed/partial，不会安装模型、切换音频、操作用户桌面或改变电源/设备连接状态。`ocr-clipboard` 是下文单独提供保护入口的真实剪贴板例外；`playback` 是静音播放例外。

`playback` 是单独的可选例外：真实调用 MCI 播放静音 WAV，验证正常完成以及播放中的进程取消，不朗读文字或改变音量/默认端点。TTS 探针还运行真实任务编排和终态协议，设备播放边界由文件解码器替代；其通过不等于听感验收。AHK 本机套件另覆盖实际父子进程取消、句柄关闭、归属校验及残片清理。

当前已验证真实 OCR 文字/空白图片、TTS 在线恢复、MCI 播放/连续替换以及受管 Python 请求的错误交付，面板协议的真实剪贴板探针见下文；本地低完整性 SAPI 限制如实保留为失败。UIA、多屏/DPI、跨应用交付、朗读听感、合盖/睡眠及设备断连仍按 `tools/startup/README.md` 的矩阵执行。

2026-11-20 本地语音增量：按仓库隔离的用户目录环境为 medium/RID 8192，中英文 SAPI WAV、SSML 参数及转义、禁止在线的实际 auto 流水线通过；AHK 实际选择该 pythonw 并在必需 Job 内完成本地合成、终态与清理，onlineCalls=0。联合探针的 Edge 与 SAPI 文件均通过。恢复的是新宿主上的 SAPI 路径，旧 Low 环境和缺失的 WinRT 依赖保持原样；新路径听感仍待确认。证据 `.tmp/integration/20261120-local-host/`，干净 clone 构建/全量测试 `.tmp/validation/20261120-local-host/`。

## 可见选区与真实剪贴板探针

`desktop-fixture.ahk` 是显式执行的桌面验收入口，不加入 CI。先创建证据目录，再用本机 AHK v2 引擎运行：

```powershell
New-Item -ItemType Directory -Force .tmp/integration/desktop | Out-Null
$ahk = 'C:\path\to\v2\AutoHotkey64.exe' # 替换为已安装的 v2 引擎路径
& $ahk /ErrorStdOut tools/validation/desktop-fixture.ahk .tmp/integration/desktop/fixture.log
# 另一种模式：通过现有面板协议测试真实剪贴板，不需要操作工具窗口
& $ahk /ErrorStdOut tools/validation/desktop-fixture.ahk --protocol-smoke .tmp/integration/desktop/panel.log
```

可见模式只创建带固定中英文文本的只读编辑框，不注入按键或自动调用语音服务。点击文本框、Ctrl+A，再连续触发真实常驻 Caps+S；结合任务日志、进程与文件清理验证替换/最终完成，点击“检查剪贴板是否恢复”比较完整 ClipboardAll 的字节。用户需另行确认声音和听感。

长译文为 7397 个 UTF-16 代码单元，包含 emoji、竖线、CRLF 和末尾标记。可点“打开长译文测试面板”、实际复制按钮，再点“校验面板复制完整性”。`--protocol-smoke` 则通过现有 `PANEL|COPY|result` 调用同一个生产剪贴板写入路径，验证完整复制、空占位保留剪贴板、关闭后迟到结果不重开；**这不代表按钮命中、翻译后端或跨应用选区已验收**。该模式要求当前仓库 HUD 已运行，会替换并最终关闭当前面板。

探针只在内存保存原 ClipboardAll，日志仅记录布尔值和长度；正常结束时仅在剪贴板仍为本探针已知内容时恢复，避免覆盖期间无关的新复制内容。请正常退出可见窗口，强制结束无法执行恢复回调。

2026-11-20 在单屏、HUD DPI 192 的环境实测：真实 Caps+S 连续三轮，前两轮播放中被替换且进程退出，第三轮两段 MCI 播放正常完成；任务目录/残片无遗留，完整剪贴板恢复通过。上述三个协议探针均通过，证据 `.tmp/integration/20261120-desktop/`。多屏、浏览器/终端选区、复制按钮点击和听感仍待验收。

## OCR 真实剪贴板交付

从仓库根目录运行，要求已有 `tools/raycast-scripts/ocr/.venv314` 及模型。使用 AHK v2 保护入口，不能直接运行 Python 的 `ocr-clipboard` 模式：

```powershell
New-Item -ItemType Directory -Force .tmp/integration/desktop | Out-Null
$ahk = 'C:\path\to\v2\AutoHotkey64.exe'
$fixture = (Resolve-Path tools/validation/desktop-fixture.ahk).Path
$log = Join-Path (Resolve-Path .tmp/integration/desktop).Path 'ocr.log'
$run = Start-Process -FilePath $ahk -ArgumentList @('/ErrorStdOut',('"'+$fixture+'"'),'--ocr-clipboard-smoke',('"'+$log+'"')) -WindowStyle Hidden -Wait -PassThru
$run.ExitCode
Get-Content $log
```

父进程仅在内存保存 ClipboardAll，工作进程绑定必需 Job、总预算 90 秒。工作进程在生产轮询函数取得序列号基线后，把生成的固定 DIB 图片写入真实剪贴板，由真实 RapidOCR 和生产复制函数交付文本；记录序列号归属，不存原剪贴板。实际图片必须与固定图像的像素一致才交给模型，复制前还核对归属。正常结束时只有当前序列号仍属于探针才恢复完整 ClipboardAll；无关的新复制保留并报告恢复未确认。这里的序列号检查不承诺跨进程原子事务。

探针验证图片→文本、空白不覆盖、无新图片时取消不覆盖、完成通知函数在复制之后触发。通知边界用观察器代替实际 Toast，**不代表系统 Toast 展示、截图框选或 Raycast detached 入口已验收**。直接运行普通 `ocr` 探针仍不改剪贴板。DIB 内存只在成功 `SetClipboardData` 后交给系统；失败路径释放内存和隐藏 owner 窗口。[Windows 剪贴板内存约定](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-operations)。

2026-11-20 首次实测发现成功通知先于复制，`completionAfterCopy=false`；修复后所有子项与 ClipboardAll 恢复通过，Job/进程句柄已关闭。证据 `.tmp/integration/20261120-browser-ocr/ocr-guarded-final.log` 及该日志指向的 `report.json`。

`browser-fixture.html` 仅提供手工可重复的固定中英文、换行、竖线和 emoji 选区，不访问网络或读取剪贴板。此前浏览器控制接口超时，Windows Computer Use 随后因无法可靠确认当前 URL 而停止；浏览器选区/锚点验收仍待执行，没有用 OCR 或静态页面测试代替。

## OCR 宿主与通知提交

2026-11-20 进一步对照：旧 `.venv314` 的 Low/RID 4096 上下文在 `CreateToastNotifier` 返回 `0x80073D54`；同版本基础解释器的 Medium/RID 8192 上下文能够提交并读回测试 Toast。没有修改通知权限、包注册或文件 ACL。

RapidOCR 启动器现在优先读取 `.venv314/pyvenv.cfg` 的基础 Python，使用 `-I -S ocr_host.py`，只加载原环境 `Lib/site-packages`，不重装依赖。宿主验证主次版本、基础目录和隔离标志后才加载二进制依赖；宿主声明/文件不可用时保留旧 venv、全局解释器回退。系统 OCR 分支不使用这个宿主。启动期版本/基础目录不匹配会退出并写 `ERROR:` 诊断，不尝试混用 ABI。

```powershell
. ./tools/raycast-scripts/ocr/OcrHost.ps1
$spec = Get-OcrLaunchSpec (Join-Path (Get-Location) 'tools/raycast-scripts/ocr')
$python = Join-Path (Split-Path $spec.Python -Parent) 'python.exe'
& $python -I -S tools/raycast-scripts/ocr/ocr_host.py --check
& $python -I -S tools/validation/integration_smoke.py ocr --ocr-host
& $python -I -S tools/validation/integration_smoke.py ocr-notify --ocr-host
```

`ocr-notify` 真实运行 OCR 的通知 runner，检查同步/异步、中文/emoji/引号/换行、异常以及 10 秒超时后的进程退出和文件清理；接收端用固定脚本观测数据，不在这些场景弹 Toast。随后独立调用真实 Windows 通知 API，用唯一 tag/group、抑制横幅的固定测试通知验证历史记录，并仅删除自己的测试记录。这是系统提交验收，**不等于横幅展示、真实 Raycast 调度或截图框选验收**。[ToastNotificationManager API](https://learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.toastnotificationmanager)。

同版基础 `python.exe/pythonw.exe` 的真实模型及通知探针均通过；无窗口宿主确认 RID=8192，临时 runner 全部清理。证据 `.tmp/integration/20261120-ocr-notify/windowless-notify/report.json`、`host-model/report.json`。新宿主的完整剪贴板复测本轮未执行成功：原 ClipboardAll 备份失败，原生 `OpenClipboard` 返回拒绝访问，保护入口在写入前退出。既有旧宿主成功证据不替代这次待复测项。

剪贴板保护入口现在对备份作约 2 秒的有界重试，失败记录元数据并退出，避免后台错误对话框无限等待。接口访问恢复后再运行 `--ocr-clipboard-smoke`；浏览器控制接口仍超时，Maestro 列出的 Chromium 未连接，因此浏览器验收继续待办。
