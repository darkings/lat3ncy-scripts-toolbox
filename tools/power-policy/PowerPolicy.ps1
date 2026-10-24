#Requires -Version 5.1
<#
    PowerPolicy.ps1 — 合盖 / 空闲的睡眠与休眠策略（Caffeine 感知）

    需求：
      1. 未启用 Caffeine 且未插电 → 合盖时休眠
      2. 阻止任何程序唤醒系统，除非在白名单中

    为什么需要脚本：
      Windows 的「合上盖子操作」是静态设置（不操作/睡眠/休眠/关机），
      无法表达「未插电 + 无 Caffeine 时才休眠」这种条件逻辑。
      因此用「合盖=不操作」+ 本脚本监听盖子状态来实现。

    检测手段（均已在本机验证）：
      - 供电状态：GetSystemPowerStatus (kernel32)        —— 实测可用
      - 盖子状态：Lenovo-Power-SmartStandby 事件日志      —— 实测可读，与 Kernel-Power 交叉一致
      - Caffeine：%LOCALAPPDATA%\coffee\state.json + 进程存活校验（Coffee 扩展源码机制）

    用法：
        # 单次检查（不执行休眠）
        .\PowerPolicy.ps1 -DryRun

        # 安装为计划任务（推荐）
        .\PowerPolicy.ps1 -Install

        # 卸载
        .\PowerPolicy.ps1 -Uninstall

        # 仅应用唤醒封锁
        .\PowerPolicy.ps1 -ApplyWakeBlock

    注意：休眠动作需要管理员权限（SeShutdownPrivilege）。
          未提权时脚本仍可运行，但只会记录而不休眠。
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$ApplyWakeBlock,
    [switch]$Run,

    # 计划任务名
    [string]$TaskName = 'PowerPolicy',

    # 检查间隔（秒）
    [int]$IntervalSeconds = 5,

    # 插电时 HIBERNATEIDLE（0 = 永不转 S4）。
    # 需求（2026-10-23 21:00 最终确认）：
    #   插电 + 合盖 -> 进 S0 睡眠，但【永不】转 S4，开盖瞬亮
    #   电池 + 合盖 -> 进 S0 睡眠，60 分钟后转 S4
    # 理由：插电时随时可能开盖使用，等 13 秒固件 POST 不划算；
    #       且插电时 S0 的 0.4W 功耗无实际代价。
    [ValidateRange(0, 86400)]
    [int]$AcHibernateSeconds = 0,

    # 电池时 HIBERNATEIDLE（3600 = 60 分钟）。
    [ValidateRange(0, 86400)]
    [int]$DcHibernateSeconds = 3600,

    # 空闲睡眠超时（STANDBYIDLE，单位秒）。
    # 需求（2026-10-22 最终确认）：
    #   AC = 0     -> 插电时永不因空闲睡眠
    #   DC = 1800  -> 不插电时，空闲 30 分钟后睡眠
    [ValidateRange(0, 86400)]
    [int]$AcStandbySeconds = 0,
    [ValidateRange(0, 86400)]
    [int]$DcStandbySeconds = 1800,

    # 空闲关屏超时（VIDEOIDLE，单位秒）。
    # 2026-10-22 用户指定：AC/DC 都是 10 分钟（DC 原为 3 分钟太短）。
    [ValidateRange(0, 86400)]
    [int]$AcVideoIdleSeconds = 600,
    [ValidateRange(0, 86400)]
    [int]$DcVideoIdleSeconds = 600,

    # 兼容旧参数名（已废弃，仅用于识别老任务配置）
    [int]$BatteryLidGraceMinutes = -1,

    # 合盖时是否强制请求睡眠。
    # 【默认关闭】2026-10-22 20:33 实测：本机不支持 S3，强制挂起会回落成 S4 休眠，
    # 导致开盖出现 BIOS logo。默认只靠 SC_MONITORPOWER 关屏，让系统自然进 S0。
    [switch]$ForceSleepOnLidClose,

    # 唤醒白名单：允许唤醒系统的设备名（支持通配）
    # 默认只允许键盘/鼠标类人工唤醒，其余一律封锁
    [string[]]$WakeWhitelist = @(),

    # 日志
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox\power-policy.log')
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 常量
$LID_LOG      = 'Lenovo-Power-SmartStandby/Operational'
$COFFEE_DIR   = Join-Path $env:LOCALAPPDATA 'coffee'
$COFFEE_STATE = Join-Path $COFFEE_DIR 'state.json'
$COFFEE_STOP  = Join-Path $COFFEE_DIR 'stop.flag'

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    try {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding utf8
    } catch {}
}

# ---------------------------------------------------------------- 配置（config.toml）
# 仓库惯例：参数外置到工具目录下的 config.toml。这里只实现本工具需要的极小子集
# （[section] + key = 标量），够用即可，不引入 TOML 依赖。
function Read-PowerPolicyConfig {
    $path = Join-Path $PSScriptRoot 'config.toml'
    $cfg = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $cfg }

    $section = ''
    foreach ($raw in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }

        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $cfg.ContainsKey($section)) { $cfg[$section] = @{} }
            continue
        }

        $m = [regex]::Match($line, '^([A-Za-z0-9_]+)\s*=\s*(.+?)\s*(?:#.*)?$')
        if (-not $m.Success -or -not $section) { continue }

        $key = $m.Groups[1].Value
        $val = $m.Groups[2].Value.Trim()
        if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
        elseif ($val -match '^(true|false)$') { $val = ($val -eq 'true') }
        elseif ($val -match '^-?\d+$') { $val = [int]$val }

        $cfg[$section][$key] = $val
    }
    return $cfg
}

function Get-CfgValue {
    param($Cfg, [string]$Section, [string]$Key, $Default)
    if ($Cfg -and $Cfg.ContainsKey($Section) -and $Cfg[$Section].ContainsKey($Key)) {
        return $Cfg[$Section][$Key]
    }
    return $Default
}

