# 脚本工具箱迁移与模块化设计

## 目标

将 `D:\Scripts` 中可维护的脚本迁移到当前 Git 仓库，并将现有 AutoHotkey v2 生产力脚本拆分为可以独立启停和配置快捷键的功能模块。迁移后的仓库应避免机器专属路径和运行时产物，能够在另一台 Windows 电脑上按文档完成配置。

## 迁移范围

迁移并整理以下内容：

- AutoHotkey 功能、自动化测试和保存剪贴板图片所需的 PowerShell 辅助脚本。
- 截图 OCR 的 Python 源码、可移植启动器和使用文档。
- 与当前功能仍然相关的设计说明。

不迁移以下机器相关或可再生成内容：

- `__pycache__` 和 `*.pyc`。
- `last_ocr.log`、`last_capture.png`、`last_processed.png` 等运行产物。
- Windows `.lnk` 快捷方式。
- `tessdata/*.traineddata` 本地 OCR 模型；由 README 说明安装方式。

仓库根目录使用 `.gitignore` 持续排除这些内容。

## 目录结构

```text
lat3ncy-scripts-toolbox/
├── .gitignore
├── README.md
├── ahk/
│   ├── main.ahk
│   ├── shortcuts.ahk
│   ├── features/
│   │   ├── caps-lock-ime.ahk
│   │   ├── always-on-top.ahk
│   │   ├── search-selected-text.ahk
│   │   ├── open-selected-target.ahk
│   │   ├── locate-selected-target.ahk
│   │   ├── toggle-hidden-files.ahk
│   │   └── smart-paste/
│   │       ├── smart-paste.ahk
│   │       └── save-clipboard-image.ps1
│   └── tests/
│       └── run-tests.ahk
├── tools/
│   └── screenshot-ocr/
│       ├── screenshot_ocr.py
│       ├── launch.bat
│       ├── launch-hidden.ps1
│       └── README.md
└── docs/
    └── superpowers/
        ├── plans/
        └── specs/
```

## AutoHotkey 架构

`ahk/main.ahk` 是加入 AutoHotkey 启动项或直接运行的唯一入口。它先引入 `shortcuts.ahk`，再逐行引入已启用的功能。用户通过注释或取消注释单个 `#Include` 行启停功能。

`ahk/shortcuts.ahk` 只负责定义快捷键，不包含功能实现。所有功能模块从该文件读取自己的快捷键，因此修改按键不需要编辑功能源码。

每个功能文件是一个自包含模块：自行注册热键、持有自己的辅助函数，并用独立类名作为命名空间以避免符号冲突。模块不得依赖其他功能文件。允许少量提示和选区读取逻辑重复，以换取模块能够单独复制和维护。

现有功能拆分为：

- Caps Lock 短按切换输入法、长按启用大写、再次按下关闭大写并强制英文。
- 切换活动窗口置顶。
- 使用 Google 搜索选中文字。
- Smart Paste 智能粘贴。
- 打开选中的文件、目录或 URL。
- 在资源管理器中定位选中的文件或目录。
- 切换资源管理器隐藏文件显示状态。

`open-selected-target.ahk` 与 `locate-selected-target.ahk` 各自保留完整的选区解析逻辑，不互相包含。

## 快捷键配置与冲突

`shortcuts.ahk` 使用一个 `Shortcuts` 类集中保存各功能的 AutoHotkey v2 热键字符串。功能加载时验证自己的配置非空并注册热键。

入口脚本维护已注册快捷键集合。如果两个已启用功能使用同一快捷键，启动时显示明确错误并退出，避免后加载的功能静默覆盖先加载功能。注释掉功能的 `#Include` 后，该功能不参与冲突检测。

默认快捷键延续当前脚本：

- `$CapsLock`：Caps Lock / 输入法控制。
- `Ctrl+Win+T`：窗口置顶。
- `Ctrl+Shift+G`：搜索选中文字。
- `Ctrl+Shift+V`：Smart Paste。
- `Ctrl+Alt+O`：打开选中目标。
- `Ctrl+Alt+E`：定位选中目标。
- `Win+Shift+.`：显示或隐藏隐藏文件。

## Smart Paste

