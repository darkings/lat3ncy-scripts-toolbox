# 干净候选与真实集成验证

```powershell
# 不读取现有 out/obj/venv；个人 config.toml 改动使用 HEAD 中的版本替代
python tools/validation/clean_checkout.py --full
# 对照两个解释器的实际令牌完整性及 TEMP 写入能力，不提权、不改 ACL
python tools/validation/process_context.py
tools/tts/.venv/Scripts/python.exe tools/validation/process_context.py
# 真实 OCR 模型：只读取合成文字图片；剪贴板交付被捕获，不改实际剪贴板
tools/raycast-scripts/ocr/.venv314/Scripts/python.exe tools/validation/integration_smoke.py ocr
# 真实 TTS：固定测试文本，在线合成/auto 回退及本地 WAV 探针；不播放
tools/tts/.venv/Scripts/python.exe tools/validation/integration_smoke.py tts
# 显式执行真实 MCI 播放/中断探针：使用静音 PCM，不朗读或改变音量
tools/tts/.venv/Scripts/python.exe tools/validation/integration_smoke.py playback
```

`clean_checkout.py` 从当前候选源码导出快照，在忽略目录创建独立 Git 仓库并做一次本地 clone，路径包含空格。它不修改原仓库的 index、分支、提交或 remote；源码可包含当前未提交修改，配置使用 HEAD 基线，未跟踪的个人配置跳过。文件清单、来源哈希、每阶段日志及 report.json 保留在输出目录。

默认验证离线套件与两个 C# 助手编译。`--full` 额外从源码构建 WinUI 并执行 AHK 全量套件。明确排除 `.tmp`、venv、bin/obj/out/test-out/dist 和运行日志，避免复用已有生产产物。子进程使用 Windows PowerShell 5.1 的系统模块路径，避免继承 PS7/Codex 模块。

这是本机新 clone 验证，仍使用本机已安装的 SDK、AHK、Python 及 NuGet 缓存；不是干净操作系统或远端 CI 的替代品。远端 workflow 分为 offline 和 winui 两个任务；WinUI 使用独立构建入口及已验证的 .NET 10.0.404。

`integration_smoke.py` 是显式执行的集成探针，不在离线 CI 自动运行。OCR 需要已安装的 RapidOCR/Pillow；TTS 需要模块锁定环境和网络。记录 passed/failed/partial，不会安装模型、切换音频、播放声音、操作用户桌面或改变电源/设备连接状态。

`playback` 是单独的可选例外：真实调用 MCI 播放静音 WAV，验证正常完成以及播放中的进程取消，不朗读文字或改变音量/默认端点。TTS 探针还运行真实任务编排和终态协议，设备播放边界由文件解码器替代；其通过不等于听感验收。AHK 本机套件另覆盖实际父子进程取消、句柄关闭、归属校验及残片清理。

当前已验证真实 OCR 文字/空白图片、TTS 在线恢复、静音 MCI 播放/中断以及受管 Python 请求的错误交付；本地低完整性 SAPI 限制如实保留为失败。UIA、多屏/DPI、真实剪贴板、朗读听感与连续快捷键打断、合盖/睡眠及设备断连仍按 `tools/startup/README.md` 的矩阵执行。
