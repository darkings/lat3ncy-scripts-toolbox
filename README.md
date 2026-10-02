# lat3ncy-scripts-toolbox

个人 Windows 工具集：AutoHotkey v2 快捷键 + 一组 PowerShell/Python 小工具（翻译、朗读、音频切换、RGB、OCR、主题调度）。

各工具的细节写在 `tools/*/README.md`，这里只给总览和常用命令。

## 快速开始

```powershell
# 需要先装 AutoHotkey v2，并让命令行能找到引擎（自启脚本和测试都依赖它）
Get-Command AutoHotkey.exe

# 启动工具箱
AutoHotkey.exe .\ahk\main.ahk
```

登录自启由启动文件夹里的快捷方式负责，它指向：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\startup\Start-Toolbox.ps1
# 失败原因（含 AHK 启动错误）看这里
Get-Content "$env:LOCALAPPDATA\lat3ncy-toolbox\startup.log" -Tail 20
```

跑测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ahk\tests\run-tests.ps1
```

## 快捷键

改键只编辑 `ahk/shortcuts.ahk`；`ahk/hotkey-router.ahk` 负责校验和注册，`ahk/features/` 只实现功能。两个功能抢占同一快捷键会在启动时报错，不会静默覆盖。

| 快捷键 | 功能 |
| --- | --- |
| `CapsLock` | 短按切中/英（记住，切窗口后恢复）；250–500ms 松开取消；长按进大写 |
| `Caps + S` | 朗读选中文字，再按一次打断 |
| `Caps + F` | 划词翻译（无选区则译剪贴板），光标处弹译文面板 |
| `Caps + G` | Google 搜索选中文字 |
| `Caps + O` | 打开选中的文件、目录或 URL |
| `Caps + E` | 在资源管理器中定位选中目标 |
| `Caps + T` | 活动窗口置顶 / 取消置顶 |
| `Caps + H` | 按 Z-order 逐个最小化可见窗口 |
| `Caps + .` / `Caps + ,` | 切换隐藏文件 / 切换当前文件夹顶层点文件 |
| `Caps + X` | 切换文件扩展名显示 |
| `Caps + Q` / `Caps + R` | 结束 / 重启前台窗口的进程 |
| `Caps + D` | 切换音频输出 `G27Q2 ↔ AirPods`（自动连接） |
| `Ctrl + V` | 智能粘贴：剪贴板是图片时存成本地 PNG，其余原样透传 |
| `Alt` + 反引号 / `Shift + Alt` + 反引号 | 同一应用窗口间正 / 反向循环（Zed 走项目切换） |
| 无快捷键 | 快速左右摇鼠标 → 指针临时放大（1.4s 后恢复） |

## 工具

| 工具 | 说明 |
| --- | --- |
| `tools/translate/` | `Caps+F` 的翻译后端，腾讯云 TMT 为主，可回退 |
| `tools/tts/` | `Caps+S` 语音朗读，Edge Neural + 本地音色，本地缓存 |
| `tools/audio-switcher/` | `Caps+D` 音频切换（`--toggle` / `--ensure-headset` / `--list`） |
| `tools/rgb/` | 桌面取色联动风扇与键盘灯，OpenRGB 走系统服务 |
| `tools/ime-hud-winui/` | CapsLock 状态芯片与翻译面板（WinUI 3），改了必须重载 |
| `tools/raycast-scripts/` | Raycast Script Commands，见下表 |
| `tools/theme-scheduler/` | 按日出日落切深浅色 / 壁纸 / 鼠标方案 |
| `tools/startup/` | 登录自启入口 |
| `resources/cursors/` | 9 套鼠标配色，供 theme-scheduler 使用 |

Raycast 里添加 `tools/raycast-scripts` 目录即可用，可逐个绑 Hotkey：

| 脚本 | 功能 |
| --- | --- |
| `restart-autohotkey.ps1` | 重启本工具箱的 `main.ahk` |
| `screenshot.ps1` / `record-screen.ps1` | 截图 / 录屏框选 |
| `screenshot-ocr.ps1` | 屏幕区域 OCR（`system` 或 RapidOCR） |
| `toggle-rgb.ps1` | 开关风扇 + 键盘灯 |
| `next-wallpaper.ps1` | 换成图池里的下一张壁纸（同时设锁屏） |
| `codex-switch.ps1` | Codex 状态 / OpenAI / 中转切换 |

