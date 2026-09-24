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

- CapsLock 短按切中/英、长按进大写；状态 HUD 默认走 `tools/ime-hud-winui/out/ImeHudWinUi.exe`（CN 中框 / EN A / CAPS 上箭头）。效果不理想时把 `CapsLockIme.UseImeHud` 设为 `false`，立刻回退 AHK 芯片。
- `ahk/shortcuts.ahk` 只保存快捷键配置，`ahk/hotkey-router.ahk` 统一完成校验与注册，`ahk/features/` 只实现功能。
- 修改按键只编辑 `ahk/shortcuts.ahk`；停用某项功能时，在 Router 中注释对应的注册项即可，feature 文件无需修改。
- 如果两个已启用功能使用了相同快捷键，脚本会在启动时报错，避免其中一个功能被静默覆盖。

### 默认快捷键

| 快捷键 | 功能 | Feature 文件 |
| --- | --- | --- |
| `CapsLock`（`*$CapsLock`） | 短按（≤ 250ms）切换微软拼音「中/英」并记住；切窗口后静默恢复。250–500ms 松开视为取消；长按（>= 500ms）进入大写，再按一次退出并恢复输入法。`PersistImeAcrossWindows` 可关 | `ahk/features/caps-lock-ime.ahk` |
| `Caps + S`（`~CapsLock & s`） | 朗读选中的文字（智能中英文双语音色即时发音，再次按下即时打断） | `ahk/features/speak-selected-text.ahk` |
| `Caps + F`（`~CapsLock & f`） | 划词翻译：有选区译选区，否则译剪贴板；中英互译，光标处显示译文 | `ahk/features/translate-selected-text.ahk` |
| `Caps + G`（`~CapsLock & g`） | 使用 Google 搜索选中文字 | `ahk/features/search-selected-text.ahk` |
| `Caps + O`（`~CapsLock & o`） | 打开选中的文件、目录或 URL | `ahk/features/open-selected-target.ahk` |
| `Caps + E`（`~CapsLock & e`） | 在资源管理器中定位选中的文件或目录 | `ahk/features/locate-selected-target.ahk` |
| `Caps + T`（`~CapsLock & t`） | 切换活动窗口置顶 / 取消置顶，并提示当前状态 | `ahk/features/always-on-top.ahk` |
| `Caps + H`（`~CapsLock & h`） | 按 Z-order 从顶到底，每次最小化一个尚未最小化的可见窗口；桌面、任务栏、工具窗与工具箱自身不进入列表 | `ahk/features/hide-active-window.ahk` |
| `Caps + .`（`~CapsLock & .`） | 显示或隐藏资源管理器中的隐藏文件 | `ahk/features/toggle-hidden-files.ahk` |
| `Caps + ,`（`~CapsLock & ,`） | 隐藏或恢复当前资源管理器文件夹顶层的点文件（`.git`、`.env` 等） | `ahk/features/toggle-dotfiles.ahk` |
| `Caps + X`（`~CapsLock & x`） | 显示或隐藏资源管理器中的文件扩展名 | `ahk/features/toggle-file-extensions.ahk` |
| `Caps + Q`（`~CapsLock & q`） | 结束当前前台窗口对应进程；前台是资源管理器时直接调用 `Caps + R` | `ahk/features/foreground-process.ahk` |
| `Caps + R`（`~CapsLock & r`） | 重启当前前台窗口对应进程；资源管理器走专用重启 | `ahk/features/foreground-process.ahk` |
| `Ctrl + V`（`$^v`） | 智能粘贴：仅图片时介入保存为本地 PNG 文件；非图片内容原生无损透传 | `ahk/features/smart-paste/smart-paste.ahk` |
| `Alt + 反引号`（`!sc029`） | 按当前 Z-order 快照循环切换同一应用窗口 | `ahk/features/switch-app-window.ahk` |
| `Shift + Alt + 反引号`（`+!sc029`） | 沿快照反向切换同一应用窗口 | `ahk/features/switch-app-window.ahk` |
| `Caps + D`（`~CapsLock & d`） | 切换播放器：`G27Q2` ↔ `AirPods`，自动连接 | `ahk/features/audio-switcher.ahk` + `tools/audio-switcher/audio-switcher.exe` |

