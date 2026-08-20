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

- `ahk/shortcuts.ahk` 只保存快捷键配置，`ahk/hotkey-router.ahk` 统一完成校验与注册，`ahk/features/` 只实现功能。
- 修改按键只编辑 `ahk/shortcuts.ahk`；停用某项功能时，在 Router 中注释对应的注册项即可，feature 文件无需修改。
- 如果两个已启用功能使用了相同快捷键，脚本会在启动时报错，避免其中一个功能被静默覆盖。

### 默认快捷键

| 快捷键 | 功能 | Feature 文件 |
| --- | --- | --- |
| `CapsLock`（`*$CapsLock`） | 短按切换输入法中英文，长按（>= 500ms）启用大写锁定，再按一次退出并恢复输入法状态 | `ahk/features/caps-lock-ime.ahk` |
| `Caps + S`（`~CapsLock & s`） | 朗读选中的文字（智能中英文双语音色即时发音，再次按下即时打断） | `ahk/features/speak-selected-text.ahk` |
| `Caps + G`（`~CapsLock & g`） | 使用 Google 搜索选中文字 | `ahk/features/search-selected-text.ahk` |
| `Caps + O`（`~CapsLock & o`） | 打开选中的文件、目录或 URL | `ahk/features/open-selected-target.ahk` |
| `Caps + E`（`~CapsLock & e`） | 在资源管理器中定位选中的文件或目录 | `ahk/features/locate-selected-target.ahk` |
| `Caps + T`（`~CapsLock & t`） | 切换活动窗口置顶 / 取消置顶 | `ahk/features/always-on-top.ahk` |
| `Caps + H`（`~CapsLock & h`） | 显示或隐藏资源管理器中的隐藏文件 | `ahk/features/toggle-hidden-files.ahk` |
| `Ctrl + V`（`$^v`） | 智能粘贴：仅图片时介入保存为本地 PNG 文件；非图片内容原生无损透传 | `ahk/features/smart-paste/smart-paste.ahk` |
| `Alt + 反引号`（`!sc029`） | 按当前 Z-order 快照循环切换同一应用窗口 | `ahk/features/switch-app-window.ahk` |
| `Shift + Alt + 反引号`（`+!sc029`） | 沿快照反向切换同一应用窗口 | `ahk/features/switch-app-window.ahk` |

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

## 统一通知

AHK feature 与 Raycast PowerShell 脚本共用 `shared/notify/renderer.ahk` 绘制的 Win11 Fluent 级自适应 HUD。视觉参数统一在 Renderer 中维护；feature 统一调用 `Notify.State()`、`Notify.Info()`、`Notify.Success()` 或 `Notify.Error()`，不得自行创建通知 GUI 或直接调用 `ToolTip`。

- **4 级全场景输入锚点定位引擎（C# + UIA）**：
  - **L1（Win32 Caret）**：通过 `GetGUIThreadInfo` 捕获传统 Win32 控件光标。
  - **L2（UIA TextPattern / TextPattern2）**：毫秒级精准捕获 Chromium 内核（Edge / Chrome）、Windows Terminal、WinUI3 记事本、VS Code 等现代文本输入光标。
  - **L3（UIA FocusedElement）**：针对自绘搜索框与无选区输入框进行物理边界锚定。
  - **Fallback（降级兜底）**：无焦点时智能挂载于活动窗口底部或屏幕工作区底部。
  - **单次无缝呈现（Zero-Jump）**：在窗口创建前即刻完成光标探测与尺寸预解算，杜绝任何中间状态闪烁与跳跃。
- **深浅色自适应视觉体系（Dark / Light Mode）**：
  - **深色模式（Dark Mode）**：沉浸式 `#202022` 背景、`#F2F2F7` 纯白文字、`#38383A` 1px 微发光边框。
  - **浅色模式（Light Mode）**：极简纯白 `#FFFFFF` 背景、`#18181B` 高对比度墨黑文字、`#E4E4E7` 1px 浅灰色立体边框。
  - 硬件级亚像素抗锯齿大圆角（`DWMWA_WINDOW_CORNER_PREFERENCE`）与 1px 细描边（`DWMWA_BORDER_COLOR`）。
- **调用链路**：
  - AHK 调用链：feature → `Notify` → `NotifyRenderer`；Renderer 失败时自动回退 `ToolTip`。
  - Raycast 调用链：script → `tools/raycast-scripts/_lib/notify.ps1` → `notify.exe` 或 `notify-cli.ahk`；调用失败时由脚本 `Write-Output`，交给 Raycast HUD 显示。
- **生命周期**：同一时间只保留一个 HUD，新通知自动覆盖旧通知；默认时长：`state` 550ms、`info` 750ms、`success` 900ms、`error` 1400ms。
- `Notify.Mode` 支持 `full`、`errors` 和 `off`；默认是 `full`。

## Screenshot OCR

屏幕区域 OCR 支持 Windows 系统文本操作和 RapidOCR 两种引擎。默认使用 Windows 系统文本操作，不需要安装 Python 依赖；如需使用 RapidOCR，再运行依赖安装脚本：

