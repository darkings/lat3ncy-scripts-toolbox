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
| `Ctrl+V`（`$^v`） | 仅图片时介入：保存到资源管理器当前目录或 VS Code 侧栏选中的单个已存在目录；资源管理器虚拟位置显示提示，其他情况原生粘贴 | `ahk/features/smart-paste/smart-paste.ahk` |
| `Ctrl+Alt+O`（`^!o`） | 打开选中的文件、目录或 URL | `ahk/features/open-selected-target.ahk` |
| `Ctrl+Alt+E`（`^!e`） | 在资源管理器中定位选中的文件或目录 | `ahk/features/locate-selected-target.ahk` |
| `Win+Shift+.`（`#+.`） | 显示或隐藏资源管理器中的隐藏文件 | `ahk/features/toggle-hidden-files.ahk` |

### Smart Paste 路由

`Ctrl+V` 仅在剪贴板包含图片时可能介入；资源管理器虚拟位置也会介入并显示无法保存提示。下表按从上到下的顺序优先匹配：

| 剪贴板内容 | 活动窗口 | 行为 |
| --- | --- | --- |
| 已复制的文件或目录（即使同时包含图片格式） | 任意 | 优先执行原生 `Ctrl+V` |
| 非图片内容 | 任意 | 原生 `Ctrl+V` |
| 图片 | 普通文件系统目录的资源管理器 | 保存为不会覆盖已有文件的唯一命名 PNG |
| 图片 | 资源管理器虚拟位置 | 显示无法保存提示，不发送原生粘贴 |
| 图片 | VS Code 文件栏选中的单个已存在文件夹 | 保存为不会覆盖已有文件的唯一命名 PNG |
| 图片 | VS Code 选中文件、多个项目、编辑器聚焦、路径探测超时或快捷键不一致 | 恢复原剪贴板后执行原生 `Ctrl+V` |
| 图片 | 其他应用 | 原生 `Ctrl+V` |

VS Code 目录探测使用 Windows 版内置的 Copy Path 命令（默认 `Shift+Alt+C`），并在成功、超时或异常后恢复原剪贴板。如果自定义了 VS Code 的 Copy Path 绑定，需要同步修改 `Shortcuts.VsCodeCopyPath`。

### 测试

从仓库根目录运行唯一推荐的测试入口：

```powershell
powershell.exe -NoProfile -File .\ahk\tests\run-tests.ps1
```

测试脚本使用真实的 AutoHotkey v2 逐个加载功能模块，并检查 PowerShell 辅助脚本的 AST。测试入口会自行处理结果，不需要直接读取某个固定的临时结果文件。

## Screenshot OCR

屏幕区域 OCR 支持前台终端 launcher 和静默 launcher，并依赖 Python、Pillow，以及单独安装的原生 Tesseract OCR 与所需语言模型。安装、启动、环境变量和故障排查请参阅 [`tools/screenshot-ocr/README.md`](tools/screenshot-ocr/README.md)。

## 仓库结构

```text
lat3ncy-scripts-toolbox/
├── ahk/
│   ├── main.ahk              # AutoHotkey 唯一入口
│   ├── shortcuts.ahk         # 集中快捷键配置
│   ├── features/             # 独立功能模块
│   └── tests/                # AHK 与 PowerShell 自动测试
├── tools/
│   └── screenshot-ocr/       # 截图 OCR、launchers 与专用文档
└── docs/superpowers/         # 历史设计和实施计划
```

不要提交运行时产物或机器本地依赖，包括 Python 缓存、OCR 日志与调试截图、Windows 快捷方式，以及 `tessdata/*.traineddata` OCR 模型。仓库的 `.gitignore` 已排除这些内容。