同应用窗口切换在第一次触发时保存窗口顺序，按住 `Alt` 连续按反引号即可完整循环；松开 `Alt` 后清除快照。最小化、不可见、工具型以及被系统隐藏的窗口不会进入候选列表。Zed 只有一个可见顶层窗口时，快捷键会通过 `F13` / `F14` 桥接到 Zed 的 `multi_workspace::NextProject` / `multi_workspace::PreviousProject`，循环切换同一窗口中的项目。

### 划词翻译与腾讯云密钥配置

`Caps + F` 默认优先使用腾讯云机器翻译 `TextTranslate`。首次使用前，需要在腾讯云控制台创建 API 密钥，并为该账号授予机器翻译（TMT）调用权限。只需要保存好以下两项：

* `SecretId`
* `SecretKey`（只在创建时显示，请安全保存）

#### 方式一：使用 Windows 环境变量（推荐）

在 PowerShell 中设置当前用户环境变量：

```powershell
[Environment]::SetEnvironmentVariable('TENCENTCLOUD_SECRET_ID', '你的 SecretId', 'User')
[Environment]::SetEnvironmentVariable('TENCENTCLOUD_SECRET_KEY', '你的 SecretKey', 'User')
```

翻译进程每次启动时会读用户环境变量，因此设置后不必重启 `ahk/main.ahk`。程序也兼容 `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY`。环境变量优先于配置文件中的值。

#### 方式二：写入本地配置文件

环境变量未设置时，可编辑 `tools/translate/config.toml`，在 `[tencent]` 段填写：

```toml
[tencent]
secret_id = "你的 SecretId"
secret_key = "你的 SecretKey"
region = "ap-guangzhou"
endpoint = "tmt.tencentcloudapi.com"
project_id = 0
```

配置文件只应保存在本机，不要把真实密钥提交到 Git、发到聊天中或写入截图。仓库中的配置模板保持空值即可。

如果密钥缺失、无效或签名错误，程序不会回退到 Google/MyMemory，而是弹出系统 Toast「腾讯云密钥无效」；网络、限流、免费额度用尽等非鉴权错误仍可按引擎顺序回退。成功时只有译文显示在光标处的翻译气泡中。

如需改回阿里云，把 `engine` 设为 `aliyun`，并配置 `ALIBABA_CLOUD_ACCESS_KEY_ID` / `ALIBABA_CLOUD_ACCESS_KEY_SECRET`。

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
| 图片 | VS Code / Zed 选中文件、多选、编辑器无打开文件、路径探测超时或快捷键不一致 | 静默回退原生 `Ctrl+V` |
| 图片 | 其他应用 | 原生 `Ctrl+V` |

VS Code 目录探测使用其内置的 Copy Path 命令（默认 `Shift+Alt+C`）；Zed 目录探测使用项目面板的 Copy Path 命令（默认同为 `Shift+Alt+C`，仅项目面板聚焦时生效）。两者失败后都会兜底尝试编辑器上下文的 Copy Path（默认 `Ctrl+K P`），把图片保存到当前文件所在目录；Zed 还会进一步尝试键盘导航选中文件树首个条目（根目录）后再次探测，以覆盖面板无选中项的场景。所有探测都会在成功、超时或异常后恢复原剪贴板。如果自定义了对应编辑器的 Copy Path 绑定，需要同步修改 `Shortcuts.VsCodeCopyPath` / `Shortcuts.ZedCopyPath`。

### 测试

从仓库根目录运行唯一推荐的测试入口：

```powershell
powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1
```

测试脚本使用真实的 AutoHotkey v2 逐个加载功能模块，并检查 PowerShell 辅助脚本的 AST。独立加载 stub 会统一注入 `shared/python.ahk`，避免朗读/翻译因缺少 `ToolboxPython` 弹错误框。Windows PowerShell 5.1 要求该 runner 使用 CRLF。测试入口会自行处理结果，不需要直接读取某个固定的临时结果文件。

## 统一通知

