#Requires -Version 5.1
<#
Caffeine-aware power policy v2. Native lid callbacks are diagnostic until tested.
No Lenovo service/registry changes; normal sleep (S0) and hibernate (S4) are distinct.
Run -DryRun for a read-only policy preview. -LibraryOnly is for isolated tests.
#>
[CmdletBinding()]
param(
    [switch]$DryRun, [switch]$Install, [switch]$Uninstall,
    [switch]$ApplyWakeBlock, [switch]$Run, [switch]$LibraryOnly,
    [string]$TaskName = 'PowerPolicy',
    [ValidateRange(1,60)][int]$IntervalSeconds = 1,
    [ValidateRange(0,86400)][int]$AcHibernateSeconds = 0,
    [ValidateRange(0,86400)][int]$DcHibernateSeconds = 3600,
    [ValidateRange(0,86400)][int]$AcStandbySeconds = 0,
    [ValidateRange(0,86400)][int]$DcStandbySeconds = 1800,
    [ValidateRange(0,86400)][int]$AcVideoIdleSeconds = 600,
    [ValidateRange(0,86400)][int]$DcVideoIdleSeconds = 600,
    # Accepted for old task command lines; no longer modifies Lenovo or forces sleep.
    [int]$BatteryLidGraceMinutes = -1, [int]$LenovoAcHibernateMinutes = 0,
    [switch]$ForceSleepOnLidClose,
    [string[]]$WakeWhitelist = @(),
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox\power-policy.log')
)
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 常量
$LID_LOG      = 'Lenovo-Power-SmartStandby/Operational'
$COFFEE_DIR   = Join-Path $env:LOCALAPPDATA 'coffee'
$COFFEE_STATE = Join-Path $COFFEE_DIR 'state.json'
$COFFEE_STOP  = Join-Path $COFFEE_DIR 'stop.flag'

# 日志节流与轮转用的状态
$script:LogWriteCount  = 0
$script:LastLoggedSig  = $null
$script:LastLoggedAt   = $null

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    try {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding utf8

        # 日志轮转：常驻工具会长期写，不轮转会无限增长
        # （迁移前的旧日志涨到了 19 MB）。每 200 次写入检查一次，超 3000 行保留最后 2000 行。
        $script:LogWriteCount++
        if ($script:LogWriteCount % 200 -eq 0) {
            $all = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
            if ($all.Count -gt 3000) {
                $all[-2000..-1] | Set-Content -LiteralPath $LogPath -Encoding utf8
            }
        }
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
if (-not $PSBoundParameters.ContainsKey('LenovoAcHibernateMinutes')) {
    $LenovoAcHibernateMinutes = [int](Get-CfgValue $PP_CFG 'power' 'lenovo_ac_hibernate_minutes' $LenovoAcHibernateMinutes)
}
if (-not $PSBoundParameters.ContainsKey('IntervalSeconds')) {
    $IntervalSeconds = [int](Get-CfgValue $PP_CFG 'general' 'interval_seconds' $IntervalSeconds)
}
if (-not $PSBoundParameters.ContainsKey('TaskName')) {
    $TaskName = [string](Get-CfgValue $PP_CFG 'general' 'task_name' $TaskName)
}
# [wake]：设备唤醒能力的处理策略。默认（disable_devices = false / keep 为空）完全不动设备。
# 以前白名单恒为空，Invoke-WakeBlock 会把 wake_armed 里所有设备禁用，而
# powercfg /devicedisablewake 是持久设置——一次误判就能让键盘/鼠标再也唤不醒机器。
if (-not $PSBoundParameters.ContainsKey('WakeWhitelist')) {
    $cfgWakeKeep = [string](Get-CfgValue $PP_CFG 'wake' 'keep' '')
    if ($cfgWakeKeep) {
        $WakeWhitelist = @($cfgWakeKeep -split '[;|,，；]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    else {
        # keep 留空 = 内置豁免：键盘/鼠标/HID 一概保留唤醒能力。
        # 这样即使某台机器的键盘本身支持唤醒，也不会被本工具关掉。
        $WakeWhitelist = @('*键盘*', '*Keyboard*', '*鼠标*', '*Mouse*', '*HID*')
    }
}
$wakeDisableRaw = Get-CfgValue $PP_CFG 'wake' 'disable_devices' $false
if ($wakeDisableRaw -is [bool]) { $WakeDisableDevices = $wakeDisableRaw }
else { $WakeDisableDevices = ("$wakeDisableRaw".Trim() -eq 'true') }
$timerDisableRaw = Get-CfgValue $PP_CFG 'wake' 'disable_timers' $true
if ($timerDisableRaw -is [bool]) { $WakeDisableTimers = $timerDisableRaw }
else { $WakeDisableTimers = ("$timerDisableRaw".Trim() -eq 'true') }
$COFFEE_DIR = [Environment]::ExpandEnvironmentVariables(
    [string](Get-CfgValue $PP_CFG 'caffeine' 'coffee_dir' $COFFEE_DIR))
$COFFEE_STATE = Join-Path $COFFEE_DIR 'state.json'
$COFFEE_STOP  = Join-Path $COFFEE_DIR 'stop.flag'


. (Join-Path $PSScriptRoot 'PowerPolicy.Core.ps1')
if ($LibraryOnly) { return }
Initialize-PowerNative
if ($DryRun -and ($Install -or $Uninstall -or $Run)) { throw '-DryRun only supports single policy preview / wake audit' }
if ($ForceSleepOnLidClose) { throw 'ForceSleepOnLidClose is no longer supported' }
if ($Install) { Install-PowerPolicyTasks; return }
if ($Uninstall) {
    Stop-PowerPolicyResident
    # 旧版装过 LidPolicy / LidPolicy-OnLidClose：Install 会清，卸载也必须清，
    # 否则「卸载完成」之后旧提权脚本仍在合盖/供电事件里改电源状态。
    foreach ($name in @($TaskName, "${TaskName}-OnLidEvent", "${TaskName}-HibernateAt", 'LidPolicy', 'LidPolicy-OnLidClose')) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name -ErrorAction Stop
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        }
    }
    Restore-OriginalPowerPolicies
    Restore-DisabledWakeDevices
    Write-Log '[卸载] 已恢复备份；Lenovo 服务保持禁用'
    return
}
if ($ApplyWakeBlock) { Invoke-WakeBlock; return }
if ($Run) { Start-LidPolicyLoop; return }
# Default is always read-only, including obsolete event task invocations.
$DryRun = $true
Set-DesiredPowerPolicy (Get-DesiredPowerPolicy (Test-CaffeineActive))