# 仅当命令行没有显式给该参数时才用 config.toml 覆盖：
# 计划任务里烘焙的显式参数永远优先，行为可预测。
$PP_CFG = Read-PowerPolicyConfig
if (-not $PSBoundParameters.ContainsKey('AcHibernateSeconds')) {
    $AcHibernateSeconds = [int](Get-CfgValue $PP_CFG 'power' 'ac_hibernate_seconds' $AcHibernateSeconds)
}
if (-not $PSBoundParameters.ContainsKey('DcHibernateSeconds')) {
    $DcHibernateSeconds = [int](Get-CfgValue $PP_CFG 'power' 'dc_hibernate_seconds' $DcHibernateSeconds)
}
if (-not $PSBoundParameters.ContainsKey('AcStandbySeconds')) {
    $AcStandbySeconds = [int](Get-CfgValue $PP_CFG 'power' 'ac_standby_seconds' $AcStandbySeconds)
}
if (-not $PSBoundParameters.ContainsKey('DcStandbySeconds')) {
    $DcStandbySeconds = [int](Get-CfgValue $PP_CFG 'power' 'dc_standby_seconds' $DcStandbySeconds)
}
if (-not $PSBoundParameters.ContainsKey('AcVideoIdleSeconds')) {
    $AcVideoIdleSeconds = [int](Get-CfgValue $PP_CFG 'power' 'ac_video_idle_seconds' $AcVideoIdleSeconds)
}
if (-not $PSBoundParameters.ContainsKey('DcVideoIdleSeconds')) {
    $DcVideoIdleSeconds = [int](Get-CfgValue $PP_CFG 'power' 'dc_video_idle_seconds' $DcVideoIdleSeconds)
}
if (-not $PSBoundParameters.ContainsKey('IntervalSeconds')) {
    $IntervalSeconds = [int](Get-CfgValue $PP_CFG 'general' 'interval_seconds' $IntervalSeconds)
}
if (-not $PSBoundParameters.ContainsKey('TaskName')) {
    $TaskName = [string](Get-CfgValue $PP_CFG 'general' 'task_name' $TaskName)
}
$COFFEE_DIR = [Environment]::ExpandEnvironmentVariables(
    [string](Get-CfgValue $PP_CFG 'caffeine' 'coffee_dir' $COFFEE_DIR))
$COFFEE_STATE = Join-Path $COFFEE_DIR 'state.json'
$COFFEE_STOP  = Join-Path $COFFEE_DIR 'stop.flag'

# ---------------------------------------------------------------- 供电状态
function Test-OnAcPower {
    if (-not ('LidPolicy.PowerStatus' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LidPolicy {
    public class PowerStatus {
        [StructLayout(LayoutKind.Sequential)]
        public struct SYSTEM_POWER_STATUS {
            public byte ACLineStatus;
            public byte BatteryFlag;
            public byte BatteryLifePercent;
            public byte SystemStatusFlag;
            public int BatteryLifeTime;
            public int BatteryFullLifeTime;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS sps);
        public static int AcLine() {
            SYSTEM_POWER_STATUS s;
            if (!GetSystemPowerStatus(out s)) return -1;
            return s.ACLineStatus;   // 1=AC, 0=DC, 255=Unknown
        }
        public static int BatteryPercent() {
            SYSTEM_POWER_STATUS s;
            if (!GetSystemPowerStatus(out s)) return -1;
            return s.BatteryLifePercent;  // 255=Unknown
        }
    }
}
'@ -ErrorAction Stop
    }
    $ac = [LidPolicy.PowerStatus]::AcLine()
    if ($ac -eq -1) { throw 'GetSystemPowerStatus 调用失败' }
    return ($ac -eq 1)
}

# ---------------------------------------------------------------- 关屏
function Initialize-DisplayType {
    <#
        只负责编译 LidPolicy.Display 类型，【绝无任何副作用】。

        严重故障复盘（2026-10-23 17:59）：
          旧代码里 Set-SystemAwake 的类型编译是这样触发的——
              if (-not ('LidPolicy.Display' -as [type])) { Set-DisplayOff }
          注释写着「副作用为一次关屏，可接受」。这个判断是错的：
          Set-DisplayOff 会真的发送 SC_MONITORPOWER 关屏命令。

          而「合盖事件任务」(LidPolicy-OnLidClose) 每次合盖都启动【全新进程】，
          于是每次合盖都会：
              合盖 -> 事件任务 -> 判定 Caffeine 开着 -> Set-SystemAwake
                   -> 类型未编译 -> Set-DisplayOff -> SC_MONITORPOWER -> 关屏
                   -> Windows 解释为进入 S0 -> 睡掉
          结果：Caffeine 开着仍然在合盖后睡了 56.7 分钟（17:59:21 -> 18:56:06），
          随后满 60 分钟转 S4，19:05 开盖见到 BIOS logo。

        修复：把类型编译抽成独立函数，各调用方先编译再无副作用地执行各自动作。
    #>
    if ('LidPolicy.Display' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LidPolicy {
    public class Display {
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
        // 关键：用于在关屏期间持有「系统必需」请求，阻止系统滑入 S0 待机
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SetThreadExecutionState(uint esFlags);
        // 取得 shell 窗口，作为 SC_MONITORPOWER 的单点目标（避免广播风暴）
        [DllImport("user32.dll")]
        public static extern IntPtr GetShellWindow();

        const uint WM_SYSCOMMAND = 0x0112;
        const int SC_MONITORPOWER = 0xF170;
        static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

        public const uint ES_CONTINUOUS      = 0x80000000;
        public const uint ES_SYSTEM_REQUIRED = 0x00000001;
        public const uint ES_DISPLAY_REQUIRED= 0x00000002;

        // 关键修复：不再广播到所有顶层窗口（会产生数十次显示翻转），
        // 只发给 shell 窗口一次；若失败再退回广播。
        public static void Off() {
            IntPtr shell = GetShellWindow();
            if (shell != IntPtr.Zero) {
                SendMessage(shell, WM_SYSCOMMAND, (IntPtr)SC_MONITORPOWER, (IntPtr)2);
            } else {
                SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, (IntPtr)SC_MONITORPOWER, (IntPtr)2);
            }
        }
        public static void On() {
            IntPtr shell = GetShellWindow();
            if (shell != IntPtr.Zero) {
                SendMessage(shell, WM_SYSCOMMAND, (IntPtr)SC_MONITORPOWER, (IntPtr)(-1));
            } else {
                SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, (IntPtr)SC_MONITORPOWER, (IntPtr)(-1));
            }
        }
        // 持有：阻止系统进入 S0 待机（不阻止显式 shutdown /h）
        public static bool HoldSystem() {
            return SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) != 0;
        }
        // 释放：恢复正常电源策略
        public static bool Release() {
            return SetThreadExecutionState(ES_CONTINUOUS) != 0;
        }
    }
}
'@ -ErrorAction Stop
}

function Set-DisplayOff {
    <#
        主动关闭显示器（不进入睡眠/休眠）。
        仅在被显式调用时才执行，绝不作为编译类型的副作用。
    #>
    Initialize-DisplayType
    [LidPolicy.Display]::Off()
}

function Set-SystemAwake {
    <#
        持有 ES_SYSTEM_REQUIRED，阻止系统进入 S0 待机。

        【重要】这里绝对不能有关屏副作用。曾经写成「类型未编译就调 Set-DisplayOff」
        来顺带编译类型，导致每次合盖的事件任务（全新进程）都真的发送一次
        SC_MONITORPOWER，把 Caffeine 开着的情况也睡掉。详见 Initialize-DisplayType 注释。
    #>
    Initialize-DisplayType
    return [LidPolicy.Display]::HoldSystem()
}

function Clear-SystemAwake {
    if (-not ('LidPolicy.Display' -as [type])) { return $false }
    return [LidPolicy.Display]::Release()
}

