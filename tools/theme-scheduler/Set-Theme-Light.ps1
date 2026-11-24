param(
  [switch]$Force
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')
if(-not(Test-ThemeFeatureEnabled)){return}

$config = Get-ThemeConfig

# 目标状态判断：不用「是否接近触发时刻」而用「当前时间应该是什么模式」。
# Modern Standby 会把进程冻结数小时，唤醒后 Get-Date 已远离触发时刻，
# 时间窗口会误判为「错过」而跳过；目标状态判断天然免疫这个问题。
if (-not $Force)
{
  $schedule = Get-ThemeScheduleTimes -Config $config
  $desired = Get-DesiredThemeMode -Now (Get-Date) -RiseTime $schedule.RiseTime -SetTime $schedule.SetTime
  if ($desired -ne 'light')
  {
    Write-ThemeLog ("Set-Theme-Light skipped: now={0} desired={1}" -f (Get-Date -Format 'HH:mm'), $desired)
    return
  }
}

$beforeState = Get-ThemePersonalizeState

if ($config.general.switch_type -eq 'theme' -and $config.theme_settings.light_theme_file)
{
  Apply-ThemeFile -ThemeInput $config.theme_settings.light_theme_file | Out-Null
}
else
{
  # mode：写 Apps/System 注册表，再按 switch_system 决定是否重启 Explorer 刷新托盘
  Set-WindowsColorMode -Mode 'light' -Config $config
}

# 只有"颜色真的变了"才派发尾巴（壁纸/光标/键盘灯/锁屏）。两个原因：
#   ① 幂等补跑不该把壁纸再轮换一张 —— 典型场景是唤醒对齐已经切过浅色，
#      几分钟后 S4 漏跑补偿又跑一次本脚本，两次都换壁纸会连跳两张。
#   ② 尾巴实测 5-17 秒，它跟"什么时候变色"完全无关。
# 用前后状态对比而不是看函数返回值：返回链路上任何杂散输出都会污染判断，
# 而多读两次注册表只要 ~2ms。
$afterState = Get-ThemePersonalizeState
$colorChanged = $true
if ($config.general.switch_type -ne 'theme')
{
  $colorChanged = ([int]$beforeState.AppsUseLightTheme -ne [int]$afterState.AppsUseLightTheme) -or `
                  ([int]$beforeState.SystemUsesLightTheme -ne [int]$afterState.SystemUsesLightTheme)
}

if ($config.general.show_notification -and $colorChanged)
{
  Invoke-ThemeNotify -Type 'info' -Icon ([string][char]0x2600 + [string][char]0xFE0F) -Text '已切换为浅色模式'
}

if ($colorChanged)
{
  # 壁纸 / 光标 / 键盘灯 / 锁屏 全部交给独立进程，主脚本立刻返回
  Start-ThemeTail -Mode 'light' | Out-Null
}
else
{
  Write-ThemeLog 'Tail skipped: color unchanged (wallpaper/cursor/backlight/lockscreen)'
}
