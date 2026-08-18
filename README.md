# lat3ncy-scripts-toolbox

一组面向 Windows 的生产力脚本，包括模块化 AutoHotkey v2 快捷键和屏幕区域 OCR 工具。

## AutoHotkey

安装 [AutoHotkey v2](https://www.autohotkey.com/)。安装程序建立 `.ahk` 文件关联后，可以直接双击 `ahk/main.ahk` 运行；也可以右键该文件并选择 AutoHotkey v2。

如果要从命令行运行，或使用本仓库的测试 runner，`AutoHotkey.exe` 必须能通过 `PATH` 解析。先验证：

```powershell
Get-Command AutoHotkey.exe
```

命令有结果后，才可运行：

```powershell
AutoHotkey.exe .\ahk\main.ahk
```

如果 `Get-Command` 没有结果，请把 AutoHotkey v2 的安装目录加入 `PATH`，或使用能提供 `AutoHotkey.exe` shim 的包管理器安装方式，然后重开终端验证。

也可以为 `ahk/main.ahk` 创建快捷方式并放入 Windows 启动文件夹（`Win+R` 后输入 `shell:startup`），让工具箱登录后自动运行。

- 在 `ahk/main.ahk` 中注释或取消注释某个 feature 的 `#Include` 行，可以单独停用或启用该功能。
- 只在 `ahk/shortcuts.ahk` 中修改快捷键，不要编辑 feature 文件中的注册代码。
- 如果两个已启用功能使用了相同快捷键，脚本会在启动时报错，避免其中一个功能被静默覆盖。

### 默认快捷键

| 快捷键 | 功能 | Feature 文件 |
| --- | --- | --- |
| `CapsLock`（`$CapsLock`） | 短按切换输入法，长按启用大写 | `ahk/features/caps-lock-ime.ahk` |
| `Ctrl+Win+T`（`^#t`） | 切换活动窗口置顶 | `ahk/features/always-on-top.ahk` |
| `Ctrl+Shift+G`（`^+g`） | 使用 Google 搜索选中文字 | `ahk/features/search-selected-text.ahk` |
| `Ctrl+V`（`$^v`） | 仅图片时介入：保存到资源管理器当前目录，或 VS Code / Zed 文件树选中的单个已存在目录；资源管理器虚拟位置显示提示，其他情况原生粘贴 | `ahk/features/smart-paste/smart-paste.ahk` |
| `Ctrl+Alt+O`（`^!o`） | 打开选中的文件、目录或 URL | `ahk/features/open-selected-target.ahk` |
| `Ctrl+Alt+E`（`^!e`） | 在资源管理器中定位选中的文件或目录 | `ahk/features/locate-selected-target.ahk` |
| `Win+Shift+.`（`#+.`） | 显示或隐藏资源管理器中的隐藏文件 | `ahk/features/toggle-hidden-files.ahk` |
| `Alt+反引号`（`!sc029`） | 按当前 Z-order 快照循环切换同一应用窗口 | `ahk/features/switch-app-window.ahk` |
| `Alt+Shift+反引号`（`+!sc029`） | 沿快照反向切换同一应用窗口 | `ahk/features/switch-app-window.ahk` |

同应用窗口切换在第一次触发时保存窗口顺序，按住 `Alt` 连续按反引号即可完整循环；松开 `Alt` 后清除快照。最小化、不可见、工具型以及被系统隐藏的窗口不会进入候选列表。Zed 只有一个可见顶层窗口时，快捷键会通过 `F13` / `F14` 桥接到 Zed 的 `multi_workspace::NextProject` / `multi_workspace::PreviousProject`，循环切换同一窗口中的项目。

### Smart Paste 路由

`Ctrl+V` 仅在剪贴板包含图片时可能介入；资源管理器虚拟位置也会介入并显示无法保存提示。下表按从上到下的顺序优先匹配：

| 剪贴板内容 | 活动窗口 | 行为 |
| --- | --- | --- |
| 已复制的文件或目录（即使同时包含图片格式） | 任意 | 优先执行原生 `Ctrl+V` |
| 非图片内容 | 任意 | 原生 `Ctrl+V` |
| 图片 | 普通文件系统目录的资源管理器 | 保存为不会覆盖已有文件的唯一命名 PNG |
| 图片 | 资源管理器虚拟位置 | 显示无法保存提示，不发送原生粘贴 |
| 图片 | VS Code / Zed 文件树选中的单个已存在文件夹 | 保存为不会覆盖已有文件的唯一命名 PNG |
| 图片 | VS Code / Zed 编辑器聚焦且当前打开文件存在（文件树探测失败后） | 保存为当前文件所在目录下不会覆盖已有文件的唯一命名 PNG |
| 图片 | VS Code / Zed 选中文件、多选、编辑器无打开文件、路径探测超时或快捷键不一致 | 显示提示并恢复原剪贴板后执行原生 `Ctrl+V` |
| 图片 | 其他应用 | 原生 `Ctrl+V` |

VS Code 目录探测使用其内置的 Copy Path 命令（默认 `Shift+Alt+C`）；Zed 目录探测使用项目面板的 Copy Path 命令（默认同为 `Shift+Alt+C`，仅项目面板聚焦时生效）。两者失败后都会兜底尝试编辑器上下文的 Copy Path（默认 `Ctrl+K P`），把图片保存到当前文件所在目录；Zed 还会进一步尝试键盘导航选中文件树首个条目（根目录）后再次探测，以覆盖面板无选中项的场景。所有探测都会在成功、超时或异常后恢复原剪贴板。如果自定义了对应编辑器的 Copy Path 绑定，需要同步修改 `Shortcuts.VsCodeCopyPath` / `Shortcuts.ZedCopyPath`。

### 测试

从仓库根目录运行唯一推荐的测试入口：

```powershell
powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1
```

测试脚本使用真实的 AutoHotkey v2 逐个加载功能模块，并检查 PowerShell 辅助脚本的 AST。测试入口会自行处理结果，不需要直接读取某个固定的临时结果文件。

## Screenshot OCR

屏幕区域 OCR 依赖 Python 3、Pillow 与 RapidOCR（中英文识别，模型随包分发、完全离线）。运行依赖安装脚本自动完成安装：

```powershell
python .\tools\raycast-scripts\ocr\install-deps.py
```

脚本会先检测操作系统与 Python 环境，再按平台选用解释器（Windows 优先 `python`，macOS/Linux 优先 `python3`），仅安装缺失的 pip 依赖并验证 RapidOCR 引擎可加载；重复运行会自动跳过已装依赖，`--check` 参数可只检测不安装。安装完成后会询问是否下载 PP-OCRv4 移动端模型，下载完成后可继续询问是否将 `models.toml` 切换为 `mobile`。

推荐通过 Raycast 命令 **Screenshot OCR**（`tools/raycast-scripts/screenshot-ocr.ps1`）触发：注入 `Win+Shift+S` 打开系统截图框选，随后由 `ocr/ocr.py` 静默识别，完成后托盘气泡显示结果。也可以手动运行：

```powershell
pythonw.exe .\tools\raycast-scripts\ocr\ocr.py
```

脚本轮询系统剪贴板中的图片（超时 45 秒，按 Esc 取消则直接退出），识别中英文后把文本写回剪贴板并显示结果通知（Raycast 流程为托盘气泡，手动运行为右上角自绘卡片），不产生日志或临时文件。

### OCR 模型配置

`tools/raycast-scripts/ocr/config.json` 的 `"ocr"` 字段切换识别引擎：

- `system`（默认）：使用 Windows 系统文本操作（`Win+Shift+T`，Windows 11 23H2+），框选后由系统自动 OCR，无需 Python 依赖
- `rapidocr`：使用 RapidOCR（`pythonw` + `ocr/ocr.py`，ctypes 注入 `Win+Shift+S`），识别精度更高但需先运行 `install-deps.py` 安装依赖

`tools/raycast-scripts/ocr/models.toml`（TOML，支持 `#` 注释）中 `models` 下列出所有可用模型的完整配置（检测 `det` / 方向分类 `cls` / 识别 `rec` 三个模型路径），修改顶层 `model` 字段选择生效的模型，文件内注释有完整说明：

- `default`（默认）：`""` 表示使用 RapidOCR 包内置的 PP-OCRv4 全精度模型，精度优先
- `mobile`：使用 PP-OCRv4 移动端模型，识别更快、精度略降；运行 `python .\tools\raycast-scripts\ocr\install-deps.py` 后按提示选择下载（sha256 校验，已存在则跳过），下载完成后可一键把 `models.toml` 切换为 `mobile`

路径缺失时自动回退对应内置模型（`cls` 缺失时回退的内置模型与本配置指向的是同一文件），不影响启动。

## Raycast 脚本

`tools/raycast-scripts/` 提供六个 Script Command：

| 脚本 | 功能 |
| --- | --- |
| `open-neomutt.ps1` | 使用 PowerShell 7+（`pwsh.exe`）打开窗口，在默认 WSL 发行版的 home 目录运行 `neomutt` |
| `restart-autohotkey.ps1` | 仅结束本工具箱的 `ahk/main.ahk` 进程，通过 PATH 中的 AutoHotkey v2 重新加载，确认进程运行后在 Raycast 显示成功提示 |
| `record-screen.ps1` | 注入 `Win+Shift+R` 直接打开截图工具（Snipping Tool）的屏幕录制框选，停止录制使用录制浮窗按钮，产物保存到 `Videos\Captures` |
| `screenshot.ps1` | 注入 `Win+Shift+S` 打开截图工具框选，结果复制到剪贴板（可用智能粘贴保存到目录） |
| `screenshot-ocr.ps1` | 注入 `Win+Shift+S` 后启动 `ocr/ocr.py`，框选结束自动 OCR，识别文本复制到剪贴板 |
| `ocr/install-deps.py` | 安装 OCR 依赖（Pillow + RapidOCR + pyperclip），按提示下载移动端模型，已装则跳过 |

在 Raycast 的 Script Commands 设置中添加 `tools/raycast-scripts` 目录即可使用，并可对每个命令单独绑定 Hotkey。NeoMutt 脚本要求 `pwsh.exe` 可通过 PATH 解析，并且默认 WSL 发行版内已安装 `neomutt`；AutoHotkey 重启脚本要求 `AutoHotkey.exe` 可通过 PATH 解析；录屏脚本要求 Windows 11 22H2+（截图工具自带屏幕录制）；OCR 脚本要求先运行 `install-deps.py` 安装 RapidOCR，且 `pythonw.exe` 可通过 PATH 解析。

## Navicat-refresh

分为MacOS和Windows版本。

路径切换到./tools/navicat-refresh执行

```bash
# windows
.\reset_navicat.ps1
# macos
.\reset_navicat.sh
```

## Theme Scheduler

Windows 深浅色模式自动切换：根据日出/日落时间切换深浅色，定位失败时回退固定时间。

### 运行方式

由三个计划任务驱动（`schtasks /query /tn "Theme-*"` 查看）：

| 任务 | 时间 | 作用 |
| --- | --- | --- |
| `Theme-Schedule-Update` | 每天 00:10 | 定位经纬度，计算当天日出/日落，更新下面两个任务的触发时间 |
| `Theme-Light` | 日出时 | 切换浅色 |
| `Theme-Dark` | 日落时 | 切换深色 |

切换原理：修改 `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` 的 `AppsUseLightTheme` / `SystemUsesLightTheme`（1=浅色，0=深色）。

### 手动控制

```powershell
# 立即重新计算日出/日落并更新时间
schtasks /run /tn "Theme-Schedule-Update"

# 立即切换深浅色
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Set-Theme-Dark.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Set-Theme-Light.ps1
```

### 配置

编辑 `tools/theme-scheduler/Update-ThemeSchedule.ps1` 顶部：

- 位置：默认通过**绕过系统代理**的直连 IP 定位经纬度（避免代理出口导致位置偏差）；也可手动填写 `$Latitude` / `$Longitude` 固定位置
- 备用时间：定位失败或极昼/极夜时使用 `$FallbackLight`（默认 07:00）/ `$FallbackDark`（默认 19:00）

运行日志写入同目录 `theme-scheduler.log`。

### 计划任务注册

```powershell
schtasks /create /tn "Theme-Schedule-Update" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\tools\theme-scheduler\Update-ThemeSchedule.ps1" /sc daily /st 00:10 /f
schtasks /create /tn "Theme-Light" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\tools\theme-scheduler\Set-Theme-Light.ps1" /sc daily /st 07:00 /f
schtasks /create /tn "Theme-Dark" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\tools\theme-scheduler\Set-Theme-Dark.ps1" /sc daily /st 19:00 /f
```

## 仓库结构

```text
lat3ncy-scripts-toolbox/
├── ahk/
│   ├── main.ahk              # AutoHotkey 唯一入口
│   ├── shortcuts.ahk         # 集中快捷键配置
│   ├── features/             # 独立功能模块
│   └── tests/                # AHK 与 PowerShell 自动测试
├── tools/
│   ├── navicat-refresh/      # Navicat 试用期重置（MacOS/Windows）
│   ├── raycast-scripts/      # Raycast 命令（含 ocr/ 子目录的 OCR 核心与依赖安装）
│   └── theme-scheduler/      # Windows 深浅色自动切换（日出日落调度）
└── README.md                 # 唯一提交的仓库文档
```
