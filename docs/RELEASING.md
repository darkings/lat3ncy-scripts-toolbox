# 安装、更新与回滚

以下命令均在目标仓库根目录运行。安装依赖、部署产物、注册任务是不同操作，按所需模块执行。日常检查可直接运行 `python tools/diagnostics/doctor.py`。

已有配置可以从 [工具箱设置中心](../tools/settings/README.md) 统一管理：Raycast Toolbox Settings 或翻译面板的工具箱设置。基础翻译/朗读偏好独立保存，其他分类编辑对应 TOML 的白名单字段；原凭证和未修改内容保留。保存各页只更新配置，系统/硬件模块按页面注明的既有入口应用。更新前仍需自行保留本机配置备份，不能用 HUD 产物回滚代替配置恢复。

## 环境与首次安装

当前发布验证环境为 Windows x64、AutoHotkey v2、Python 3.11+、系统 Windows PowerShell 5.1；WinUI 源码构建使用 .NET 10 SDK，CI 固定为 10.0.404。RapidOCR 单独使用 Python 3.14 环境。新机器需先安装这些所需工具；首次构建会恢复 NuGet 包，Python 安装命令也需要网络。

```powershell
Get-Command AutoHotkey.exe, python.exe, dotnet.exe, powershell.exe
python --version
dotnet --list-sdks
```

翻译无需安装 Python 包。在翻译设置中选择引擎、填写密钥；需要 Google 保底时，开启缺密钥和鉴权失败回退。两个开关默认关闭，已有个人配置保持原值；独立 CLI 也按其配置执行。成功保底不发送系统通知。详见[翻译配置](../tools/translate/README.md)。离线诊断不验证云端密钥。

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

## 首次启动工具箱

准备好所需环境后，在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Rebuild-ToolboxHud.ps1
```

该入口构建并验证 HUD 与 anchor，部署后启动本仓库 AHK，并检查运行状态。以后的普通启动使用 `tools/startup/Start-Toolbox.ps1`。电源、主题计划、灯光服务按需单独安装，见各模块 README。

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

先保留本机配置和当前提交号，更新源码后运行相应检查。需要重建界面或锚点时：

```powershell
# 构建和验证候选，仅预览差异，当前实例继续运行
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Rebuild-ToolboxHud.ps1 -PlanOnly

# 重新构建、备份并部署 HUD + anchor，重载后检查运行状态
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Rebuild-ToolboxHud.ps1

python tools/diagnostics/doctor.py
```

Raycast 的 **Reload IME HUD** 使用同一流程。构建失败保留当前运行实例；替换或健康检查失败时尝试恢复本次写入。候选、日志和备份位于 Git 忽略的 `.tmp/`，保留部署输出中的 `Release` 路径。

已有经过完整检查的 `test-out` 时，也可用原 `Deploy-Toolbox.ps1` 仅发布 HUD。只需重新加载 AHK 源码时，可在相同前提下加 `-ForceReload`。两种发布方式的备份范围不同，回滚时按下一节区分。

Python OCR、翻译和朗读在下次调用时读取新源码。TTS 或 OCR 依赖锁变化时，重新执行对应安装入口及 `--check`。

PowerPolicy 源码或配置变化时，单独优雅重载已有任务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/power-policy/Restart-PowerPolicy.ps1
```

该命令使用现有任务，不重装。首次需要电源策略或看护任务时，在管理员终端分别运行 `tools/power-policy/Install-PowerPolicy.ps1`、`tools/startup/Install-ToolboxWatchdog.ps1`；电源安装会改变电源策略，非核心快捷键安装的必需步骤。登录快捷方式指向目标 checkout 的 `tools/startup/Toolbox-Launch.vbs`，具体说明见 [启动与部署](../tools/startup/README.md)。

## 回滚范围与步骤

| 对象 | 恢复方法 | 边界 |
| --- | --- | --- |
| 单独 HUD 发布 | `Deploy-Toolbox.ps1 -RollbackRelease`，使用其输出的 Release 路径 | 仅接受目标为 HUD out 的原发布记录 |
| HUD＋anchor 复合发布 | 替换或健康检查失败时自动恢复本次写入；保留复合发布记录供审阅 | 不能传给旧的单目录回滚入口；手动恢复入口见后续计划 |
| AHK/Python/PowerPolicy 源码 | 审阅具体 Git 差异，应用修复提交或恢复已选定版本，再按模块重载 | HUD 回滚不会恢复源码；保留未提交改动与个人配置 |
| 个人 TOML/凭证 | 从本机配置备份恢复所需文件，再按模块重新读取 | 不在部署产物备份内 |
| 设置和偏好 | 在设置页点击“默认”恢复该页；完整恢复使用本机配置备份 | 偏好在 `.toolbox-state/`，开关/键位在 `.toolbox-controls.json`，模块配置在各 TOML；恢复默认保留厂商密钥 |
| TTS Python 环境 | 使用所选源码版本的锁文件执行安装/检查 | HUD 回滚不回退包；旧 repo 环境保留但不会自动取代就绪的 profile 环境 |
| 电源设置/设备恢复记录 | 使用现有 PowerPolicy 恢复/卸载入口 | 不属于 HUD 回滚；设备不可用时保留未成功恢复的记录 |