```powershell
python .\tools\raycast-scripts\ocr\install-deps.py
```

安装脚本会先检测操作系统与 Python 环境，再按平台选用解释器（Windows 优先 `python`，macOS/Linux 优先 `python3`），仅安装缺失的 RapidOCR 依赖并验证引擎可加载；重复运行会自动跳过已装依赖，`--check` 参数可只检测不安装。安装完成后会询问是否下载 PP-OCRv4 移动端模型，以及是否在 `config.toml` 中切换为 `mobile`。

推荐通过 Raycast 命令 **Screenshot OCR**（`tools/raycast-scripts/screenshot-ocr.ps1`）触发。默认 `system` 模式直接注入 `Win+Shift+T`，进入 Windows 文本操作的框选识别，不显示本脚本通知；切换为 `rapidocr` 后，才会注入 `Win+Shift+S` 并由 `ocr/ocr.py` 识别，完成后显示统一 HUD。也可以手动运行：

```powershell
pythonw.exe .\tools\raycast-scripts\ocr\ocr.py
```

RapidOCR 模式会轮询系统剪贴板中的图片（超时 45 秒，按 Esc 取消则直接退出），识别中英文后把文本写回剪贴板；Raycast 流程通过共享 Renderer 显示结果，调用失败时回退 Raycast HUD。手动运行 `ocr.py` 时仍使用其自身结果界面。system 模式由 Windows 完成框选、识别和复制，不经过 Python。

### OCR 模型配置

`tools/raycast-scripts/ocr/config.toml` 的 `ocr` 字段切换识别引擎：

- `system`（默认）：使用 Windows 系统文本操作（`Win+Shift+T`，Windows 11 23H2+），框选后由系统自动 OCR，无需 Python 依赖
- `rapidocr`：使用 RapidOCR（`pythonw` + `ocr/ocr.py`，ctypes 注入 `Win+Shift+S`），识别精度更高但需先运行 `install-deps.py` 安装依赖

同一个 `tools/raycast-scripts/ocr/config.toml`（TOML，支持 `#` 注释）中，`models` 下列出所有 RapidOCR 模型的完整配置（检测 `det` / 方向分类 `cls` / 识别 `rec` 三个模型路径），修改顶层 `model` 字段选择生效的模型，文件内注释有完整说明：

- `default`（默认）：`""` 表示使用 RapidOCR 包内置的 PP-OCRv4 全精度模型，精度优先
- `mobile`：使用 PP-OCRv4 移动端模型，识别更快、精度略降；运行 `python .\tools\raycast-scripts\ocr\install-deps.py` 后按提示选择下载（sha256 校验，已存在则跳过），下载完成后可一键把 `config.toml` 切换为 `mobile`

路径缺失时自动回退对应内置模型（`cls` 缺失时回退的内置模型与本配置指向的是同一文件），不影响启动。

## Raycast 脚本

`tools/raycast-scripts/` 提供丰富的跨平台 Script Commands：

| 脚本 | 功能 |
| --- | --- |
| `reset-navicat.ps1` | 自动识别当前操作系统（Windows / macOS / Linux），调用对应的 Navicat Premium 试用期重置脚本并弹出 HUD 提示 |
| `restart-autohotkey.ps1` | 仅结束本工具箱的 `ahk/main.ahk` 进程，通过 PATH 中的 AutoHotkey v2 重新加载，确认进程运行后在 Raycast 显示成功提示 |
| `screenshot.ps1` | 注入 `Win+Shift+S` 打开截图工具框选，结果复制到剪贴板（可用智能粘贴保存到目录） |
| `screenshot-ocr.ps1` | 默认注入 `Win+Shift+T` 使用 Windows 系统 OCR；切换为 `rapidocr` 后注入 `Win+Shift+S` 并启动 `ocr/ocr.py` |
| `record-screen.ps1` | 注入 `Win+Shift+R` 直接打开截图工具（Snipping Tool）的屏幕录制框选，停止录制使用录制浮窗按钮，产物保存到 `Videos\Captures` |
| `open-neomutt.ps1` | 使用 PowerShell 7+（`pwsh.exe`）打开窗口，在默认 WSL 发行版的 home 目录运行 `neomutt` |
| `ocr/install-deps.py` | 安装 OCR 依赖（Pillow + RapidOCR + pyperclip），按提示下载移动端模型，已装则跳过 |

在 Raycast 的 Script Commands 设置中添加 `tools/raycast-scripts` 目录即可使用，并可对每个命令单独绑定 Hotkey。

## Navicat-refresh

跨平台 Navicat Premium 试用期重置工具，支持 Windows、macOS 与 Linux。

- **快速触发**：通过 Raycast 运行 `Reset Navicat Trial`（`tools/raycast-scripts/reset-navicat.ps1`）一键自动适配系统执行。
- **手动运行**：
  ```powershell
  # Windows
  powershell -File .\tools\navicat-refresh\reset_navicat.ps1
  # macOS / Linux
  bash ./tools/navicat-refresh/reset_navicat.sh
  ```

## Theme Scheduler

