# power-policy v2

Caffeine（Raycast Coffee）决定合盖/空闲策略。睡眠指 Modern Standby（S0 Low Power Idle），休眠指 S4。

## 策略

| 设置 | Caffeine 开 | Caffeine 关 |
| --- | --- | --- |
| LIDACTION AC/DC | 0 / 0 | 1 / 1 |
| STANDBYIDLE AC/DC | 0 / 0 | 0 / 1800 秒 |
| HIBERNATEIDLE AC/DC | 0 / 0 | 0 / 3600 秒 |
| VIDEOIDLE AC/DC | 600 / 600 秒 | 600 / 600 秒 |

LenovoSmartStandby 必须保持 Stopped / Disabled。本工具不写 Lenovo 注册表，不启动该服务。
低电量、过热和手动睡眠等系统保护不被屏蔽。其他程序仍可以独立持有电源请求，本工具不提供全局独占白名单。

`config.toml` 的 `[wake] disable_timers = true` 独立控制 AC/DC 唤醒定时器，默认保持禁用策略。RTCWAKE 与其余设置一起在写入前备份，卸载时按电源计划恢复。旧备份缺少此字段时只补存当前值，不覆盖已有字段；旧版本已经丢失的历史原值无法推断恢复。

设备禁用也先持久化恢复日志，写档失败即停止禁用。卸载时仅删除成功恢复的设备记录；离线设备等恢复失败会保留存档并报错，设备可用后重跑卸载即可重试。JSON 使用统一 UTF-8 BOM，支持 Windows PowerShell 5.1 与 PowerShell 7 互读。

## 原生盖子通知与关屏

PowerNative.cs 使用 PowerSettingRegisterNotification + DEVICE_NOTIFY_CALLBACK；回调完全在 C# 内执行，不依赖 PowerShell 运行空间或 AHK GUI 生命周期。同时订阅 AC/DC 和恢复睡眠通知。

盖子状态只能来自当前进程的原生回调。未知值为 -1，不使用历史 506/507 或 Lenovo 日志推断当前状态。Caffeine 策略选择不依赖盖子状态，因此缺少盖子事件不会阻断保活策略。

2026-11-11 第一次手工测试确认：SC_MONITORPOWER 在本机导致约 220 秒常驻中断和 Modern Standby，已移除该指令及相关 user32 调用。

当前候选：仅 Caffeine 开且原生盖子状态为关闭时，将 VIDEOIDLE AC/DC 临时设为 1 秒，让 Windows 走自然显示空闲关屏；开盖、Caffeine 关闭、进程正常退出后恢复 600 秒。STANDBYIDLE 和 HIBERNATEIDLE 在 Caffeine 期间继续保持 0。订阅 GUID_CONSOLE_DISPLAY_STATE，记录真实系统显示状态（0 关闭、1 打开、2 变暗），并记录最大循环间隔。第二次插电手工短测已通过：2026-11-11 23:02:14 至 23:03:41，SleepStudy 为 Screen Off 87.018 秒，Sleep 0 秒，常驻最大循环间隔 1.601 秒，显示回调确认关屏/亮屏。此结论仅覆盖本次插电短测，电池和长时间运行仍待验证。

Power Request 每个句柄只申请一次；重复轮询不增加计数。AC/DC 切换和恢复睡眠后重建句柄。不再将请求当成 LIDACTION=1 的拦截器。

## 安装、预览、测试

在管理员终端运行 `tools/power-policy/Install-PowerPolicy.ps1`。安装会重启 PowerPolicy 常驻，移除旧 OnLidEvent 任务。单实例互斥；后台通过 Run-PowerPolicy.vbs 隐藏启动，该启动器保留退出码，供任务计划程序重启失败实例。保留仓库已有 Watchdog 兜底。

任务引擎固定为系统 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`，不依赖 Codex runtime 的版本目录。已有提权常驻启动时仅校验并迁移属于本仓库的任务 action，保留其他任务设置。日常优雅重载使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/power-policy/Restart-PowerPolicy.ps1`；它验证新鲜心跳身份及源码指纹后重启原任务，无需重装。

心跳新增 `identityVersion/scriptPath/repoRoot/startTicks/sourceFingerprint/hostPath`。普通权限看护交叉验证进程创建时间；`outdated` 与 `query-failed` 都不会重复启动。具体状态契约、发布回滚与真机验收见 `tools/startup/README.md`。

```powershell
pwsh -NoProfile -File ./tools/power-policy/PowerPolicy.ps1 -DryRun
pwsh -NoProfile -File ./tools/power-policy/Test-PowerPolicy.ps1
```

默认单次调用也是只读。DryRun 不写策略、服务、请求或恢复备份。测试不发送关屏/睡眠指令，但会在测试进程中短暂申请和释放电源请求，以及注册/注销回调。

config.toml 在每次常驻启动时读取，修改后需重启任务。Caffeine 状态校验 PID、进程创建 FILETIME、会话到期和 stop.flag；轮询默认 1 秒，期间存在最多约一个轮询间隔的开关响应延迟。

## 恢复与故障

首次变更每个电源计划前保存四项设置，文件为 `%LOCALAPPDATA%/lat3ncy-toolbox/power-policy-backup-<GUID>.json`；已有备份不覆盖。修改后只激活一次，回读验证；失败则回滚该批设置。设置相同时不重复写入/激活。

Caffeine 关闭/退出后恢复上表关闭策略。常驻正常退出或抛出异常时释放请求并恢复关闭策略；任务失败由计划程序重试，已有 Watchdog 亦可拉起。强制杀进程/系统崩溃无法执行 finally，重启常驻后重新读真实 Caffeine 状态并纠正策略，不能保证进程完全停止期间立即恢复。

管理员运行 Uninstall-PowerPolicy.ps1 会发送优雅停止信号、删除任务、恢复备份电源设置；不会重新启用 Lenovo。

诊断文件：

- `%LOCALAPPDATA%/lat3ncy-toolbox/power-policy.log`
- `%LOCALAPPDATA%/lat3ncy-toolbox/power-policy-status.json`（当前 PID、Caffeine、供电、原生状态/回调计数、注册错误码、请求状态）

## 手工验收

先确认原生初始状态为打开、Caffeine 开启、四项策略回读正确，再通知用户合盖。

1. 插电+Caffeine 开，合盖约 2 分钟后开盖，检查原生闭/开回调及任务是否连续运行。
2. 电池+Caffeine 开，保持至少 45 分钟，覆盖旧 30 分钟睡眠超时再加 5 分钟限制。
3. 合盖期间插拔电源，检查供电回调和请求重建。
4. Caffeine 关，确认空闲睡眠 30 分钟、电池休眠 60 分钟基线恢复；合盖后开关 Caffeine 需单独验收。

用实际任务进度与 SleepStudy 的 Screen Off / Sleep 分段交叉核对。506/507 本身不能证明应用曾暂停，也不能单凭 DRIPS 时间判断任务连续性。

微软参考：

- [PowerSetRequest](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-powersetrequest)
- [原生通知回调](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powersettingregisternotification)
- [显示与睡眠计时器](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/display--sleep--and-hibernate-idle-timers)