AHK feature 统一调用 `Notify.State()`、`Notify.Info()`、`Notify.Success()` 或 `Notify.Error()`，不得自行创建通知 GUI 或直接调用 `ToolTip`。`state` / `popup` 由 `shared/notify/renderer.ahk` 绘制 Win11 Fluent 级自适应 HUD；`success` / `info` / `error` 走系统 Toast。**例外：** CapsLock 的中 / 英 / 大写状态默认走独立进程 `tools/ime-hud-winui/out/ImeHudWinUi.exe`（WinUI 3 Island，Acrylic.Default，圆角 `ROUNDSMALL`，点穿 NOACTIVATE），失败或 `UseImeHud=false` 时回退 `Notify.State()` 芯片。`Caps + F` 划词翻译也走同一 WinUI 进程的独立翻译面板。Raycast 生产通知一律 `Show-SystemToast`，不经过共享 HUD。

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
  - AHK 调用链：CapsLock 的 `CN` / `EN` / `CAPS` 走 `ImeHudWinUi.exe`（WinUI 芯片），失败回退 `NotifyRenderer` 芯片；`Caps + F` 走同一进程的翻译面板；其它 `state` / `popup` 仍走 `Notify` → `NotifyRenderer`；`success` / `info` / `error` 走 `Notify` → `toast.ps1` 系统 Toast，找不到脚本或启动失败时回退 `ToolTip`。
  - 共享资源（`toast.ps1`、`anchor-locator.exe`）通过 `shared/notify/paths.ahk` 按入口脚本目录解析，不写死本机绝对路径。
  - 默认不写调试日志；仅启动参数 `--debug` 或环境变量 `LAT3NCY_DEBUG=1` 时写入 `%TEMP%\lat3ncy-toolbox-notify.log`。
  - Raycast 调用链：script → `tools/raycast-scripts/_lib/notify.ps1` → `Show-SystemToast` → `shared/notify/toast.ps1`。Caps 中/英/大写与 Caps+F 翻译面板仍走 WinUI；其余生产通知一律系统 Toast。
- **生命周期**：同一时间只保留一个 HUD，新通知自动覆盖旧通知；默认时长：`state` 550ms、`info` 750ms、`success` 900ms、`error` 1400ms。
- `Notify.Mode` 支持 `full`、`errors` 和 `off`；默认是 `full`。

## Screenshot OCR

屏幕区域 OCR 支持 Windows 系统文本操作和 RapidOCR 两种引擎。仓库模板默认是 `system`（无需 Python）；**本机当前配置是 `rapidocr`**。如需 RapidOCR，先运行依赖安装脚本：

```powershell
python .\tools\raycast-scripts\ocr\install-deps.py
```

安装脚本会先检测操作系统与 Python 环境，再按平台选用解释器（Windows 优先 `python`，macOS/Linux 优先 `python3`），仅安装缺失的 RapidOCR 依赖并验证引擎可加载；重复运行会自动跳过已装依赖，`--check` 参数可只检测不安装。安装完成后会询问是否下载 PP-OCRv4 移动端模型，以及是否在 `config.toml` 中切换为 `mobile`。

推荐通过 Raycast 命令 **Screenshot OCR**（`tools/raycast-scripts/screenshot-ocr.ps1`）触发。`system` 模式直接注入 `Win+Shift+T`，进入 Windows 文本操作的框选识别，不显示本脚本通知；当前本机为 `rapidocr`，会先打开系统截图框，再启动 `ocr/ocr.py --no-screenshot` 加载模型并识别，完成后显示系统 Toast。手动运行 `ocr.py` 时也会先出框再加载模型：

```powershell
pythonw.exe .\tools\raycast-scripts\ocr\ocr.py
```

RapidOCR 模式会轮询系统剪贴板中的图片（超时 45 秒，按 Esc 取消则直接退出），识别中英文后把文本写回剪贴板；Raycast 流程由 `screenshot-ocr.ps1` 以系统 Toast 显示结果，手动运行 `ocr.py` 时由脚本直接调用 `shared/notify/toast.ps1`。system 模式由 Windows 完成框选、识别和复制，不经过 Python。

