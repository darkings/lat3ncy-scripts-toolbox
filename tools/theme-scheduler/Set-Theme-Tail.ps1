param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('light', 'dark')]
  [string]$Mode,
  [switch]$PlanOnly
)

# Set-Theme-Tail.ps1
# 切换主题后的"尾巴"：壁纸 / 鼠标方案 / 键盘背光 / 锁屏。
# 这些都不影响"界面什么时候变色"，但实测合计 5-17 秒（锁屏 p90 10s、壁纸 SPI 1.5-2s、
# 光标四个 pass 共 8s、锁屏子进程 WaitForExit 最长 60s）。
# 由 Set-Theme-Light/Dark.ps1 通过 Start-ThemeTail 以独立进程拉起，主脚本不等待它，
# 这样任务状态反映的是"颜色切完了"，而不是"壁纸和锁屏也落地了"。
#
# 单独运行：  powershell -NoProfile -File Set-Theme-Tail.ps1 -Mode light
# 只体检不落盘：powershell -NoProfile -File Set-Theme-Tail.ps1 -Mode light -PlanOnly

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$config = Get-ThemeConfig
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-ThemeLog ("Tail start: mode={0} plan={1}" -f $Mode, [bool]$PlanOnly)

# 1) 壁纸：显式路径优先，否则按文件名取当前壁纸的下一张，和 Raycast 下一张共用顺序。
$wallpaperImage = $null
try
{
  $wallpaperImage = Resolve-WallpaperImage -Config $config -Mode $Mode
}
catch
{
  Write-ThemeLog ("Tail wallpaper resolve failed: {0}" -f $_.Exception.Message)
}

if ($config.wallpaper.enabled -and $wallpaperImage)
{
  if ($PlanOnly)
  {
    Write-ThemeLog ("Tail plan: wallpaper would be {0}" -f $wallpaperImage)
  }
  else
  {
    try
    {
      Set-DesktopWallpaper -ImagePath $wallpaperImage | Out-Null
    }
    catch
    {
      Write-ThemeLog ("Tail wallpaper failed: {0}" -f $_.Exception.Message)
    }
  }
}

# 锁屏跟随：换过壁纸就用同一张，否则同步当前桌面壁纸
$lockScreenImage = if ($config.wallpaper.enabled -and $wallpaperImage) { $wallpaperImage } else { '' }

# 2) 鼠标方案（缺文件或 cursor.enabled=false 时静默跳过）
if ($PlanOnly)
{
  try
  {
    Write-ThemeLog ('Tail plan: cursor would target {0}' -f (Resolve-ThemeCursorDirectory -Mode $Mode -Config $config))
  }
  catch
  {
  }
}
else
{
  try
  {
    Set-WindowsCursorScheme -Mode $Mode -Config $config | Out-Null
  }
  catch
  {
    Write-ThemeLog ("Tail cursor failed: {0}" -f $_.Exception.Message)
  }
}

# 3) ThinkPad 键盘背光（非 ThinkPad / 禁用时静默跳过）
if ($PlanOnly)
{
  $level = if ($Mode -eq 'light') { $config.keyboard_backlight.light_level } else { $config.keyboard_backlight.dark_level }
  Write-ThemeLog ('Tail plan: backlight would be level {0}' -f $level)
}
else
{
  try
  {
    Set-ThinkPadKeyboardBacklight -Mode $Mode -Config $config | Out-Null
  }
  catch
  {
    Write-ThemeLog ("Tail backlight failed: {0}" -f $_.Exception.Message)
  }
}

# 4) 锁屏同步放最后：WinRT 落地 + 读回校验实测 p90 10 秒、最长 18 秒，
#    反正在独立进程里跑，不拖主脚本。
if (-not $PlanOnly)
{
  try
  {
    Sync-LockScreenWallpaper -Config $config -ImagePath $lockScreenImage | Out-Null
  }
  catch
  {
    Write-ThemeLog ("Tail lockscreen failed: {0}" -f $_.Exception.Message)
  }
}

Write-ThemeLog ("Tail done: mode={0} elapsed={1:N1}s" -f $Mode, $sw.Elapsed.TotalSeconds)