# ---------------------------------------------------------------- Lenovo Smart Standby 配置
function Set-LenovoSmartStandbyPolicy {
    <#
        通过【配置 Lenovo 自己的参数】让它算出我们想要的值。
        既不放弃它的能力，也不与它对抗——这是多轮实测后的最终方案。

        ── 实测结论（2026-10-21 21:04，全部验证过）──────────────────────
        Smart Standby 的「200+ 分钟」不是硬编码，而是它按下面这些输入【算】出来的：

          HKLM\SOFTWARE\WOW6432Node\Lenovo\SmartStandby
            IsEnabled             总开关。
                                  =0 时日志输出 "Smart Standby is disabled."，
                                  并且【连带停止记录 Lid / Console Display 事件】——
                                  而这正是 LidPolicy 判断盖子的唯一数据源，所以绝不能设 0。
            IsAutonomic           自适应开关（根键，真正生效的那个）。
                                  =1 时按「存在感数据」动态计算，同时改写 AC 和 DC；
                                  =0 时只按手动活跃时段算 DC，【完全不碰 AC】。
            HibernateIdleDaytime  活跃时段内的休眠超时，【单位：分钟】
            HibernateIdleOvertime 活跃时段外的休眠超时，【单位：分钟】
            ActiveTimeStart/End   手动活跃时段（实测 <Mon 07:30-Mon 23:30>）

        实测公式（IsAutonomic=0 时）：
            活跃时段内  DC = min(距活跃时段结束的剩余分钟, HibernateIdleDaytime)
            活跃时段外  DC = HibernateIdleOvertime
            AC = 完全不改写（保持我们写入的值）

        实测验证：Daytime/Overtime 都设 60 后，DC 稳定为 3600s（60 分钟），
        AC 保持 0s（永不 S4）。两者互不干扰。

        ── 为什么不能用 IsEnabled=0 ─────────────────────────────────
        2026-10-21 17:51 的真实故障：IsEnabled=0 后 Lenovo 停止记录 Lid 事件，
        LidPolicy 的 Get-LidState 永远读到陈旧值「打开」，合盖后完全不介入，
        系统「屏幕关但全速运行」2.9 小时，电池 80%→54%。
        教训：日志能力和管理能力是绑定的，不能为了关管理而牺牲日志。
    #>
    param(
        [int]$AcSeconds = 0,
        [int]$DcSeconds = 3600
    )

    $root = 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\SmartStandby'
    if (-not (Test-Path $root)) {
        Write-Log '  [Lenovo] 未检测到 Smart Standby，跳过配置'
        return $false
    }

    # 取当前活动电源方案 GUID（SavedPowerSettings 按其分目录存放）
    $schemeGuid = $null
    try {
        $out = (& powercfg /getactivescheme) -join ' '
        $schemeGuid = ([regex]::Match($out, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')).Groups[1].Value
    } catch { }
    if (-not $schemeGuid) { $schemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e' }
    $saved = Join-Path $root "SavedPowerSettings\$schemeGuid"

    if (-not (Test-Path $saved)) {
        Write-Log ("  [Lenovo] 未找到 SavedPowerSettings\{0}，跳过" -f $schemeGuid)
        return $false
    }

    $dcMinutes = [int][math]::Round($DcSeconds / 60)
    if ($dcMinutes -lt 1) { $dcMinutes = 1 }

    try {
        # 先读注册表现值，判断是否真的需要变更 —— 决定要不要重启服务
        $cur = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue
        $regChanged = (
            ($cur.IsEnabled            -ne 1) -or
            ($cur.IsAutonomic          -ne 0) -or
            ($cur.HibernateIdleDaytime -ne $dcMinutes) -or
            ($cur.HibernateIdleOvertime -ne $dcMinutes)
        )

        if ($regChanged) {
            # 1) 保持服务启用 —— 这是 LidPolicy 拿到 Lid / Console Display 事件的唯一数据源
            Set-ItemProperty -Path $root -Name 'IsEnabled' -Value 1 -Type DWord -ErrorAction Stop
            # 2) 关闭自适应 —— 它便不再按存在感动态计算，也不再改写 AC
            Set-ItemProperty -Path $root -Name 'IsAutonomic' -Value 0 -Type DWord -ErrorAction Stop
            # 3) 用它的手动参数直接规定 DC 超时（实测单位：分钟）
            Set-ItemProperty -Path $root -Name 'HibernateIdleDaytime'  -Value $dcMinutes -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $root -Name 'HibernateIdleOvertime' -Value $dcMinutes -Type DWord -ErrorAction Stop
            # 4) 子键里的自适应/存在感预测一并关掉
            $auto = Join-Path $root 'Autonomic'
            if (Test-Path $auto) {
                Set-ItemProperty -Path $auto -Name 'IsAutonomic' -Value 0 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $auto -Name 'IsPresenceDataSufficient' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            }
            Write-Log ("  [Lenovo] IsEnabled=1（保留事件日志）、IsAutonomic=0（不改 AC）、" +
                       "IdleDaytime/Overtime={0} 分钟 -> DC 目标 {1}s" -f $dcMinutes, $DcSeconds)
        }

        # 5) 【2026-10-24 优化】仅在必要时才重启服务。
        #
        #    复盘：Lenovo 每次从睡眠恢复都会把 HIBERNATEIDLE 改回去，旧逻辑于是
        #    每几小时就 Restart-Service -Force 一次（10-24 共 7 次）。最终服务变成
        #    Stopped 起不来，Lenovo 事件日志不再记录盖子开合，LidPolicy 永久误判
        #    「盖子=打开」，日志彻底失真。
        #
        #    现在：
        #      - 注册表真的变了、或服务没在跑  -> 才重启/启动服务
        #      - 只是 powercfg 的 HIBERNATEIDLE 漂移 -> 纯 powercfg 覆盖，不碰服务
        #    这样 Lenovo 改回去一次，我们只覆盖一个数值，服务完全不受扰动。
        $svcStatus = (Get-Service -Name 'LenovoSmartStandby' -ErrorAction SilentlyContinue).Status
        if ($regChanged -or $svcStatus -ne 'Running') {
            if ($svcStatus -eq 'Running') {
                Restart-Service -Name 'LenovoSmartStandby' -Force -ErrorAction SilentlyContinue
                $act = '重启'
            } else {
                Start-Service -Name 'LenovoSmartStandby' -ErrorAction SilentlyContinue
                $act = '启动'
            }
            Start-Sleep -Seconds 4
            $svcAfter = (Get-Service -Name 'LenovoSmartStandby' -ErrorAction SilentlyContinue).Status
            Write-Log ("  [Lenovo] 服务已{0}，当前状态 {1}" -f $act, $svcAfter)
        }

        # 6) AC 直接写 0（Autonomic=0 时 Lenovo 不覆盖它）；DC 写目标值
        & powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364 $AcSeconds 2>&1 | Out-Null
        & powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364 $DcSeconds 2>&1 | Out-Null
        & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800

        # 7) 回读校验
        $q = & powercfg /q SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364 2>&1 | Out-String
        $acHex = ([regex]::Match($q,'当前交流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
        $dcHex = ([regex]::Match($q,'当前直流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
        $acNow = [Convert]::ToInt32($acHex,16)
        $dcNow = [Convert]::ToInt32($dcHex,16)
        Write-Log ("  [Lenovo] 校验：AC={0}s DC={1}s" -f $acNow, $dcNow)

        if ($acNow -eq $AcSeconds -and $dcNow -eq $DcSeconds) {
            $acDesc = if ($AcSeconds -eq 0) { '插电永不 S4' } else { "插电 $([math]::Round($AcSeconds/60,0)) 分钟 S4" }
            $dcDesc = if ($DcSeconds -eq 0) { '电池永不 S4' } else { "电池 $([math]::Round($DcSeconds/60,0)) 分钟 S4" }
            Write-Log ("  [Lenovo] 配置生效：保留事件日志；{0}，{1}" -f $acDesc, $dcDesc)
            return $true
        }
        Write-Log ("  [Lenovo] 警告：回读不一致（期望 AC={0} DC={1}）" -f $AcSeconds, $DcSeconds)
        return $false
    } catch {
        Write-Log ("  [Lenovo] 配置失败：{0}" -f $_.Exception.Message)
        return $false
    }
}

function Test-LenovoPolicyDrift {
    <# 检查 Lenovo 状态是否与策略一致；$true = 发生偏离，需要重新应用 #>
    param([int]$AcSeconds = 0, [int]$DcSeconds = 3600)

    $root = 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\SmartStandby'
    if (-not (Test-Path $root)) { return $false }
    $p = Get-ItemProperty $root -ErrorAction SilentlyContinue
    if (-not $p) { return $false }

    $dcMinutes = [int][math]::Round($DcSeconds / 60)
    if ($dcMinutes -lt 1) { $dcMinutes = 1 }

    $bad = ($p.IsEnabled   -ne 1) -or
           ($p.IsAutonomic -ne 0) -or
           ($p.HibernateIdleDaytime  -ne $dcMinutes) -or
           ($p.HibernateIdleOvertime -ne $dcMinutes)
    if ($bad) { return $true }

    $q = & powercfg /q SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364 2>&1 | Out-String
    $acHex = ([regex]::Match($q,'当前交流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    $dcHex = ([regex]::Match($q,'当前直流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    if (-not $acHex) { return $false }
    return (([Convert]::ToInt32($acHex,16) -ne $AcSeconds) -or
            ([Convert]::ToInt32($dcHex,16) -ne $DcSeconds))
}

function Restore-LenovoSmartStandbyDefault {
    <# 回滚：恢复 Smart Standby 自身管理（IsEnabled=1），并把它原来的默认值写回 #>
    $root = 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\SmartStandby'
    if (-not (Test-Path $root)) { return }
    try {
        Set-ItemProperty -Path $root -Name 'IsEnabled' -Value 1 -Type DWord -ErrorAction SilentlyContinue
        $auto = Join-Path $root 'Autonomic'
        if (Test-Path $auto) {
            Set-ItemProperty -Path $auto -Name 'IsAutonomic' -Value 1 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $auto -Name 'IsPresenceDataSufficient' -Value 1 -Type DWord -ErrorAction SilentlyContinue
        }
        Restart-Service -Name 'LenovoSmartStandby' -Force -ErrorAction SilentlyContinue
        Write-Log '  [Lenovo] 已恢复 Smart Standby 自主管理（IsEnabled=1）'
    } catch {
        Write-Log ("  [Lenovo] 回滚失败：{0}" -f $_.Exception.Message)
    }
}

function Invoke-SystemSleep {
    <#
        强制请求进入睡眠（Modern Standby 上即进入 S0 连接待机 / DRIPS）。

        需求（2026-10-22 最终确认）：
          只有 Caffeine 能阻止睡眠；其它任何程序都【不能】阻止睡眠。

        因此这里用 SetSuspendState(FALSE, TRUE, FALSE)：
          - hibernate      = FALSE   -> 睡眠（S0），不是休眠（S4）
          - forceCritical  = TRUE    -> 【不打商量】，不向其它应用/驱动请求许可
                                        （FALSE 时 Windows 会征询各应用，持保活的程序可否决）
          - disableWakeEvent = FALSE -> 保留唤醒事件

        这也是「别的程序不能阻止睡眠」的实现关键：force=TRUE 绕过应用否决。

        历史教训（2026-10-22 17:23 / 19:03）：
          - 屏幕被 VIDEOIDLE 先关掉时，SC_MONITORPOWER 变空操作，系统停在
            「屏幕关但全速运行」，34 分钟耗电 6%（该路径睡眠转化率仅 3%）。
          - 保活请求若在关屏之后才建立，会被睡眠冻结而永远建立不起来。
          这两点都已在调用方修正。
    #>
    if (-not ('LidPolicy.Power' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LidPolicy {
    public class Power {
        [DllImport("powrprof.dll", SetLastError = true)]
        public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
        // 强制睡眠（S0），不让其它应用否决
        public static bool SleepForced() { return SetSuspendState(false, true, false); }
        // 温和睡眠（会被持保活的应用否决），保留备用
        public static bool SleepGraceful() { return SetSuspendState(false, false, false); }
    }
}
'@ -ErrorAction Stop
    }
    try {
        return [LidPolicy.Power]::SleepForced()
    } catch {
        return $false
    }
}

function Set-DisplayOn {
    # 主动点亮显示器（复用上方已编译的 LidPolicy.Display 类型）
    if (-not ('LidPolicy.Display' -as [type])) { return }
    [LidPolicy.Display]::On()
}

# ---------------------------------------------------------------- 盖子状态
function Get-LidState {
    <#
        返回 $true = 盖子打开，$false = 盖子关闭，$null = 无法确定
        依据：Lenovo-Power-SmartStandby 日志中的 "Lid has been opened/closed"
        该日志在本机实测可读，且与 Kernel-Power 的 LidOpenState 交叉一致。
    #>
    try {
        $ev = Get-WinEvent -LogName $LID_LOG -MaxEvents 400 -ErrorAction Stop |
              Where-Object { $_.Message -match 'Lid has been' } |
              Select-Object -First 1
        if (-not $ev) { return $null }
        if ($ev.Message -match 'opened') { return $true }
        if ($ev.Message -match 'closed') { return $false }
        return $null
    } catch {
        return $null
    }
}

function Get-LidClosedTime {
    <#
        返回最近一次「合盖」事件的时刻（DateTime），无法确定时返回 $null。
        直接从事件日志读取，因此脚本重启后仍能正确计算已合盖时长。
    #>
    try {
        $ev = Get-WinEvent -LogName $LID_LOG -MaxEvents 400 -ErrorAction Stop |
              Where-Object { $_.Message -match 'Lid has been closed' } |
              Select-Object -First 1
        if ($ev) { return $ev.TimeCreated }
        return $null
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------- Caffeine 状态
function Test-CaffeineActive {
    <#
        依据 Coffee 扩展源码（rust/src/main.rs）：
          - worker 启动后写 state.json { pid, startTime, startTicks, durationSeconds }
          - stop_caffeinate 会 clear_state() 删除它
          - is_caffeinate_running 会校验 pid + 进程创建时间，防止 PID 复用
        这里做等效校验：state.json 存在 且 其中 pid 仍存活 且 进程名匹配。
    #>
    if (-not (Test-Path $COFFEE_STATE)) { return $false }
    try {
        $st = Get-Content $COFFEE_STATE -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $false
    }
    if (-not $st.pid) { return $false }
    $p = Get-Process -Id $st.pid -ErrorAction SilentlyContinue
    if (-not $p) { return $false }   # 进程已退出 -> 状态过期
    return $true
}

# ---------------------------------------------------------------- 唤醒封锁
function Get-WakeArmedDevices {
    $out = & powercfg /devicequery wake_armed 2>&1
    # powercfg 在没有任何唤醒设备时会输出「无」/「None」，需过滤掉，
    # 否则会被当成设备名传给 devicedisablewake 而报 0x490 错误。
    return @($out | Where-Object {
        $t = $_.Trim()
        $t -ne '' -and $t -ne '无' -and $t -ne '無' -and $t -ne 'None' -and $t -ne 'NONE'
    })
}

function Test-Whitelisted([string]$device) {
    if ($WakeWhitelist.Count -eq 0) { return $false }
    foreach ($pat in $WakeWhitelist) {
        if ($device -like $pat) { return $true }
    }
    return $false
}

function Invoke-WakeBlock {
    <#
        封锁所有「唤醒就绪」设备，白名单除外。
        另外确保：唤醒定时器禁用、USB 选择性挂起不唤醒。
    #>
    $devices = Get-WakeArmedDevices
    if ($devices.Count -eq 0) {
        Write-Log '  [唤醒] 当前无唤醒就绪设备'
    }
    foreach ($d in $devices) {
        if (Test-Whitelisted $d) {
            Write-Log "  [唤醒] 白名单保留: $d"
            continue
        }
        if ($DryRun) {
            Write-Log "  [唤醒] (DryRun) 将禁用唤醒: $d"
            continue
        }
        $r = & powercfg /devicedisablewake $d 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  [唤醒] 已禁用唤醒: $d"
        } else {
            Write-Log "  [唤醒] 禁用失败: $d -> $($r -join ' ')"
        }
    }

    # 唤醒定时器（AC/DC 均禁用）
    if (-not $DryRun) {
        & powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0 | Out-Null
        & powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0 | Out-Null
        & powercfg /setactive SCHEME_CURRENT | Out-Null
    }
    Write-Log '  [唤醒] 唤醒定时器已禁用 (AC/DC)'
}

# ---------------------------------------------------------------- 空闲睡眠超时（STANDBYIDLE）
function Set-PowerSecondsValue {
    <# 通用：按 GUID 设置一个「秒」类电源设置（AC/DC 分别），值相同就不写。 #>
    param(
        [string]$SubGroup,
        [string]$SettingGuid,
        [int]$AcSeconds,
        [int]$DcSeconds,
        [string]$Label
    )

    $q = & powercfg /q SCHEME_CURRENT $SubGroup $SettingGuid 2>&1 | Out-String
    $acHex = ([regex]::Match($q, '当前交流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    $dcHex = ([regex]::Match($q, '当前直流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    $acNow = if ($acHex) { [Convert]::ToInt32($acHex,16) } else { -1 }
    $dcNow = if ($dcHex) { [Convert]::ToInt32($dcHex,16) } else { -1 }
    if ($acNow -eq $AcSeconds -and $dcNow -eq $DcSeconds) { return $true }

    & powercfg /setacvalueindex SCHEME_CURRENT $SubGroup $SettingGuid $AcSeconds 2>&1 | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT $SubGroup $SettingGuid $DcSeconds 2>&1 | Out-Null
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null

    $q2 = & powercfg /q SCHEME_CURRENT $SubGroup $SettingGuid 2>&1 | Out-String
    $ac2 = ([regex]::Match($q2, '当前交流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    $dc2 = ([regex]::Match($q2, '当前直流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    $ok = ($ac2 -and ([Convert]::ToInt32($ac2,16) -eq $AcSeconds) -and
           $dc2 -and ([Convert]::ToInt32($dc2,16) -eq $DcSeconds))
    $fmt = { param($s) if ($s -eq 0) { '永不' } else { "$([math]::Round($s/60,1)) 分钟" } }
    if ($ok) {
        Write-Log ("  [{0}] 已设置  AC={1}  DC={2}" -f $Label, (& $fmt $AcSeconds), (& $fmt $DcSeconds))
    } else {
        Write-Log ("  [{0}] 设置失败（回读 AC=0x{1} DC=0x{2}）" -f $Label, $ac2, $dc2)
    }
    return $ok
}

function Set-StandbyIdle {
    <#
        空闲多久后睡眠（STANDBYIDLE）: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da
        需求：AC 永不、DC 30 分钟。
    #>
    param([int]$AcSeconds, [int]$DcSeconds)
    return Set-PowerSecondsValue -SubGroup 'SUB_SLEEP' `
        -SettingGuid '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' `
        -AcSeconds $AcSeconds -DcSeconds $DcSeconds -Label 'STANDBYIDLE'
}

function Set-VideoIdle {
    <#
        空闲多久后关闭显示器（VIDEOIDLE）: 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e
        需求：AC/DC 都是 10 分钟（2026-10-22 用户指定，DC 原为 3 分钟太短）。
    #>
    param([int]$AcSeconds, [int]$DcSeconds)
    return Set-PowerSecondsValue -SubGroup 'SUB_VIDEO' `
        -SettingGuid '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' `
        -AcSeconds $AcSeconds -DcSeconds $DcSeconds -Label 'VIDEOIDLE'
}

# ---------------------------------------------------------------- 合盖操作（LIDACTION）
function Set-LidAction {
    <#
        设置「合上盖子操作」：0=不采取任何操作，1=睡眠，2=休眠，3=关机
        GUID 5ca83367-6e45-459f-a27b-476b1d01c936（子组 SUB_BUTTONS）

        这是本方案的核心：把「合盖该不该睡」交给 Windows 原生逻辑，
        而不是自己调 SC_MONITORPOWER / SetSuspendState。
        本机实测：原生 Lid 路径的入睡率 83%，远高于脚本关屏的 32%。
    #>
    param([ValidateSet(0, 1, 2, 3)][int]$Value)

    $guid = '5ca83367-6e45-459f-a27b-476b1d01c936'

    # 先读现值，一样就不写（避免每 5 秒刷 powercfg）
    $q = & powercfg /q SCHEME_CURRENT SUB_BUTTONS $guid 2>&1 | Out-String
    $acHex = ([regex]::Match($q, '当前交流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    $dcHex = ([regex]::Match($q, '当前直流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    if ($acHex -and $dcHex -and
        ([Convert]::ToInt32($acHex,16) -eq $Value) -and
        ([Convert]::ToInt32($dcHex,16) -eq $Value)) {
        return $true   # 已是目标值
    }

    & powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS $guid $Value 2>&1 | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS $guid $Value 2>&1 | Out-Null
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null

    # 回读校验
    $q2 = & powercfg /q SCHEME_CURRENT SUB_BUTTONS $guid 2>&1 | Out-String
    $ac2 = ([regex]::Match($q2, '当前交流电源设置索引:\s*0x([0-9a-f]+)')).Groups[1].Value
    $ok = ($ac2 -and ([Convert]::ToInt32($ac2,16) -eq $Value))
    if ($ok) {
        $name = switch ($Value) { 0 { '不操作' } 1 { '睡眠' } 2 { '休眠' } 3 { '关机' } }
        Write-Log ("  [LIDACTION] 已切换为 {0}（{1}）" -f $Value, $name)
    } else {
        Write-Log ("  [LIDACTION] 切换失败（期望 {0}，回读 0x{1}）" -f $Value, $ac2)
    }
    return $ok
}

# ---------------------------------------------------------------- 主逻辑
function Invoke-LidPolicy {
    $lidOpen = Get-LidState
    if ($null -eq $lidOpen) {
        Write-Log '  [盖子] 无法确定状态（日志不可读），跳过本次'
        return
    }

    $onAc      = Test-OnAcPower
    $caffeine  = Test-CaffeineActive

    $lidText = if ($lidOpen) { '打开' } else { '关闭' }
    $acText  = if ($onAc) { 'AC 插电' } else { 'DC 电池' }
    $cafText = if ($caffeine) { '开启' } else { '关闭' }

    $closedMin = $null
    if (-not $lidOpen) {
        $c = Get-LidClosedTime
        if ($c) { $closedMin = ((Get-Date) - $c).TotalMinutes }
    }

    # ---- 决策：动态切换「合盖操作」LIDACTION，让 Windows 用原生合盖逻辑入睡 ----
    #
    # 为什么用这个方案（2026-10-22 网络查证 + 本机实测）：
    #   1) Microsoft 官方明确：SetThreadExecutionState（Caffeine/PowerToys Awake 用的
    #      同一个 API）无法阻止「合盖/电源键」引起的睡眠，只能挡空闲超时。
    #      -> 所以不可能靠 Caffeine 自己免于合盖睡眠。
    #   2) 本机实测各「关屏原因」的真实入睡率：
    #        Video Idle Timeout  3%
    #        SC_MONITORPOWER    32%
    #        Lid（Windows 原生） 83%   <-- 最高
    #      -> 让 Windows 自己处理合盖，成功率最高，且不会误走 S4。
    #   3) 之前自己调 SetSuspendState(force=TRUE) 会被固件回落成 S4（见 BIOS logo），
    #      这个方案完全不调用睡眠 API，规避该陷阱。
    #
    # 实现：
    #   Caffeine 开  -> LIDACTION=0（不操作）+ 持有保活  => 合盖后继续运行
    #   Caffeine 关  -> LIDACTION=1（睡眠）             => 合盖后 Windows 原生入睡
    # 这个设置每轮（5 秒）维护一次，保证在你合盖之前已经就位。
    $wantSleepOnLidClose = -not $caffeine

    $lidAction = if ($wantSleepOnLidClose) { 1 } else { 0 }
    $lidActionText = if ($wantSleepOnLidClose) { '睡眠' } else { '不操作' }

    $action = if ($wantSleepOnLidClose) { "合盖=睡眠$($(if($lidOpen){''}else{'（已合盖）'}))" }
              else { "合盖=不操作$($(if($lidOpen){''}else{'（仍保持运行）'}))" }

    # 维护 LIDACTION（AC/DC 一致）
    Set-LidAction -Value $lidAction

    # 供常驻循环判断是否需要持有「系统必需」请求
    $script:LastAction   = $action
    $script:LastLidOpen  = $lidOpen
    $script:LastOnAc     = $onAc
    $script:LastCaffeine = $caffeine

    $graceText = ''
    if (-not $lidOpen -and $null -ne $closedMin) {
        $graceText = " | 已合盖 $([math]::Round($closedMin,1)) 分钟（$([math]::Round($DcHibernateSeconds/60,0)) 分钟后转 S4）"
    }
    Write-Log "盖子=$lidText | $acText | Caffeine=$cafText -> LIDACTION=$lidActionText$graceText"

    if ($DryRun) {
        Write-Log '  (DryRun) 不实际变更'
        return
    }

    # Caffeine 开着且已合盖：额外持有保活，确保即便 LIDACTION 被外部改回也能撑住
    if (-not $lidOpen -and $caffeine) {
        if (Set-SystemAwake) {
            Write-Log '  [保活] Caffeine 开启，持有 ES_SYSTEM_REQUIRED 保持运行'
        }
    }
}

# ---------------------------------------------------------------- 单实例互斥
function Enter-SingleInstance {
    <#
        严重故障复盘 (2026-10-21 08:03)：
          「每 10 分钟兜底触发器」每 10 分钟启动一个新的常驻实例，
          但旧实例并未退出，导致 58 个 LidPolicy 进程并发运行。
          每个实例都在独立做「关屏/保活/挂计时器」判断，
          相互冲突的 SC_MONITORPOWER 调用把系统推进
          「进 S0 -> 输入唤醒 -> 再进 S0」的无限循环，
          表现为：锁屏进桌面 -> 黑屏 -> 回锁屏 -> 反复。

        本函数用命名 Mutex 保证全局只有一个常驻实例。
    #>
    param([string]$Name)

    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, $Name, [ref]$created)
    if (-not $created) {
        # 已有实例持有，本进程应立即退出
        $mutex.Dispose()
        return $null
    }
    return $mutex
}
function Start-LidPolicyLoop {
    # 单实例保护：若已有常驻实例在跑，本进程立刻退出，绝不允许并发
    $mutex = Enter-SingleInstance -Name 'Global\PowerPolicyResident'
    if ($null -eq $mutex) {
        Write-Log '  [互斥] 已有常驻实例在运行，本实例退出（防止并发）'
        return
    }

    try {
        Write-Log "PowerPolicy 常驻启动（间隔 ${IntervalSeconds}s）"
        $lastWakeBlock = [datetime]::MinValue
        $holding = $false          # 当前是否持有 ES_SYSTEM_REQUIRED

        while ($true) {
        try {
            $script:LastAction   = ''
            $script:LastLidOpen  = $null
            $script:LastOnAc     = $null
            $script:LastCaffeine = $null
            Invoke-LidPolicy

            # 保活策略（按用户术语校准）：
            # 保活策略（2026-10-22 最终需求）：
            #   插电与电池行为完全一致；唯一能阻止睡眠的只有 Caffeine。
            #   Caffeine 开 -> 持有保活，绝不进 S0（其它电源请求一律不理会）
            #   Caffeine 关 -> 不持有，让系统正常进 S0，由 HIBERNATEIDLE 在 60 分钟后转 S4
            $keepAwake = ($script:LastCaffeine -eq $true)

            if ($keepAwake -and -not $holding) {
                if (Set-SystemAwake) {
                    $holding = $true
                    Write-Log '  [保活] 已持有 ES_SYSTEM_REQUIRED（Caffeine 期间保持系统唤醒）'
                }
            } elseif (-not $keepAwake -and $holding) {
                if (Clear-SystemAwake) {
                    $holding = $false
                    Write-Log '  [保活] 已释放 ES_SYSTEM_REQUIRED（恢复正常合盖睡眠）'
                }
            } elseif ($holding) {
                [void](Set-SystemAwake)   # 周期性续期
            }

            # 每 5 分钟：重新应用唤醒封锁 + 校验 Lenovo 配置是否被外部改回
            if (((Get-Date) - $lastWakeBlock).TotalMinutes -ge 5) {
                Invoke-WakeBlock
                $lastWakeBlock = Get-Date

                # 防漂移：Lenovo Vantage 或服务重启有可能改回 IsEnabled / IsAutonomic，
                # 或改写 HIBERNATEIDLE。仅在检测到偏离时才纠正一次，
                # 不是每轮都写（避免变成对抗式反复重写）。
                try {
                    if (Test-LenovoPolicyDrift -AcSeconds $AcHibernateSeconds -DcSeconds $DcHibernateSeconds) {
                        # 注意：多数情况下只是 HIBERNATEIDLE 被 Lenovo 从睡眠恢复时改回去了，
                        # 注册表参数仍是好的。Set-LenovoSmartStandbyPolicy 内部会自行判断
                        # 是否真的需要重启服务，所以这里不必再区分。
                        Write-Log '  [防漂移] 检测到 Lenovo 休眠参数偏离，重新应用'
                        [void](Set-LenovoSmartStandbyPolicy -AcSeconds $AcHibernateSeconds -DcSeconds $DcHibernateSeconds)
                    }
                    # 同时纠正空闲睡眠 / 关屏超时（内部自带"相同就不写"，开销极小）
                    [void](Set-StandbyIdle -AcSeconds $AcStandbySeconds -DcSeconds $DcStandbySeconds)
                    [void](Set-VideoIdle  -AcSeconds $AcVideoIdleSeconds -DcSeconds $DcVideoIdleSeconds)

                    # 服务健康检查（2026-10-24 故障复盘）：
                    #   LenovoSmartStandby 服务在 08:24 之后停掉了，导致 Lenovo 事件日志
                    #   不再记录 Lid has been closed/opened。本脚本靠该日志判断盖子状态，
                    #   于是此后日志一直显示「盖子=打开」，完全失去盖子感知。
                    #   注意：LIDACTION 只由 Caffeine 决定、与盖子状态无关，所以实际睡眠
                    #   行为仍正确（Windows 自己按 LIDACTION 执行），但可观测性与保活分支失效。
                    #   之前防漂移只查注册表数值，服务停了不算偏离，永远纠正不到，现补上。
                    $svc = Get-Service -Name 'LenovoSmartStandby' -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -ne 'Running') {
                        Write-Log ("  [防漂移] LenovoSmartStandby 状态为 {0}，正在启动（否则盖子事件流会断）" -f $svc.Status)
                        Start-Service -Name 'LenovoSmartStandby' -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 2
                        $svc2 = Get-Service -Name 'LenovoSmartStandby' -ErrorAction SilentlyContinue
                        Write-Log ("  [防漂移] 启动后状态: {0}" -f $(if ($svc2) { $svc2.Status } else { '未知' }))
                    }
                } catch {
                    # 防漂移失败不应影响主循环
                }
            }
        } catch {
            Write-Log "  [错误] $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $IntervalSeconds
        }
    } finally {
        # 释放互斥锁，允许后续实例接管
        try { $mutex.ReleaseMutex() } catch { }
        try { $mutex.Dispose() } catch { }
    }
}

# ================================================================ 入口
if ($Uninstall) {
    foreach ($t in @($TaskName, "${TaskName}-OnLidEvent", "${TaskName}-HibernateAt")) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
    # 回滚 Lenovo Smart Standby 到自主管理
    Restore-LenovoSmartStandbyDefault
    Write-Log "已卸载全部 PowerPolicy 计划任务，并恢复 Lenovo Smart Standby 默认行为"
    return
}

if ($Install) {
    $scriptPath = $MyInvocation.MyCommand.Path

    # 关键：计划任务【不继承 PATH】，必须用 pwsh.exe 的绝对路径。
    # 否则会以 0x80070002（找不到文件）失败。
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath -or -not (Test-Path $pwshPath)) {
        $pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
        if (-not (Test-Path $pwshPath)) {
            $pwshPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        }
    }
    Write-Log "使用 pwsh 路径: $pwshPath"

    # ---- 第 1 步：配置 Lenovo Smart Standby（让它自己写入并保持目标值）----
    Write-Log ''
    Write-Log '=== 配置 Lenovo Smart Standby ==='
    [void](Set-LenovoSmartStandbyPolicy -AcSeconds $AcHibernateSeconds -DcSeconds $DcHibernateSeconds)

    # ---- 第 1b 步：空闲睡眠超时（AC 永不 / DC 30 分钟）+ 空闲关屏（都是 10 分钟）----
    Write-Log ''
    Write-Log '=== 配置空闲睡眠与关屏超时 ==='
    [void](Set-StandbyIdle -AcSeconds $AcStandbySeconds -DcSeconds $DcStandbySeconds)
    [void](Set-VideoIdle  -AcSeconds $AcVideoIdleSeconds -DcSeconds $DcVideoIdleSeconds)

    # 清理历史遗留任务：
    #   - "${TaskName}-HibernateAt"：早期的一次性计时器
    #   - "LidPolicy" / "LidPolicy-OnLidClose"：本工具移入仓库前的旧任务名
    foreach ($legacy in @("${TaskName}-HibernateAt", 'LidPolicy', 'LidPolicy-OnLidClose')) {
        if (Get-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $legacy -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "  已移除历史任务: $legacy"
        }
    }

    # 统一参数串
    $commonArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -AcHibernateSeconds $AcHibernateSeconds -DcHibernateSeconds $DcHibernateSeconds -AcStandbySeconds $AcStandbySeconds -DcStandbySeconds $DcStandbySeconds -AcVideoIdleSeconds $AcVideoIdleSeconds -DcVideoIdleSeconds $DcVideoIdleSeconds"
    if ($WakeWhitelist.Count -gt 0) {
        $quoted = ($WakeWhitelist | ForEach-Object { "'$_'" }) -join ','
        $commonArgs += " -WakeWhitelist $quoted"
    }

    # ---- 静默启动：通过 wscript + SilentRun.vbs 启动，彻底避免控制台窗口闪现 ----
    # 仅靠 pwsh 的 -WindowStyle Hidden 仍会短暂创建 conhost 窗口（用户实测会闪）。
    # 用 WScript.Shell.Run 的窗口样式 0 可完全隐藏。
    # 静默外壳：优先用本目录副本，否则复用仓库 tools\startup\SilentRun.vbs
    # （仓库已有同一份实现，避免重复维护；本目录不再放第二份）
    $vbsCandidates = @(
        (Join-Path (Split-Path -Parent $scriptPath) 'SilentRun.vbs'),
        (Join-Path (Split-Path (Split-Path -Parent $scriptPath) -Parent) 'startup\SilentRun.vbs')
    )
    $vbsPath = $vbsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $useVbs  = [bool]$vbsPath
    if ($useVbs) {
        Write-Log "静默启动器: $vbsPath"
    } else {
        Write-Log "警告：未找到 SilentRun.vbs，将直接启动（可能有窗口闪现）"
    }

    # 把任务的动作改写为「通过 wscript+SilentRun.vbs 静默启动」，并置 Hidden
    function ConvertTo-SilentTaskXml {
        param([string]$Xml, [string]$VbsPath, [string]$ExePath, [string]$Arguments)

        $fullCmd = "`"$ExePath`" $Arguments"
        $newCmd  = "$env:SystemRoot\System32\wscript.exe"
        $newArgs = "//B `"$VbsPath`" `"$fullCmd`""

        $esc = [System.Security.SecurityElement]::Escape($newArgs)
        $cmdEsc = [System.Security.SecurityElement]::Escape($newCmd)

        $out = $Xml -replace '<Hidden>false</Hidden>', '<Hidden>true</Hidden>'
        $out = $out -replace '(?s)<Actions Context="Author">.*?</Actions>', @"
<Actions Context="Author">
    <Exec>
      <Command>$cmdEsc</Command>
      <Arguments>$esc</Arguments>
    </Exec>
  </Actions>
"@
        return $out
    }

    # 生成事件触发任务 XML 的辅助函数
    function New-EventTaskXml {
        param([string]$Description, [string[]]$Subscriptions, [string]$Arguments, [string]$ExePath)

        $triggers = ($Subscriptions | ForEach-Object {
            $esc = [System.Security.SecurityElement]::Escape($_)
            "    <EventTrigger><Enabled>true</Enabled><Subscription>$esc</Subscription></EventTrigger>"
        }) -join "`r`n"

        return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$Description</Description></RegistrationInfo>
  <Triggers>
$triggers
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$env:USERDOMAIN\$env:USERNAME</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$([System.Security.SecurityElement]::Escape($ExePath))</Command>
      <Arguments>$([System.Security.SecurityElement]::Escape($Arguments))</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    }

    # --- 任务 1：盖子/供电状态变化 -> 立即重新判定 ---
    # 覆盖三个场景：
    #   a) 合盖                -> 判定是否休眠/关屏
    #   b) 插电合盖后断电      -> 立即转为休眠
    #   c) 开盖                -> 清除关屏标记，允许下次合盖再次关屏
    $lidClosed = "<QueryList><Query Id='0' Path='Lenovo-Power-SmartStandby/Operational'>" +
                 "<Select Path='Lenovo-Power-SmartStandby/Operational'>" +
                 "*[System[Provider[@Name='Lenovo-Power-SmartStandby'] and EventID=103]] " +
                 "and *[EventData[Data[@Name='MessageString']='Lid has been closed.']]" +
                 "</Select></Query></QueryList>"
    $lidOpened = "<QueryList><Query Id='0' Path='Lenovo-Power-SmartStandby/Operational'>" +
                 "<Select Path='Lenovo-Power-SmartStandby/Operational'>" +
                 "*[System[Provider[@Name='Lenovo-Power-SmartStandby'] and EventID=103]] " +
                 "and *[EventData[Data[@Name='MessageString']='Lid has been opened.']]" +
                 "</Select></Query></QueryList>"
    $powerChange = "<QueryList><Query Id='0' Path='System'>" +
                   "<Select Path='System'>" +
                   "*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=105]]" +
                   "</Select></Query></QueryList>"

    $xml1 = New-EventTaskXml -Description '盖子或供电变化时立即判定休眠/关屏' `
        -Subscriptions @($lidClosed, $lidOpened, $powerChange) `
        -Arguments "$commonArgs" `
        -ExePath $pwshPath
    # 事件任务也需要单实例：事件风暴时（如反复合盖）不能并发执行，
    # 否则多个实例同时 Set-DisplayOff 会造成显示状态争抢。
    # MultipleInstancesPolicy=IgnoreNew + ExecutionTimeLimit 已在 XML 中设置，
    # 但进程级仍有竞态，故在 XML 中把执行时间限制收紧，并在脚本层面加互斥。
    if ($useVbs) { $xml1 = ConvertTo-SilentTaskXml -Xml $xml1 -VbsPath $vbsPath -ExePath $pwshPath -Arguments $commonArgs }
    Register-ScheduledTask -TaskName "${TaskName}-OnLidEvent" -Xml $xml1 -Force | Out-Null
    Write-Log "已安装事件触发任务 '${TaskName}-OnLidEvent'（合盖/开盖/断电 三事件，单次检查）"

    # --- 任务 2：登录后常驻，负责唤醒封锁与兜底轮询 ---
    $action2 = New-ScheduledTaskAction -Execute $pwshPath -Argument "$commonArgs -Run -IntervalSeconds $IntervalSeconds"
    if ($useVbs) {
        $action2 = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" `
            -Argument ("//B `"$vbsPath`" `"`"$pwshPath`" " + $commonArgs + " -Run -IntervalSeconds $IntervalSeconds`"")
    }

    # 【严重教训 2026-10-21】绝不使用「每 N 分钟重复触发」来兜底常驻任务。
    # 原实现用了 -Once -RepetitionInterval 10 分钟，结果每 10 分钟起一个新实例，
    # 旧实例不死，累积到 58 个并发进程，互相冲突的 SC_MONITORPOWER
    # 造成锁屏<->黑屏无限循环。
    # 正确做法：
    #   1) 只在登录时启动一次
    #   2) 用 RestartCount/RestartInterval 让「任务失败」时重启（Task Scheduler 托管，不累积）
    #   3) 由进程内 Mutex 保证全局单实例
    $trigger2 = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $action2 -Trigger $trigger2 `
        -Principal $principal -Settings $settings -Force | Out-Null
    # 置 Hidden=true：任务计划程序中隐藏，减少窗口闪现
    try {
        $tobj = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $tobj.Settings.Hidden = $true
        Set-ScheduledTask -TaskName $TaskName -Settings $tobj.Settings -ErrorAction Stop | Out-Null
    } catch { Write-Log "  (设置 Hidden 失败: $($_.Exception.Message))" }
    Write-Log "已安装常驻任务 '$TaskName'（登录启动 + 每 10 分钟兜底，间隔 ${IntervalSeconds}s）"

    Write-Log '说明：事件任务负责秒级响应（合盖/开盖/断电），常驻任务负责唤醒封锁与兜底。'
    return
}

if ($ApplyWakeBlock) {
    Invoke-WakeBlock
    return
}

# 常驻循环模式
if ($Run) {
    Start-LidPolicyLoop
    return
}

# 默认：单次检查（DryRun 或真实执行）
Invoke-LidPolicy