### OCR 模型配置

`tools/raycast-scripts/ocr/config.toml` 的 `ocr` 字段切换识别引擎：

- `system`：使用 Windows 系统文本操作（`Win+Shift+T`，Windows 11 23H2+），框选后由系统自动 OCR，无需 Python 依赖
- `rapidocr`（本机当前）：使用 RapidOCR（先 `ms-screenclip:` 出框，再 `pythonw` + `ocr/ocr.py --no-screenshot`），识别精度更高但需先运行 `install-deps.py` 安装依赖

同一个 `tools/raycast-scripts/ocr/config.toml`（TOML，支持 `#` 注释）中，`models` 下列出所有 RapidOCR 模型的完整配置（检测 `det` / 方向分类 `cls` / 识别 `rec` 三个模型路径），修改顶层 `model` 字段选择生效的模型，文件内注释有完整说明：

- `default`（默认）：`""` 表示使用 RapidOCR 包内置的 PP-OCRv4 全精度模型，精度优先
- `mobile`：使用 PP-OCRv4 移动端模型，识别更快、精度略降；运行 `python .\tools\raycast-scripts\ocr\install-deps.py` 后按提示选择下载（sha256 校验，已存在则跳过），下载完成后可一键把 `config.toml` 切换为 `mobile`

路径缺失时自动回退对应内置模型（`cls` 缺失时回退的内置模型与本配置指向的是同一文件），不影响启动。

## Raycast 脚本

`tools/raycast-scripts/` 提供丰富的跨平台 Script Commands：

| 脚本 | 功能 |
| --- | --- |
| `reset-navicat.ps1` | **仅限合法授权测试环境**：识别当前操作系统后调用 Navicat 试用期重置脚本；`silent` 关闭 Raycast 窗口，成功/失败都走系统 Toast。公开仓库请勿默认启用 |
| `restart-autohotkey.ps1` | 仅结束本工具箱的 `ahk/main.ahk` 进程，通过 PATH 中的 AutoHotkey v2 重新加载；`silent` 关闭 Raycast 窗口，成功/失败都走系统 Toast |
| `toggle-rgb.ps1` | 切换技嘉风扇 + Hi75 灯光；只动 `rgb-disabled.flag`，不杀 Ambient、不停 OpenRGB。`silent` 关闭 Raycast 窗口，开关灯成功/失败都走系统 Toast |
| `screenshot.ps1` | 用 `ms-screenclip:` 立刻打开截图框（失败才回退 `Win+Shift+S`），结果复制到剪贴板；若 Win11 自动保存截图已开启并写出文件，后台 Toast 完整路径 |
| `screenshot-ocr.ps1` | 按 `ocr/config.toml` 选择引擎：`system` 注入 `Win+Shift+T`；本机当前 `rapidocr` 先打开截图框，再 `pythonw ocr.py --no-screenshot`。只处理文字，不报图片保存路径 |
| `record-screen.ps1` | 注入 `Win+Shift+R` 直接打开截图工具（Snipping Tool）的屏幕录制框选；停止后若系统写出视频，后台 Toast `Videos\\Captures` 完整路径 |
| `open-neomutt.ps1` | 使用 PowerShell 7+（`pwsh.exe`）打开窗口，在默认 WSL 发行版的 home 目录运行 `neomutt` |
| `ocr/install-deps.py` | 安装 OCR 依赖（Pillow + RapidOCR + pyperclip），按提示下载移动端模型，已装则跳过 |

在 Raycast 的 Script Commands 设置中添加 `tools/raycast-scripts` 目录即可使用，并可对每个命令单独绑定 Hotkey。

## Navicat-refresh

跨平台 Navicat Premium 试用期重置工具，支持 Windows、macOS 与 Linux。**仅限已购买授权或官方允许的测试环境**；会删除试用期相关注册表、哈希文件和凭据。公开或远程推送仓库时，应从默认 Raycast 清单中移除。

