# 安装、更新与回滚

以下命令均在目标仓库根目录运行。安装依赖、部署产物、注册任务是不同操作，按所需模块执行。日常检查可直接运行 `python tools/diagnostics/doctor.py`。

## 环境与首次安装

当前发布验证环境为 Windows x64、AutoHotkey v2、Python 3.11+、系统 Windows PowerShell 5.1；WinUI 源码构建使用 .NET 10 SDK，CI 固定为 10.0.404。RapidOCR 单独使用 Python 3.14 环境。新机器需先安装这些所需工具；首次构建会恢复 NuGet 包，Python 安装命令也需要网络。

```powershell
Get-Command AutoHotkey.exe, python.exe, dotnet.exe, powershell.exe
python --version
dotnet --list-sdks
```

配置文件保留本机设置。翻译无 pip 依赖：选择需要的引擎并按 [翻译配置](../tools/translate/README.md)设置凭证；默认云引擎缺密钥会报 `config`，不会自动联网改用免费引擎。诊断命令仅检查配置语法和引擎名，不验证凭证。

朗读使用独立且按仓库归属的用户目录环境：

```powershell
python tools/tts/install-deps.py
if ($LASTEXITCODE -ne 0) { throw 'TTS installation failed' }
python tools/tts/install-deps.py --check
```

依赖按 `requirements.lock` 的版本和哈希安装，不安装到全局 Python。`auto` 的本地 WinRT/SAPI 路径失败后会在线回退，向语音服务发送待朗读文本；显式 `engine = "winrt"` 保持离线。已有环境检查正常时无需重装。

需要 RapidOCR 或截图翻译时，在已安装 uv 的机器使用专用环境安装入口；已存在且版本/导入正常的环境不会重装：

```powershell
python tools/raycast-scripts/ocr/install-deps.py
python tools/raycast-scripts/ocr/install-deps.py --check
```

将 `tools/raycast-scripts/ocr/config.toml` 的 `ocr` 设为 `rapidocr` 后，独立 OCR 启动器优先使用该环境声明的同版基础 `pythonw.exe` 和原依赖目录。`system` 模式使用 Windows 截图文本操作，不需要这些模型依赖；截图翻译单独使用本地 RapidOCR，不改变该配置。OCR 全部依赖已有版本/SHA-256 锁，安装只管理模块 `.venv314`；全局 Python 3.15 不加载 cp314 依赖。`--mobile-models` 仅显式下载原有可选模型，不更改配置。

## 构建与验证

```powershell
# 离线行为检查；不启动生产常驻，不访问模型或设备
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ahk/tests/run-offline-tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'Offline checks failed' }

# 从当前源码构建隔离的 HUD test-out，再运行完整本机套件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ahk/tests/run-tests.ps1 -BuildImeHud
if ($LASTEXITCODE -ne 0) { throw 'Full checks failed' }
```

完整套件需要本机 AHK/SDK；`test-out` 不替换运行中的 `out`。远端 CI 还会独立编译 C# 锚点/音频助手，记录源码及产物来源。需要本机复现时使用 [助手构建入口](../tools/build/README.md)；该入口输出隔离候选，不会自动更新生产助手。

准备合并时，用干净候选 clone 再验证源码构建：

```powershell
python tools/validation/clean_checkout.py --full
if ($LASTEXITCODE -ne 0) { throw 'Clean candidate checks failed' }
```

它使用 HEAD 中的配置基线，排除本机模型、venv 和旧产物；保留报告和日志。它仍使用本机工具链和包缓存，不代表全新操作系统安装。验证范围见 [集成说明](../tools/validation/README.md)。

## 更新已有安装

更新前保存当前提交号和本机配置备份，备份放在忽略目录或仓库外，保留相对目录结构；不要把凭证写进发布说明或提交。源码更新后重新构建并验证，再执行：

