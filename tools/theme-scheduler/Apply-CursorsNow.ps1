# Apply-CursorsNow.ps1
# 锁屏解锁 / 切回控制台 / 从睡眠恢复：先按当前时间对齐深浅色，再重套当前方案的指针。
#
# 为什么主题对齐放在这里：
#   休眠唤醒不是"登录"，Theme-Apply-Now 的 AtLogOn 触发器永远不会补位；
#   而任务计划程序的漏跑补偿（StartWhenAvailable）实测要 6 分钟到 24 分钟
#   （2026-10-31 08:29:09 从 S4 唤醒 -> 08:35:08 才补跑 Theme-Light，
#    期间用户看到的是一直是深色）。
#   解锁 / ConsoleConnect 这条触发器实测唤醒后 0.5 秒内就能拉起本脚本，
#   把对齐放在这里，才算真的在"唤醒那一刻"生效。
#
# 指针部分保留多次补套：Win11 会在解锁后按 CurrentTheme 把指针打回默认，
#   1) Set-WindowsCursorScheme 会把自定义路径写进 .theme
#   2) 当下立刻套一次，再按 1.5s / 4s 补套，盖掉系统的延迟重载

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')
if(-not(Test-ThemeFeatureEnabled)){return}

$config = Get-ThemeConfig
$now = Get-Date
$schedule = Get-ThemeScheduleTimes -Config $config
$desired = Get-DesiredThemeMode -Now $now -RiseTime $schedule.RiseTime -SetTime $schedule.SetTime
Write-ThemeLog ("Apply-Cursors start: now={0} desired={1}" -f $now.ToString('HH:mm:ss'), $desired)

# --- 1) 对齐主题颜色 ---
if ($config.general.switch_type -eq 'theme')
{
  # 完整 .theme 包无法可靠比对当前值，交给 Theme-Apply-Now / 定时任务处理。
  Write-ThemeLog 'Apply-Cursors theme align skipped: switch_type=theme'
}
else
{
  $before = Get-ThemePersonalizeState
  $wantLight = if ($desired -eq 'light') { 1 } else { 0 }
  $appsOk = (-not $config.mode_settings.switch_apps) -or ([int]$before.AppsUseLightTheme -eq $wantLight)
  $sysOk = (-not $config.mode_settings.switch_system) -or ([int]$before.SystemUsesLightTheme -eq $wantLight)

  if ($appsOk -and $sysOk)
  {
    Write-ThemeLog ('Apply-Cursors theme align: already {0}' -f $desired)
  }
  else
  {
    $leaf = if ($desired -eq 'light') { 'Light' } else { 'Dark' }
    $targetScript = Join-Path $PSScriptRoot ('Set-Theme-{0}.ps1' -f $leaf)
    if (Test-Path -LiteralPath $targetScript -PathType Leaf)
    {
      Write-ThemeLog ('Apply-Cursors theme align: switching to {0} (before apps={1} system={2})' -f `
          $desired, $before.AppsUseLightTheme, $before.SystemUsesLightTheme)
      # -Force：模式已经算好了，别再让目标脚本按自己的时间窗口判一次。
      # 目标脚本内部会派发 Set-Theme-Tail.ps1（壁纸/键盘灯/锁屏），这里不再等它。
      & $targetScript -Force
    }
    else
    {
      Write-ThemeLog ('Apply-Cursors theme align skipped: missing {0}' -f $targetScript)
    }
  }
}

# --- 2) 重套指针 ---
if (-not $config.cursor -or -not $config.cursor.enabled)
{
  Write-ThemeLog 'Apply-Cursors skip cursors: disabled'
  exit 0
}

# 相对脚本启动：0s 立刻、1.5s、4s。原来 0/1/3/8 四拍，实测中位 8 秒、
# 其中 99% 是 Start-Sleep，而后两拍每次都只是幂等短路（10-30ms）。
# 收敛到 4 秒，同时保留一次补发来盖 Win11 的延迟重载。
$offsets = @(0, 1.5, 4)
$started = Get-Date
foreach ($offset in $offsets)
{
  $elapsed = ((Get-Date) - $started).TotalSeconds
  $wait = $offset - $elapsed
  if ($wait -gt 0)
  {
    Start-Sleep -Milliseconds ([Math]::Max(1, [int]($wait * 1000)))
  }
  Set-WindowsCursorScheme -Mode $desired -Config $config | Out-Null
  Write-ThemeLog ("Apply-Cursors pass: +{0}s mode={1}" -f $offset, $desired)
}

Write-ThemeLog ("Apply-Cursors done: {0}" -f $desired)
