# Ctrl+V 图片粘贴与 VS Code 目录支持设计

## 目标

将 Smart Paste 的入口从 `Ctrl+Shift+V` 调整为 `Ctrl+V`。脚本只在剪贴板包含真实图片、目标应用能够提供明确文件系统目录时改变粘贴行为；其他情况必须保持应用原生 `Ctrl+V`。

支持的图片保存目标：

- Windows 文件资源管理器当前显示的普通文件系统目录。
- VS Code 文件栏中当前选中的单个文件夹。

VS Code 文件栏选中文件、选择多个项目、文件栏未聚焦或无法取得有效目录时，不推断父目录或工作区目录，直接执行原生 `Ctrl+V`。

## 快捷键配置

`ahk/shortcuts.ahk` 中：

- `Shortcuts.SmartPaste` 默认改为 `$^v`。`$` 防止 Smart Paste 内部发送的 `Ctrl+V` 再次触发自身。
- 新增 `Shortcuts.VsCodeCopyPath`，默认值为 `+!c`，对应 Windows 版 VS Code 内置的 `copyFilePath` 快捷键 `Shift+Alt+C`。

用户如果修改了 VS Code 的 Copy Path 快捷键，只需同步修改 `Shortcuts.VsCodeCopyPath`。该键只用于向 VS Code 发送命令，不注册为全局热键，也不参加全局热键冲突检查。

## 行为路由

Smart Paste 按以下优先级处理：

| 剪贴板与活动窗口 | 行为 |
| --- | --- |
| 包含 `CF_HDROP` 文件或目录列表 | 原生 `Ctrl+V` |
| 不包含图片 | 原生 `Ctrl+V` |
| 图片 + Windows 文件资源管理器普通目录 | 将图片保存为 PNG |
| 图片 + Windows 文件资源管理器虚拟位置 | 显示无法保存提示，不发送原生粘贴 |
| 图片 + VS Code 文件栏选中单个文件夹 | 将图片保存到该文件夹 |
| 图片 + VS Code 选中文件、多个项目或路径探测失败 | 原生 `Ctrl+V` |
| 图片 + 其他应用 | 原生 `Ctrl+V` |

文本不再使用 `SendText`。文本、HTML、文件列表及无法可靠分类的剪贴板内容全部由当前应用原生处理。

## Windows 文件资源管理器

沿用现有 Shell COM 逻辑：根据活动 `CabinetWClass` 窗口句柄匹配 `Shell.Application` 窗口，并读取当前显示目录。

保存目标是窗口当前目录，不依赖资源管理器中选中的文件或文件夹。`此电脑`、搜索结果等没有普通文件系统路径的位置不执行保存，并显示短提示。

## VS Code 路径探测

仅当活动进程是 `Code.exe` 且剪贴板包含图片时探测路径：

1. 使用 `ClipboardAll()` 完整保存原图片及所有剪贴板格式。
2. 清空剪贴板并向 VS Code 发送 `Shortcuts.VsCodeCopyPath`，默认 `Shift+Alt+C`。
3. 短时间等待 VS Code 的 `copyFilePath` 写入路径。
4. 仅接受单个、存在且 `FileExist` 属性包含 `D` 的文件夹路径。
5. 无论成功、超时或异常，都在 `finally` 中恢复原始图片剪贴板。
6. 取得有效文件夹后调用现有 PNG helper；否则发送原生 `Ctrl+V`。

该流程不使用 VS Code CLI、命令面板、上下文菜单或额外扩展。选中文件时 `copyFilePath` 返回文件路径，因为它不是目录，所以不会保存图片，也不会自动改用文件的父目录。

多选结果如果包含换行或多个路径，不是单个有效目录，按失败处理。普通编辑器文本即使恰好写着一个目录路径，也不会成为目标：路径探测仅由 VS Code 的 Copy Path 命令触发，并要求返回单个真实目录。

## 原生粘贴与递归保护

所有 fallback 使用 `Send "^v"`。全局热键使用 `$^v`，因此 AHK 发送的按键不会递归进入 Smart Paste。

非图片路径不得清空、读取或改写剪贴板。VS Code 路径探测必须先恢复原图片，再发送 fallback `Ctrl+V`，确保应用收到的仍是用户原始剪贴板内容。

## 错误处理

- Windows 文件资源管理器虚拟位置显示明确提示，不猜测保存目录。
- VS Code 路径复制超时、快捷键被改动、返回文件、多选或无效路径时静默回退原生粘贴。
- VS Code 路径探测期间发生异常时恢复剪贴板并执行原生粘贴。
- PNG helper 缺失仍在工具箱启动阶段报错并退出，避免半初始化脚本常驻。
- PNG 编码或目录写入失败沿用现有错误提示和临时文件清理。

## 测试与验收

自动测试覆盖：

- `Shortcuts.SmartPaste` 为 `$^v`，`VsCodeCopyPath` 为 `+!c`。
- 文件列表、无图片、其他应用图片均选择原生粘贴。
- Windows 文件资源管理器图片选择保存分支。
- VS Code 有效目录、文件路径、多选、超时和异常的决策分支。
- VS Code 探测成功与失败后都恢复原剪贴板。
- Smart Paste 内部 `Send "^v"` 不因全局热键产生递归。
- 现有 Bitmap、DIB、DIBV5、PNG-only、PowerShell AST、原子发布和模块独立加载测试继续通过。

人工验收覆盖：

- 普通文本编辑器、浏览器、终端和非目标应用中的 `Ctrl+V` 行为保持原生。
- 文件资源管理器复制文件后 `Ctrl+V` 仍执行文件粘贴。
- 文件资源管理器截图粘贴保存到当前目录。
- VS Code 文件栏选中文件夹时保存 PNG。
- VS Code 文件栏选中文件、选择多个项目或编辑器聚焦时执行原生粘贴。
- 修改或移除 VS Code Copy Path 快捷键时安全回退，剪贴板图片不丢失。
- 连续保存图片不覆盖已有文件。
