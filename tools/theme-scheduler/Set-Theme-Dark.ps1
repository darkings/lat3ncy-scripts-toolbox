param(
  [switch]$Force
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$config = Get-ThemeConfig

# 目标状态判断：不用「是否接近触发时刻」而用「当前时间应该是什么模式」。
# Modern Standby 会把进程冻结数小时，唤醒后 Get-Date 已远离触发时刻，
# 时间窗口会误判为「错过」而跳过；目标状态判断天然免疫这个问题。
if (-not $Force)
{
  $schedule = Get-ThemeScheduleTimes -Config $config
  $desired = Get-DesiredThemeMode -Now (Get-Date) -RiseTime $schedule.RiseTime -SetTime $schedule.SetTime
  if ($desired -ne 'dark')
  {
    Write-ThemeLog ("Set-Theme-Dark skipped: now={0} desired={1}" -f (Get-Date -Format 'HH:mm'), $desired)
    return
  }
}

$beforeState = Get-ThemePersonalizeState

if ($config.general.switch_type -eq 'theme' -and $config.theme_settings.dark_theme_file)
{
  Apply-ThemeFile -ThemeInput $config.theme_settings.dark_theme_file | Out-Null
}
else
{
  # mode：写 Apps/System 注册表，再按 switch_system 决定是否重启 Explorer 刷新托盘
  Set-WindowsColorMode -Mode 'dark' -Config $config
}

# 只有"颜色真的变了"才派发尾巴（壁纸/光标/键盘灯/锁屏）。理由同 Set-Theme-Light.ps1。
$afterState = Get-ThemePersonalizeState
$colorChanged = $true
if ($config.general.switch_type -ne 'theme')
{
  $colorChanged = ([int]$beforeState.AppsUseLightTheme -ne [int]$afterState.AppsUseLightTheme) -or `
                  ([int]$beforeState.SystemUsesLightTheme -ne [int]$afterState.SystemUsesLightTheme)
}

if ($config.general.show_notification -and $colorChanged)
{
  Invoke-ThemeNotify -Type 'state' -Icon ([char]::ConvertFromUtf32(0x1F319)) -Text '已切换为深色模式'
}

if ($colorChanged)
{
  # 壁纸 / 光标 / 键盘灯 / 锁屏 全部交给独立进程，主脚本立刻返回
  Start-ThemeTail -Mode 'dark' | Out-Null
}
else
{
  Write-ThemeLog 'Tail skipped: color unchanged (wallpaper/cursor/backlight/lockscreen)'
}