Smart Paste 先对剪贴板类型和活动窗口分类，再选择行为：

| 剪贴板内容 | 活动窗口 | 行为 |
| --- | --- | --- |
| 文本 | 任意 | 使用 `SendText` 粘贴无格式文本 |
| 图片 | 普通文件系统资源管理器 | 保存为唯一命名的 PNG |
| 图片 | 其他应用 | 发送普通 `Ctrl+V` |
| 已复制的文件或目录 | 任意 | 发送普通 `Ctrl+V` |
| 其他或无法可靠分类的内容 | 任意 | 发送普通 `Ctrl+V` |

文件列表通过 `CF_HDROP` 检测，并优先于文本分支，确保在资源管理器中复制文件后仍能正常粘贴。图片检测覆盖 `CF_BITMAP`、`CF_DIB`、`CF_DIBV5` 和注册的 PNG 剪贴板格式。

保存图片仍使用同目录的 Windows PowerShell STA 辅助脚本，以避免引入体积较大的 AHK GDI+ 库。PowerShell 仅在资源管理器保存图片时启动，普通粘贴路径没有额外进程。辅助脚本先写入同一目标目录的唯一临时文件，成功编码后再原子重命名为 `Clipboard-yyyyMMdd-HHmmss[-N].png`；失败时清理临时文件，不覆盖既有文件。

虚拟资源管理器位置、目录不可写、剪贴板内容在检测后变化、图片解码失败和 PowerShell 启动失败均显示明确的短提示。Smart Paste 的文件名格式和提示时长保留为模块内部配置，不增加全局配置复杂度。

## OCR 工具可移植性

OCR 工具移至 `tools/screenshot-ocr/`。启动器必须基于自身目录定位 `screenshot_ocr.py`，不得包含 `D:\Scripts` 或特定 Scoop 安装目录。

`launch.bat` 使用当前环境中的 `python`。`launch-hidden.ps1` 按 `pythonw.exe`、`pyw.exe` 和常见 Python Launcher 方式依次查找无窗口解释器；找不到时给出可操作的错误提示。Python 程序仍支持 `OCR_LANG`、`OCR_PSM` 和 `TESSERACT_CMD` 环境变量。

OCR 日志与调试截图可以继续生成在工具目录，但由 `.gitignore` 排除。Tesseract 和语言包作为外部依赖，由工具 README 提供安装及验证命令。

## 错误处理

- AHK 启动阶段对空快捷键、重复快捷键和辅助脚本缺失给出明确错误。
- 功能运行失败只提示对应功能的错误，不导致其他热键失效。
- 操作剪贴板的功能在读取选区后恢复原剪贴板内容。
- OCR 启动器找不到 Python 时返回非零退出码并显示安装建议。
- OCR 找不到 Tesseract 或语言数据时沿用通知与日志诊断，并在 README 中说明解决方法。

## 测试与验收

AutoHotkey 自动测试覆盖：

- 每个功能模块可单独解析和加载。
- 默认快捷键及重复快捷键检测。
- 选中目标规范化、分类和 URL 编码。
- Caps Lock 状态机和隐藏文件状态转换。
- Smart Paste 对文本、图片、文件列表及未知类型的分派。
- Smart Paste 源码包含所需 Windows 剪贴板格式和 PowerShell 边界。

PowerShell 辅助脚本通过 PowerShell AST 解析检查语法。Python 工具通过 `compileall` 检查语法，并验证启动器中不存在原 `D:\Scripts` 或特定 Python 安装路径。

人工验收包括：逐项注释 `main.ahk` 的功能、修改 `shortcuts.ahk` 后热键生效、文本无格式粘贴、资源管理器图片保存、非资源管理器图片粘贴、资源管理器文件粘贴、目标打开与定位、隐藏文件切换、Caps Lock 输入法行为及 OCR 完整流程。

## 文档

根 README 说明仓库结构、AutoHotkey v2 要求、运行 `ahk/main.ahk`、通过注释 `#Include` 启停功能、修改 `shortcuts.ahk`、运行自动测试和安装 OCR 工具。OCR 子目录 README 只记录该工具的依赖、启动方式、Raycast 配置、环境变量和故障排查。