复合发布（HUD＋anchor）不能交给旧的单目录回滚入口。使用专用入口列出、预览并恢复批次：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Restore-ToolboxHudRelease.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Restore-ToolboxHudRelease.ps1 -Preview '<release>'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Restore-ToolboxHudRelease.ps1 -RollbackRelease '<release>'
```

列表显示批次、创建时间、状态、HUD/anchor 源码指纹与备份完整性；预览按文件给出恢复动作与冲突。存在后来写入时回滚被拒绝并保留现场；实际回滚先保存当前字节，失败时恢复，成功也不改写原批次记录。

```powershell
# 仅用于 Deploy-Toolbox 的单独 HUD 发布记录，不接受 hud-* 复合发布记录
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Deploy-Toolbox.ps1 `
  -RollbackRelease 'C:\path\to\repo\.tmp\releases\release-id'
python tools/diagnostics/doctor.py
```

部署失败会尝试恢复本次写入的产物。遇到其他写入导致的 `Automatic rollback conflict` 时会保留现场；先审阅当前差异与备份，再决定是否显式回滚。原单目录入口的显式回滚会恢复所选备份，并额外保存回滚前字节。若原发布只重载、没有产物差异，清单为空，回滚它不能撤销源码更新。

## 合并与发布记录

每次候选记录：提交 SHA、相对 `main` 的完整范围、对应 SHA 的 CI、干净 clone 报告、基础使用验收及剩余专项矩阵。草稿 PR 不等于合并或正式发布；本仓库没有自动发布安装包的流程。

当前更新见 [2026-11-24 工具箱更新](releases/2026-11-24-toolbox.md)，后续方向见[更新计划](ROADMAP.md)。[文本工作流](releases/2026-11-22-text-workflow.md)和[基础可靠性](releases/2026-11-21-reliability.md)作为历史记录保留。本机配置、偏好文件、运行日志、模型、依赖环境和 `.tmp` 证据不作为发布附件；自动化报告只记录必要元数据。分享诊断使用 `doctor.py --bundle <新 ZIP 路径>`；`--output` 的普通本地报告仍含路径/PID，不应当作脱敏附件。

## 配置备份与迁移

非敏感设置可通过专用桥接导出为 JSON 备份，导入前先预览：

```powershell
python tools/toolbox_config_transfer.py --export > .tmp\settings-backup.json
python tools/toolbox_config_transfer.py --preview .tmp\settings-backup.json
python tools/toolbox_config_transfer.py --apply .tmp\settings-backup.json
```

导出只包含 `configuration_schema.py` 白名单字段、校验过的翻译/朗读偏好和非敏感功能开关/键位；任何疑似密钥字段、凭证文件、原始 TOML 与日志都不进入备份。预览逐项显示当前值与拟写入值，列出只读/未知字段的跳过说明，并检查备份后是否发生写入（revision 冲突）或键位冲突；存在冲突时不写入任何文件。旧版 `version = 0` 的分段字段列表会在读取时迁移到当前格式。

导入按模块逐个保存并保留各文件原有的编码与注释；它不是多文件原子事务，中途失败会报告已完成的部分。恢复密钥、连接目标和凭证仍使用各自本机备份入口，不能用本备份代替。

## 提交范围

- **保留在仓库**：源码、配置模板、依赖锁、许可证、必要资源、使用指南和整理后的发布记录。
- **只留本机**：密钥、连接目标、个人配置改动、运行日志、测试截图、诊断包、候选/备份、虚拟环境及会话任务/进度/研究笔记。
- `findings.md`、`progress.md`、`task_plan.md` 和机器验收笔记不再跟踪，已有本地文件保留。公共后续计划集中在 `docs/ROADMAP.md`。
- `.gitignore` 只影响未跟踪文件。已有配置模板的个人改动需要逐文件审阅，不能通过添加一条忽略规则隐藏；本机填入的密钥不要暂存。
- 当前跟踪的三个运行助手 exe 仍由现有启动/测试流程使用，保留兼容基线；重新构建产生的本机字节差异不自动提交。HUD、PyInstaller 和其他构建目录继续忽略。