## 需要配置的地方

几个 TOML，都在各自工具目录里，仓库里的模板留空：

- `tools/translate/config.toml`：`engine = "tencent"`。密钥优先读用户环境变量 `TENCENTCLOUD_SECRET_ID` / `TENCENTCLOUD_SECRET_KEY`，其次读配置文件。密钥缺失/无效会弹 Toast，不会静默回退。
- `tools/theme-scheduler/config.toml`：`switch_type`、`schedule.trigger_mode`（`sun` / `fixed`）、壁纸目录、`[cursor]` 配色。
- `tools/tts/config.toml` / `tools/audio-switcher/config.toml`：音色、设备关键字。

装依赖（按需）：

```powershell
python .\tools\tts\install-deps.py                 # 朗读
python .\tools\raycast-scripts\ocr\install-deps.py # RapidOCR
```

主题调度的五个计划任务用脚本注册，不要手写 `schtasks /create`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\theme-scheduler\Install-ThemeScheduler.ps1
schtasks /run /tn "Theme-Light"   # 立即切浅色；同理 Theme-Dark
```

> **注册脚本必须提权运行**：`Theme-Apply-Now` / `Theme-Apply-Cursors` 是提权创建的，非管理员重注册会对它们报 `Access is denied`（其余三个能过）。提权重跑一次即可全部更新。
>
> **任务是无窗口的，靠 `wscript.exe` 外壳实现**：任务计划程序不能直接跑 `powershell.exe`——它是控制台程序，以交互方式在用户会话里启动时会分配真实控制台，导致**睡眠唤醒/解锁时屏幕上蹦出一个终端窗口**；任务的 `-Hidden` 只作用于任务自身，管不到子进程。
> `Get-ThemeHiddenAction` 会为每个脚本生成一个 VBS shim（`%LOCALAPPDATA%\lat3ncy-toolbox\theme-tasks\<脚本名>.vbs`），任务改为 `wscript.exe "<shim>"`；shim 里用 `WshShell.Run(cmd, 0, True)` 静默等待 PowerShell 跑完，任务状态仍准确。
> **不要再用 `conhost.exe --headless` 当外壳**——`--headless` 不是"隐藏窗口"开关（它是 ConPTY/终端集成的标志），直接由计划任务启动时照样会出窗口；这个坑 2026-10-02 已修复并复验。

RGB Ambient（首次需管理员装官方 OpenRGB 服务，之后日常不用管）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\install.ps1
python tools\rgb\ambient.py --dry-run --time 5
```

## 通知约定

功能模块统一用 `Notify.State() / Info() / Success() / Error()`，不要自己造 GUI 或直接 `ToolTip`。状态类走 WinUI HUD（失败回退 AHK 芯片），成功/失败走系统 Toast。改了锚点或 HUD 代码后必须跑 `tools/raycast-scripts/reload-ime-hud.ps1`，否则常驻进程里跑的还是旧 exe。

## 仓库结构

```text
ahk/                 main.ahk 入口、shortcuts.ahk 快捷键、hotkey-router.ahk 路由、features/、tests/
shared/              python.ahk（pythonw 解析）、notify/（HUD、Toast、锚点）
tools/               各工具与 Raycast 命令（见上表）
resources/           鼠标配色
findings.md          研究与决策记录
progress.md          会话进度
task_plan.md         阶段任务计划
```

## 已知坑

- 命令行找不到 `AutoHotkey.exe` 时，自启脚本和测试都会失败；把安装目录加进 `PATH` 后重开终端。
- Scoop 的 `apps\autohotkey\current` 正常应是 junction，变成实目录后 `scoop update` 会半删除它：先停 AHK，删掉 `current`，再用 `New-Item -ItemType Junction` 指回版本目录。
- 锁屏壁纸脚本必须由 Windows PowerShell 5.1 执行（WinRT 互操作），文件要保持 UTF-8 BOM；`ahk/tests/run-tests.ps1` 需要 CRLF。