```powershell
# 预览 HUD 产物差异，不停止实例
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Deploy-Toolbox.ps1 -PlanOnly
if ($LASTEXITCODE -ne 0) { throw 'Deployment preview failed' }

# 部署 HUD 差异并重载本仓库 AHK；无产物差异时仍读取新 AHK 源码
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Deploy-Toolbox.ps1 -ForceReload
if ($LASTEXITCODE -ne 0) { throw 'Deployment failed; inspect release evidence' }

python tools/diagnostics/doctor.py --json --output .tmp/diagnostics/after-update.json
```

保留部署输出的 `Release` 绝对路径及其中的 manifest/backup。发布操作只管理 HUD 产物和当前 checkout 的 AHK/HUD/光标助手；Python OCR、翻译、朗读下次调用读取新源码，不需要另起常驻。TTS 依赖锁变化时先执行安装/检查，再验收新请求。

PowerPolicy 源码或配置变化时，单独优雅重载已有任务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/power-policy/Restart-PowerPolicy.ps1
```

该命令使用现有任务，不重装。首次需要电源策略或看护任务时，在管理员终端分别运行 `tools/power-policy/Install-PowerPolicy.ps1`、`tools/startup/Install-ToolboxWatchdog.ps1`；电源安装会改变电源策略，非核心快捷键安装的必需步骤。登录快捷方式指向目标 checkout 的 `tools/startup/Toolbox-Launch.vbs`，具体说明见 [启动与部署](../tools/startup/README.md)。

## 回滚范围与步骤

| 对象 | 恢复方法 | 边界 |
| --- | --- | --- |
| HUD 部署产物 | 使用部署输出的 `Release` 路径 | 恢复该发布清单中的字节，并重载当前 AHK 源码 |
| AHK/Python/PowerPolicy 源码 | 审阅具体 Git 差异，应用修复提交或恢复已选定版本，再按模块重载 | HUD 回滚不会恢复源码；保留未提交改动与个人配置 |
| 个人 TOML/凭证 | 从本机配置备份恢复所需文件，再按模块重新读取 | 不在部署产物备份内 |
| 翻译/朗读窗口偏好 | 单独备份本仓库身份对应的 `preferences.json`；需要回到 TOML 时先关闭设置窗口，再将该文件改名保留 | 位于 LOCALAPPDATA，不在 HUD 产物备份中；旧源码忽略它，仓库移动后身份变化 |
| TTS Python 环境 | 使用所选源码版本的锁文件执行安装/检查 | HUD 回滚不回退包；旧 repo 环境保留但不会自动取代就绪的 profile 环境 |
| 电源设置/设备恢复记录 | 使用现有 PowerPolicy 恢复/卸载入口 | 不属于 HUD 回滚；设备不可用时保留未成功恢复的记录 |

```powershell
# 将示例路径替换为实际部署输出的 Release；不是 test-out 或其他仓库备份
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Deploy-Toolbox.ps1 `
  -RollbackRelease 'C:\path\to\repo\.tmp\releases\release-id'
python tools/diagnostics/doctor.py
```

部署失败会尝试恢复本次写入的产物。遇到其他写入导致的 `Automatic rollback conflict` 时会保留现场；先审阅当前差异与备份，再决定是否显式回滚。显式回滚会恢复所选备份，并额外保存回滚前字节。若原发布只重载、没有产物差异，清单为空，回滚它不能撤销源码更新。

## 合并与发布记录

每次候选记录：提交 SHA、相对 `main` 的完整范围、对应 SHA 的 CI、干净 clone 报告、基础使用验收及剩余专项矩阵。草稿 PR 不等于合并或正式发布；本仓库没有自动发布安装包的流程。

本轮候选见 [2026-11-22 文本工作流说明](releases/2026-11-22-text-workflow.md)，前一轮见 [2026-11-21 基础可靠性记录](releases/2026-11-21-reliability.md)。本机配置、偏好文件、运行日志、模型、依赖环境和 `.tmp` 证据不作为发布附件；自动化报告只记录必要元数据。分享诊断使用 `doctor.py --bundle <新 ZIP 路径>`；`--output` 的普通本地报告仍含路径/PID，不应当作脱敏附件。
