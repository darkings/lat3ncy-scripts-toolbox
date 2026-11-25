# lat3ncy-scripts-toolbox

一套 Windows 日常工具：用快捷键完成翻译、朗读、截图识别、音频切换和窗口操作，也可通过 Raycast 调用。

## 能做什么

- **翻译与朗读**：选中文字即可使用，支持长文、重试和播放打断。选用腾讯云时，可在设置中填写密钥并开启 Google 保底。
- **截图与录屏**：截图 OCR、截图翻译，以及保存完成后的复制和额外存档。
- **窗口与输入**：CapsLock 中英文切换、窗口置顶、同应用窗口切换、智能粘贴。
- **桌面与设备**：音频输出切换、主题与壁纸、Caffeine 状态图标、电源策略和 RGB 灯光。
- **统一设置**：功能开关、快捷键、厂商密钥和模块参数集中管理。

## 开始使用

需要 Windows x64、AutoHotkey v2 和 Python 3.11+。首次构建界面还需要 .NET 10 SDK；朗读和 OCR 的依赖安装见[安装指南](docs/RELEASING.md)。

在仓库目录打开 PowerShell：

```powershell
# 首次使用：构建界面和锚点助手，并启动工具箱
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\startup\Rebuild-ToolboxHud.ps1

# 以后启动
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\startup\Start-Toolbox.ps1
```

电源、主题和 RGB 的安装按需进行，详见各模块文档。

## 打开设置

在 Raycast 运行 **Toolbox Settings**，或在翻译面板选择 **更多操作 → 工具箱设置**。

设置采用左侧分类、右侧配置，修改后自动保存。功能开关位于标题右侧；偏离默认值时可点击标题旁的 **默认** 恢复。需要重新应用的配置会在左下角显示 **重载**。

快捷键可以自定义或单独关闭，CapsLock 基础键保留。厂商密钥在本机设置中输入，恢复默认不会清除密钥。详见[设置说明](tools/settings/README.md)。

## 常用快捷键

以下为默认键位，可在“功能与快捷键”中修改。

| 快捷键 | 功能 |
| --- | --- |
| `CapsLock` | 短按切换中英文，长按开启大写 |
| `Caps + F` | 翻译选中文字；没有选区时使用剪贴板 |
| `Caps + S` | 朗读选中文字，再按一次打断 |
| `Caps + I` | 框选截图并翻译，再按一次取消识别 |
| `Caps + G` | 搜索选中文字 |
| `Caps + D` | 切换音频输出 |
| `Caps + T` | 窗口置顶／取消置顶 |
| `Caps + H` | 最小化当前窗口 |
| `Caps + O` / `Caps + E` | 打开／定位选中目标 |
| `Ctrl + V` | 智能粘贴图片，其他内容正常粘贴 |
| `Alt + 反引号` | 切换同一应用的窗口，加 `Shift` 反向切换 |

## 配合 Raycast 使用

在 Raycast 添加 `tools/raycast-scripts` 目录，即可调用设置、截图、录屏、OCR、截图翻译、换壁纸和灯光切换等命令。

工具箱设置中的 **Raycast 脚本** 页可控制各入口是否启用；Raycast 自己的快捷键和别名仍在 Raycast 中配置。

## 遇到问题

先检查设置中的功能开关，再运行离线诊断：

```powershell
python tools/diagnostics/doctor.py
```

诊断不会发起翻译、朗读或截图。在线翻译和在线朗读会把待处理文本发送给对应服务；需要离线朗读时，在设置中选择本地引擎。

## 更多说明

| 文档 | 内容 |
| --- | --- |
| [安装、更新与回滚](docs/RELEASING.md) | 依赖安装、更新和恢复步骤 |
| [工具箱设置](tools/settings/README.md) | 自动保存、功能开关、快捷键和密钥 |
| [启动与维护](tools/startup/README.md) | 登录自启、看护、HUD 重建和电源重载 |
| [诊断](tools/diagnostics/README.md) / [测试](tools/validation/README.md) | 排查问题和开发验证 |
| [最新更新](docs/releases/2026-11-25-capture-results.md) | 已完成的改动与验证范围 |
| [后续计划](docs/ROADMAP.md) | 下一阶段的更新方向 |

模块细节：[翻译](tools/translate/README.md)、[朗读](tools/tts/README.md)、[灯光](tools/rgb/README.md)、[电源](tools/power-policy/README.md)。
