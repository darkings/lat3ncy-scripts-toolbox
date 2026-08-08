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
python .\tools\screenshot-ocr\install-deps.py
```

脚本会先检测操作系统与 Python 环境，再按平台选用解释器（Windows 优先 `python`，macOS/Linux 优先 `python3`），仅安装缺失的 pip 依赖并验证 RapidOCR 引擎可加载；重复运行会自动跳过已装依赖，`--check` 参数可只检测不安装。

推荐使用 Raycast Quicklink 打开 `launch.vbs`。VBS 通过 `pythonw.exe`（失败时回退到 `pyw.exe`）静默启动 OCR，不会创建终端窗口。

1. 在 Raycast 中运行 **Create Quicklink**。
2. Name 填写 `截图识别`。
3. Link 填写 `C:\Users\Jie\Projects\lat3ncy-scripts-toolbox\tools\screenshot-ocr\launch.vbs`。
4. Open With 使用系统默认的 Windows Script Host。
5. 保存后可为该 Quicklink 配置 alias 或全局快捷键。

`pythonw.exe` 不创建终端窗口。执行后拖拽选择识别区域，结果会复制到剪贴板并通过 Windows 通知显示摘要。

## Raycast 脚本

`tools/raycst-scripts/` 提供两个 PowerShell Script Command：

| 脚本 | 功能 |
| --- | --- |
| `open-neomutt.ps1` | 使用 PowerShell 7+（`pwsh.exe`）打开窗口，在默认 WSL 发行版的 home 目录运行 `neomutt` |
| `restart-autohotkey.ps1` | 仅结束本工具箱的 `ahk/main.ahk` 进程，通过 PATH 中的 AutoHotkey v2 重新加载，确认进程运行后在 Raycast 显示成功提示 |

在 Raycast 的 Script Commands 设置中添加 `tools/raycst-scripts` 目录即可使用。NeoMutt 脚本要求 `pwsh.exe` 可通过 PATH 解析，并且默认 WSL 发行版内已安装 `neomutt`；AutoHotkey 重启脚本要求 `AutoHotkey.exe` 可通过 PATH 解析。

## Navicat-refresh

分为MacOS和Windows版本。

路径切换到./tools/navicat-refresh执行

```bash
# windows
.\reset_navicat.ps1 
# macos
.\reset_navicat.sh
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
│   └── screenshot-ocr/       # 截图 OCR 与 Raycast Quicklink VBS 入口
└── README.md                 # 唯一提交的仓库文档
```
