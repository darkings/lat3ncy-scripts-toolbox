# RGB Ambient

桌面实时取色 -> 技嘉 B550M DS3H 风扇 + Hi75 键盘。

OpenRGB 由 **官方 Windows 系统服务** 常驻，之后只复用 `127.0.0.1:6742`。`ambient.py` 不启动、不重启 OpenRGB。项目目录不携带 `OpenRGB.exe` / PawnIO 安装包。

## 架构

```
mss 中心320x180 step=8 --丢弃黑场--> 亮像素饱和度top30% --> EMA
        --> OpenRGB Direct(可较勤) + Hi75 Direct 0x08(限频/限色差)
        静止 6Hz / 活动 12Hz；切场黑帧保持上一色
当前生产: fps 12/6 threshold=6 ema_alpha=0.18 lerp_alpha=0.35 min_brightness=22
早期压测(历史): threshold=8 brightness=16 12Hz；中间版本曾用 8/4Hz threshold=14 ema=0.35
```

开机后：

```
PawnIO（winget）
  -> 系统服务 OpenRGB（LocalSystem, delayed-auto, 无窗口）
       C:\Program Files\OpenRGB\OpenRGB.exe
       配置：C:\Program Files\OpenRGB\service_config\
       监听 127.0.0.1:6742
登录 +15s
  -> 任务 RGB-Ambient（当前用户、普通权限、直接 pythonw，不包 powershell）
       pythonw -u ambient.py
       dist/hi75/hi75.exe --serve
```

## 文件

* `ambient.py` — 主程序（`--dry-run/--bench/--bench-capture/--time/--fps`）
* `config.toml` — 阈值/FPS/EMA/亮度/HID 路径
* `hi75.py` — Hi75 单控（`--list/--preset/--color/--off/--serve`）
* `dist/hi75/hi75.exe` — `--onedir` 打包的 `--serve` 子进程（任务管理器里只有一个进程）。**被 gitignore，换机先跑 `build_hi75.ps1`，不要误删本机已有产物**
* `hi75_data/` — 520B Feature 报文（static_* / complete_off_*），入库以便免 pip 换机运行
* `lib/{mss,openrgb,dxcam,comtypes}` + `lib_hid/hid.pyd` — 免 pip 的 HID/OpenRGB/mss，入库
* `build_hi75.ps1` — 用 PyInstaller `--onedir --noconsole` 生成 `dist/hi75/hi75.exe`（GUI 子系统，后台不弹终端）
* `install.ps1` — winget 安装 PawnIO + 官方 OpenRGB 系统服务（`INSTALLLEVEL=2`）
* `Start-OpenRGB.ps1` — 6742 已监听则直接退出；否则启动系统服务
* `Stop-OpenRGB.ps1` — 停止系统服务（日常 ambient 不要调用）
* `Start-Ambient.ps1` — 无窗口拉起 `pythonw ambient.py` 后立刻返回；不再 `powershell -Wait`（那会弹出 SDK/PID 那几行）；已在跑则复用
* `Stop-Ambient.ps1` — 结束 ambient / hi75.exe，不碰 OpenRGB
* `Install-Ambient.ps1` — 登录任务 `RGB-Ambient`（直接 `pythonw`，+15s 等 DWM；注册任务需要提权）

## 一次性准备

```powershell
# 管理员：winget 官方 MSI + 系统服务。不要手动开 OpenRGB 窗口
powershell -NoProfile -ExecutionPolicy Bypass -File tools/rgb/install.ps1
# 灯管正常后删除项目内便携包
powershell -NoProfile -ExecutionPolicy Bypass -File tools/rgb/install.ps1 -PruneBundled
# 或只确保 SDK：已在 6742 则什么都不做
powershell -NoProfile -ExecutionPolicy Bypass -File tools/rgb/Start-OpenRGB.ps1
# 当前用户：登录常驻 ambient（无窗口，延迟 15s 等 DWM）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/rgb/Install-Ambient.ps1
```

## 日常

```powershell
python tools/rgb/hi75.py --list
python tools/rgb/ambient.py --bench 20                 # 合成帧：只跑 process_frame，不抓屏、不写灯
python tools/rgb/ambient.py --bench 20 --bench-capture # 真实抓屏；Session 0 / 无桌面时 mss BitBlt 会失败
python tools/rgb/hi75.py --preset red
python tools/rgb/hi75.py --color 00ff00
python tools/rgb/ambient.py --dry-run --time 3
# 前台调试（有窗口）；常驻请用 Start-Ambient.ps1
python tools/rgb/ambient.py --time 10
powershell -NoProfile -ExecutionPolicy Bypass -File tools/rgb/Start-Ambient.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/rgb/Stop-Ambient.ps1
Get-Content tools/rgb/logs/ambient.out.log -Tail 20 -Wait
```

## 排错

* `HidD_SetFeature 0x01` → 用 `Col06`；关官方驱动，并避免 OpenRGB 占用 Hi75
* `OpenRGB connect failed` / 只有键盘变色、主板不动 → 看 `logs/ambient.out.log` 是否 `timed out`。服务在听 6742 也会握手失败；现在会按 2/4/8/16/30s 重连，不必重启。确认 `Get-Service OpenRGB` 为 Running，不要开 OpenRGB GUI
* 启动弹出终端，内容是 `[ambient] SDK 6742 not ready...` / `started PID ...` → 那是旧的 `powershell.exe -File Start-Ambient.ps1 -Wait` 在 `Write-Host`。Win11 默认终端会显示这个 CUI waiter。现在任务直接跑 `pythonw`；`Start-Ambient.ps1` 拉起后立刻返回，`-Wait` 也不再挂起。更新任务：`Install-Ambient.ps1`。若弹的是空 Windows Terminal：旧 `--console` `hi75.exe`，重跑 `build_hi75.ps1`（`--noconsole`）
* `dxcam hang` → 默认 `mss`，不要用 auto 里的 dxcam 作首选
* `BitBlt` / `ScreenShotError` → 当前没有可用交互桌面会话（Session 0 / 无显示器抓屏）。这不是 OpenRGB 服务或 `hi75.exe` 损坏；日常压测用 `--bench`，不要把 `--bench-capture` 失败当成硬件故障
* 服务日志：`C:\Program Files\OpenRGB\service_config\logs`
