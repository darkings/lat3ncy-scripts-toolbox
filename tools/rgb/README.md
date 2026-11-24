# RGB Ambient

桌面实时取色 -> 技嘉 B550M DS3H 风扇 + Hi75 键盘。

OpenRGB 由 **官方 Windows 系统服务** 常驻，之后只复用 `127.0.0.1:6742`。`ambient.py` 不启动、不重启 OpenRGB。项目目录不携带 `OpenRGB.exe` / PawnIO 安装包。

## 架构

```
mss 中心320x180 step=8 --丢弃黑场--> 亮像素饱和度加权均值 --> EMA
        --> OpenRGB Direct(可较勤) + Hi75 Direct 0x08(限频/限色差)
        静止 6Hz / 活动 12Hz；切场黑帧保持上一色
当前生产: fps 12/6 threshold=6 ema_alpha=0.18 lerp_alpha=0.50 sat_boost=1.25 min_brightness=22
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

* `ambient.py` — 主程序（`--dry-run/--bench/--bench-capture/--time/--fps/--lights-off`）
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
* `Stop-Ambient.ps1` — 先写本仓库的 `rgb-quit-<scope>.flag` 让 ambient 推 Direct 全黑再退出；失败才强杀。不碰 OpenRGB
* `Install-Ambient.ps1` — 登录任务 `RGB-Ambient`（直接 `pythonw`，+15s 等 DWM；注册任务需要提权）
* `../raycast-scripts/toggle-rgb.ps1` — Raycast 单切换。只动 `%LOCALAPPDATA%\lat3ncy-toolbox\rgb-disabled.flag`，不杀 Ambient、不停 OpenRGB 服务

## 进程归属与并发

启动、停止、安装、设置重载和 Raycast 切换共用跨会话控制互斥体；硬件写入者另持全局互斥体，覆盖退出时推黑及一次性设备命令。其他 checkout、遗留孤立 Hi75、无法读取的元数据或占用时拒绝操作，不把未知状态当作未运行。不会启动或停止 OpenRGB 服务。离线合成帧 bench 与 dry-run 不占写入锁。

停止依据绝对脚本路径、PID 创建 FILETIME 和父子身份；最终终止前再次核对并持有已验证进程对象。固定任务 `\RGB-Ambient` 也必须属于本仓库，外部同名任务不更新、不停止。设置重载复用相同的停止链路并重新检查归属后启动。

退出请求使用 `rgb-quit-<scope>.flag`（仓库绝对路径哈希），包含请求 ID、有效期和每个目标的 PID/创建时间；新进程、过期请求和其他仓库不会响应。旧的全局 `rgb-quit.flag` 不再读写或删除。旧版常驻可能不识别新请求，超时后仅终止已验证的本仓库进程；不能据此保证旧程序一定完成推黑。`rgb-disabled.flag` 仍保留当前用户的全黑偏好。

直接运行 `ambient.py` 也在打开抓屏/设备之前执行归属预检。`hi75.py` 单独维护命令和外部 OpenRGB 客户端不参与本仓库锁，勿与 Ambient 同时手动控制设备。路径无法证明一致时保守拒绝，不自动接管外部实例。

测试：`python -S -m unittest discover -s tools/rgb -p 'test_*.py' -v` 与 `python -S -m unittest discover -s tools/validation -p test_rgb_ownership.py -v`。只使用隔离元数据、进程桩和唯一测试互斥体，不连接 SDK/HID、不抓屏、不修改系统任务；真实灯光和跨用户会话的设备效果另行验收。

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
# Raycast：Toggle RGB Lights。关灯只推 Direct 全黑，Ambient 继续跑
powershell -NoProfile -ExecutionPolicy Bypass -File tools/raycast-scripts/toggle-rgb.ps1
# Ambient 没在跑时一次性关灯（已在跑不要调，会抢 HID）
python tools/rgb/ambient.py --lights-off
Get-Content tools/rgb/logs/ambient.out.log -Tail 20 -Wait
```