Windows 主题 / 深浅色模式 / 壁纸自动化调度系统。支持根据日出/日落时间动态对齐太阳作息，或按固定时间准时切换。

### 统一配置文件（`tools/theme-scheduler/config.toml`）

```toml
[general]
# 切换类型: "mode" (仅深浅色模式切换，默认推荐) | "theme" (完整主题包切换)
switch_type = "mode"
show_notification = true # 是否弹出 HUD 通知

[schedule]
trigger_mode = "sun" # "sun" (日出日落动态计算) | "fixed" (固定时间)
fixed_light_time = "07:00" # 浅色切换时间
fixed_dark_time = "19:00"  # 深色切换时间

[wallpaper]
enabled = false # 是否在切换时联动更换桌面壁纸 (true / false)
light_wallpaper = "C:\\path\\to\\Day.jpg"
dark_wallpaper  = "C:\\path\\to\\Night.jpg"

[theme_settings]
# 智能名称/路径寻址：支持 "aero"、"dark"、"Dark Theme" 或绝对路径
light_theme_file = "aero.theme"
dark_theme_file  = "dark.theme"
```

### 运行方式

由三个计划任务驱动（`schtasks /query /tn "Theme-*"` 查看）：

| 任务 | 时间 | 作用 |
| --- | --- | --- |
| `Theme-Schedule-Update` | 每天 00:10 | 定位经纬度，计算当天日出/日落，更新下面两个任务的触发时间 |
| `Theme-Light` | 日出或指定时间 | 切换浅色（模式 / 主题 / 壁纸）并提示 HUD |
| `Theme-Dark` | 日落或指定时间 | 切换深色（模式 / 主题 / 壁纸）并提示 HUD |

### 手动控制

```powershell
# 立即重新计算日出/日落并更新时间
schtasks /run /tn "Theme-Schedule-Update"

# 立即切换深浅色
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Set-Theme-Dark.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Set-Theme-Light.ps1
```

### 计划任务注册

```powershell
schtasks /create /tn "Theme-Schedule-Update" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\tools\theme-scheduler\Update-ThemeSchedule.ps1" /sc daily /st 00:10 /f
schtasks /create /tn "Theme-Light" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\tools\theme-scheduler\Set-Theme-Light.ps1" /sc daily /st 07:00 /f
schtasks /create /tn "Theme-Dark" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\tools\theme-scheduler\Set-Theme-Dark.ps1" /sc daily /st 19:00 /f
```

## Text-to-Speech (TTS)

选中文本按 `CapsLock+S`，按中英文语境智能切片并调用 Microsoft Edge Neural TTS 自动朗读。

- **智能中英切片**：自动将中英混排文本（如 `今天使用 Windows 11 学习 Python 很方便。`）切片，中文使用 Xiaoxiao，英文使用 Jenny / Sonia，数字与标点智能跟随上下文。
- **无后台驻留**：非驻留架构（One-Shot Helper），平时 0 后台进程；触发朗读时临时调用 `pythonw.exe`，播放完毕自动退出。
- **即时打断**：再次按下快捷键时，自动终止上一个播放进程与音频，立即开始新的朗读。
- **SHA256 本地多维缓存**：按 `text + voice + rate + pitch + volume` 在 `%LOCALAPPDATA%\lat3ncy-toolbox\tts-cache\` 缓存音频，常用词语瞬发播放，支持 LRU 容量自动淘汰。
- **离线兜底**：若网络异常或离线，自动降级至 Windows 本地 SAPI 朗读保底。

### 依赖安装与配置

首次使用前安装 `edge-tts` 依赖：

```powershell
python .\tools\tts\install-deps.py
```

在 `tools/tts/config.toml` 中自定义音色与参数：

- `zh_voice`：中文音色（默认 `zh-CN-XiaoxiaoNeural`，可选 `zh-CN-YunxiNeural` 等）
- `en_voice`：英文音色（默认美音 `en-US-JennyNeural`，可选英音 `en-GB-SoniaNeural`、`en-US-GuyNeural` 等）
- `rate` / `pitch` / `volume`：语速、音调与音量调节
- `cache`：最大缓存容量与文件数限制

## 仓库结构

```text
lat3ncy-scripts-toolbox/
├── ahk/
│   ├── main.ahk              # AutoHotkey 唯一入口
│   ├── shortcuts.ahk         # 集中快捷键配置
│   ├── hotkey-router.ahk     # 统一校验、注册并路由到 feature
│   ├── features/             # 独立功能模块
│   └── tests/                # AHK 与 PowerShell 自动测试
├── shared/
│   └── notify/               # AHK/Raycast 共用通知 API、Renderer 与 CLI
├── tools/
│   ├── navicat-refresh/      # Navicat 试用期重置（MacOS/Windows）
│   ├── raycast-scripts/      # Raycast 命令（含 ocr/ 子目录的 OCR 核心与依赖安装）
│   ├── theme-scheduler/      # Windows 深浅色自动切换（日出日落调度）
│   └── tts/                  # Text-to-Speech 核心播放器、依赖安装与配置
└── README.md                 # 唯一提交的仓库文档
```
