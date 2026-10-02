$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$config = Get-ThemeConfig

# 目标状态判断：不用「是否接近触发时刻」而用「当前时间应该是什么模式」。
# Modern Standby 会把进程冻结数小时，唤醒后 Get-Date 已远离触发时刻，
# 时间窗口会误判为「错过」而跳过；目标状态判断天然免疫这个问题。
$schedule = Get-ThemeScheduleTimes -Config $config
$desired = Get-DesiredThemeMode -Now (Get-Date) -RiseTime $schedule.RiseTime -SetTime $schedule.SetTime
if ($desired -ne 'dark')
{
  Write-ThemeLog ("Set-Theme-Dark skipped: now={0} desired={1}" -f (Get-Date -Format 'HH:mm'), $desired)
  return
}

if ($config.general.switch_type -eq 'theme' -and $config.theme_settings.dark_theme_file)
{
  Apply-ThemeFile -ThemeInput $config.theme_settings.dark_theme_file | Out-Null
}
else
{
  # mode：写 Apps/System 注册表，再按 switch_system 决定是否重启 Explorer 刷新托盘
  Set-WindowsColorMode -Mode 'dark' -Config $config
}

# 壁纸：显式路径优先，否则按文件名取当前壁纸的下一张，和 Raycast 下一张共用顺序。
$wallpaperImage = Resolve-WallpaperImage -Config $config -Mode 'dark'
if ($config.wallpaper.enabled -and $wallpaperImage)
{
  Set-DesktopWallpaper -ImagePath $wallpaperImage | Out-Null
}

# 锁屏跟随：换过壁纸就用同一张，否则同步当前桌面壁纸（wallpaper.sync_lock_screen 控制）
$lockScreenImage = if ($config.wallpaper.enabled -and $wallpaperImage) { $wallpaperImage } else { '' }
Sync-LockScreenWallpaper -Config $config -ImagePath $lockScreenImage | Out-Null

# 颜色切完再换指针；缺文件或关闭 cursor.enabled 时静默跳过。
Set-WindowsCursorScheme -Mode 'dark' -Config $config | Out-Null

if ($config.general.show_notification)
{
  Invoke-ThemeNotify -Type 'state' -Icon '🌙' -Text '已切换为深色模式'
}