## 开关灯 / 关机推黑

Raycast 只有一个 `toggle-rgb.ps1`。旗标：

```text
%LOCALAPPDATA%\lat3ncy-toolbox\rgb-disabled.flag
```

* **关灯**：写旗标。Ambient 仍保持运行，风扇和 Hi75 都推 Direct `#000000`，并继续 keepalive / HID 重连。关灯期间不抓屏。
* **开灯**：删旗标。Ambient 下一帧取色后立刻推灯，不等下一次明显色差。
* **Direct 全黑必须 keepalive**：Hi75 `0x08` 约 1 秒不刷新会掉回板载彩虹，不是自动关灯。
* **拔插键盘**：`hi75.exe --serve` 没插键盘时约 50ms 轮询；只等 Col06，不抢先打开 Col05。设备在但 Col06 未就绪先短重试，打不开才 1/2/4/8/16/30s 退避。成功后立刻发 `0x84` 握手并连发 Direct。关灯状态下插上强制 Direct `#000000`，不重放掉线前的彩色。USB 上电到 HID 打开之前的板载灯效无法用软件完全挡住，只能把闪灯压到枚举完成之后立刻盖住。
* **正常停止**：`Stop-Ambient.ps1` 先写本仓库的 `rgb-quit-<scope>.flag`，ambient `finally` 推黑再退出。
* **正常关机**：隐藏顶层窗口收 `WM_QUERYENDSESSION`，尽量先推黑。突然断电 / 硬断电软件发不出 HID，只能靠 BIOS。
* **BIOS 兜底**：开启 `ErP Ready`，关闭 `RGB lighting in S5` / `LEDs in sleep/shutdown`。Windows 快速启动也可能让硬件停在类似 S4。
* **不要停 OpenRGB 服务**，也不要改主题调度器。

## 排错

* `HidD_SetFeature 0x01` → 用 `Col06`；关官方驱动，并避免 OpenRGB 占用 Hi75
* `OpenRGB connect failed` / 只有键盘变色、主板不动 → 看 `logs/ambient.out.log` 是否 `timed out`。服务在听 6742 也会握手失败；现在会按 2/4/8/16/30s 重连，不必重启。确认 `Get-Service OpenRGB` 为 Running，不要开 OpenRGB GUI
* 启动弹出终端，内容是 `[ambient] SDK 6742 not ready...` / `started PID ...` → 那是旧的 `powershell.exe -File Start-Ambient.ps1 -Wait` 在 `Write-Host`。Win11 默认终端会显示这个 CUI waiter。现在任务直接跑 `pythonw`；`Start-Ambient.ps1` 拉起后立刻返回，`-Wait` 也不再挂起。更新任务：`Install-Ambient.ps1`。若弹的是空 Windows Terminal：旧 `--console` `hi75.exe`，重跑 `build_hi75.ps1`（`--noconsole`）
* `dxcam hang` → 默认 `mss`，不要用 auto 里的 dxcam 作首选
* `BitBlt` / `ScreenShotError` → 当前没有可用交互桌面会话（Session 0 / 无显示器抓屏）。这不是 OpenRGB 服务或 `hi75.exe` 损坏；日常压测用 `--bench`，不要把 `--bench-capture` 失败当成硬件故障
* 服务日志：`C:\Program Files\OpenRGB\service_config\logs`

## 随仓依赖补丁

`lib/openrgb/network.py` 保留本仓库的网络修复：头部和包体使用 `recv_exact` 收满，EOF 立即断开，失败清理不重复释放锁。更新随仓 OpenRGB Python 库时须保留或确认上游已包含这些行为，并运行 `python -m unittest discover -s tools/rgb -p test_protocols.py`。该测试只使用本机 socket pair 和测试子进程，不连接 SDK 或 HID。