- **快速触发**：通过 Raycast 运行 `Reset Navicat Trial`（`tools/raycast-scripts/reset-navicat.ps1`）一键自动适配系统执行。
- **手动运行**：
  ```powershell
  # Windows
  powershell -File ./tools/navicat-refresh/reset_navicat.ps1
  # macOS / Linux
  bash ./tools/navicat-refresh/reset_navicat.sh
  ```

## Theme Scheduler

Windows 主题 / 深浅色模式 / 壁纸自动化调度系统。支持根据日出/日落时间动态对齐太阳作息，或按固定时间准时切换。

### 统一配置文件（`tools/theme-scheduler/config.toml`）

```toml
[general]
# 切换类型: "mode" (仅深浅色模式切换) | "theme" (完整主题包切换)
# 本机当前生产配置是 mode：只切 Apps，不切系统壳。
switch_type = "mode"
show_notification = true # 是否弹出系统 Toast

[schedule]
trigger_mode = "sun" # "sun" (日出日落动态计算) | "fixed" (固定时间)
fixed_light_time = "07:00" # 浅色切换时间
fixed_dark_time = "19:00"  # 深色切换时间

[mode_settings]
# 仅 switch_type = "mode" 时生效。
# switch_system = false：任务栏/托盘保持当前深浅色，不重启 Explorer。
# switch_system = true 才会重启 Explorer 同步系统壳颜色。
switch_apps = true
switch_system = false

[wallpaper]
enabled = false # 是否在切换时联动更换桌面壁纸 (true / false)
light_wallpaper = "C:\\path\\to\\Day.jpg"
dark_wallpaper  = "C:\\path\\to\\Night.jpg"

[theme_settings]
# 智能名称/路径寻址：支持 "light"、"dark" 或绝对路径
light_theme_file = "light.theme"
dark_theme_file  = "dark.theme"
```

### 运行方式

由三个计划任务驱动（`schtasks /query /tn "Theme-*"` 查看）：

| 任务 | 时间 | 作用 |
| --- | --- | --- |
| `Theme-Schedule-Update` | 每天 00:10 | 定位经纬度，计算当天日出/日落，更新下面两个任务的触发时间 |
| `Theme-Light` | 日出或指定时间 | 切换浅色（模式 / 主题 / 壁纸）并弹系统 Toast；仅 mode + switch_system 时才会重启 Explorer |
| `Theme-Dark` | 日落或指定时间 | 切换深色（模式 / 主题 / 壁纸）并弹系统 Toast；仅 mode + switch_system 时才会重启 Explorer |

### 手动控制

```powershell
# 推荐：通过已注册的隐藏计划任务触发（无窗口、与自动调度一致）
schtasks /run /tn "Theme-Schedule-Update" # 立即重新计算日出/日落并校准 Light/Dark 时间
schtasks /run /tn "Theme-Light"           # 立即切浅色
schtasks /run /tn "Theme-Dark"            # 立即切深色

# 调试直调（前台有窗口，仅排错用，路径与执行策略已在 Install 脚本中固化为隐藏无窗口）
# powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Set-Theme-Light.ps1
```

### 计划任务注册

> 旧版 `schtasks /create ... /tr "powershell ..."` 一个个执行已废弃：会丢失 `Hidden/AllowStartIfOnBatteries/WakeToRun/ExecutionTimeLimit` 等隐藏无窗口配置，且写死固定时间无法跟随 `sun` 动态日出日落。

**统一脚本注册（幂等）：**

```powershell
# 一键注册/更新 3 个任务（Theme-Light / Theme-Dark / Theme-Schedule-Update），自动按 config.toml 的 sun/fixed 校准时间
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Install-ThemeScheduler.ps1

# 查看
schtasks /query /tn "Theme-*" /fo LIST
Get-Content .\tools\theme-scheduler\theme-scheduler.log -Tail 20 -Wait

# 移除
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Uninstall-ThemeScheduler.ps1
```

## Text-to-Speech (TTS)

选中文本按 `CapsLock+S`，按中英文语境智能切片并调用 Microsoft Edge Neural TTS 自动朗读。

- **智能中英切片**：自动将中英混排文本（如 `今天使用 Windows 11 学习 Python 很方便。`）切片；默认 `engine=auto`，中文走 `Microsoft Yaoyao`，英文走 `Microsoft Zira`（本地 WinRT 优先，匹配不到再走 Edge Neural），数字与标点智能跟随上下文。
- **无后台驻留**：非驻留架构（One-Shot Helper），平时 0 后台进程；触发朗读时临时调用 `pythonw.exe`（由 `shared/python.ahk` 解析，入口 `ahk/main.ahk` 统一加载），播放完毕自动退出。
- **即时打断**：再次按下快捷键时，自动终止上一个播放进程与音频，立即开始新的朗读。
- **SHA256 本地多维缓存**：按 `text + voice + rate + pitch + volume` 在 `%LOCALAPPDATA%\lat3ncy-toolbox\tts-cache\` 缓存音频，常用词语瞬发播放，支持 LRU 容量自动淘汰。
- **离线兜底**：若网络异常或离线，自动降级至 Windows 本地 SAPI 朗读保底。
- **耳机预热（可选）**：`tools/audio-switcher/config.toml` 设 `tts.auto_switch_before_play = true` 时，`Caps+S` 会在播前 `audio-switcher.exe --ensure-headset` 将 AirPods 拉为默认（默认等待 `connect_wait_ms=12000`），失败不阻塞，日志记 `tools/tts/tts.log`。

### 依赖安装与配置

首次使用前安装 `edge-tts` 依赖：

```powershell
python .\tools\tts\install-deps.py
```

在 `tools/tts/config.toml` 中自定义音色与参数：

- `zh_voice`：中文音色（默认本地 `Microsoft Yaoyao`，也可改 `zh-CN-XiaoxiaoNeural` 等 Edge 音色）
- `en_voice`：英文音色（默认本地 `Microsoft Zira`，也可改 `en-US-JennyNeural` 等 Edge 音色）
- `rate` / `pitch` / `volume`：语速、音调与音量调节
- `cache`：最大缓存容量与文件数限制；非法值会 warning 后夹紧，不让朗读进程崩溃

## Audio Switcher

`Caps+D` 一键切换 `G27Q2 ↔ AirPods`。未连接时自动连接，手机占用时自动抢占，无需手动点蓝牙面板。

- 按 `tools/audio-switcher/config.toml` 识别首选设备，开盖即连
- Caps+D 立即提示「正在检查音频设备」；Busy / 防抖不再静默丢键，失败后可立刻再按
- 立体声未 ACTIVE 时按原因分类：`蓝牙已连但立体声未就绪` / `连接超时` / `耳机未取出或不在附近` / `设备节点不存在` / `耳机未激活`。只有 Enable/WSA/PNP 真正成功才等待 12s
- 自动提权默认关闭；仅 `behavior.auto_elevate=true` 且错误详情明确是权限问题时，才会 `sudo` / `gsudo` 重试。普通立体声未就绪不提权
- 回切扬声器不掉蓝牙

```toml
# tools/audio-switcher/config.toml
[preferred]
headset_keywords = ["AirPods"]
headset_exclude = ["Hands-Free", "Hands Free", "iPhone"]
speaker_keywords = ["G27Q2", "NVIDIA High Definition Audio"]
speaker_exclude = ["Virtual"]
[behavior]
connect_wait_ms = 12000
poll_ms = 200
pnp_fallback = false  # Enable-PnpDevice 易超时，默认关闭
auto_elevate = false  # 仅明确权限错误时才允许 AHK sudo 重试
[tts]
auto_switch_before_play = false  # true 时 Caps+S 朗读前自动 --ensure-headset 预热
```

```powershell
# 手动
.\tools\audio-switcher\audio-switcher.exe --toggle        # 互切
.\tools\audio-switcher\audio-switcher.exe --ensure-headset  # 仅确保耳机为默认（TTS 预热用）
.\tools\audio-switcher\audio-switcher.exe --list
.\tools\audio-switcher\audio-switcher.exe --get
.\tools\audio-switcher\audio-switcher.exe --debug-dump    # 只读诊断，写 %TEMP%\lat3ncy-audio-debug.log
```

详见 `tools/audio-switcher/config.toml` 与 `ahk/tests/run-tests.ahk` 契约 11 项。

## RGB Ambient — 桌面实时取色联动

`tools/rgb`：**技嘉 B550M DS3H 风扇（官方 OpenRGB 系统服务）+ Leobog Hi75（HID Col06）**。OpenRGB 由 Windows 服务常驻，之后只复用 `127.0.0.1:6742`，`ambient.py` 不启动它。项目目录不携带 `OpenRGB.exe`。

- **抓屏**：`mss` 中心 320x180，`sample_step=8` 稀疏采样 + 饱和度 top 30%
- **均色（当前生产，见 `tools/rgb/config.toml`）**：`ema_alpha=0.18` + 阈值 `6` + `lerp_alpha=0.35` + 亮度门限 `22`；过暗不推灯。早期压测曾用阈值 8 / 亮度 16；中间版本曾用阈值 14 / EMA 0.35 / 8Hz，都不是当前配置
- **推灯**：OpenRGB `set_color(..., fast=True)` 只控 Gigabyte；Hi75 Direct `0x08`，两路失败独立重试
- **频率（当前生产）**：活动 12Hz / 静止 6Hz；设备全挂也降频
- **常驻**：系统服务 `OpenRGB`（LocalSystem / Session 0 / delayed-auto，依赖 PawnIO）提供 SDK `127.0.0.1:6742`；登录任务 `RGB-Ambient`（+15s 等 DWM），无窗口 `pythonw`，不提权
- **换机**：`dist/hi75/hi75.exe` 被 gitignore，需先跑 `tools/rgb/build_hi75.ps1`；`lib/`、`lib_hid/`、`hi75_data/` 保留以便免 pip 运行

```powershell
# 一次性（管理员）：winget 官方 OpenRGB 系统服务 + PawnIO
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\install.ps1
# 灯管正常后删除项目内便携包
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\install.ps1 -PruneBundled
# 当前用户：登录常驻 ambient（无需管理员）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\Install-Ambient.ps1
# 日常：不要手动开 OpenRGB 窗口
python tools/rgb/hi75.py --list
python tools/rgb/ambient.py --time 10
python tools/rgb/ambient.py --dry-run --time 5
python tools/rgb/ambient.py --bench 20            # 合成帧压测：不抓屏、不连 SDK、不写灯
python tools/rgb/ambient.py --bench 20 --bench-capture  # 真实抓屏；无交互桌面时 BitBlt 失败不等于硬件损坏
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\Start-Ambient.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\Stop-Ambient.ps1
Get-Content .\tools\rgb\logs\ambient.out.log -Tail 20 -Wait
```

详见 `tools/rgb/README.md`。Hi75 协议基于 `OpenRGB #4297`（`258A:010C` / `Col06` / `060a` 520B）。

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
│   ├── python.ahk            # 本机 pythonw 解析；由 ahk/main.ahk 统一加载，朗读/翻译共用
│   └── notify/               # AHK 芯片/popup HUD、WinUI 客户端、系统 Toast
├── tools/
│   ├── ime-hud-winui/        # CapsLock 中/英/大写芯片 + Caps+F 翻译面板（AHK 检测，ImeHudWinUi.exe 显示）
│   ├── audio-switcher/       # Caps+D 音频切换（G27Q2 ↔ AirPods 自动拉起，config.toml 可配置）
│   ├── rgb/                  # RGB Ambient 桌面取色（mss + 官方 OpenRGB 系统服务 + Hi75 Col06）
│   ├── navicat-refresh/      # Navicat 试用期重置（仅限合法授权测试环境）
│   ├── raycast-scripts/      # Raycast 命令（ocr/ 识字；capture/ 截图与录屏落盘监视）
│   ├── theme-scheduler/      # Windows 主题 / 深浅色自动切换（日出日落调度）
│   └── tts/                  # Text-to-Speech 核心播放器、依赖安装与配置
├── findings.md               # 研究与决策记录（含历史压测参数）
├── progress.md               # 会话进度
├── task_plan.md              # 阶段性任务计划
└── README.md                 # 仓库总览；模块细节见 tools/*/README.md
```
