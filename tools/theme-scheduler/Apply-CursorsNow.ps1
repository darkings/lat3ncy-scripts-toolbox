# Apply-CursorsNow.ps1
# 锁屏解锁 / 切回控制台时立刻重套当前深浅色的鼠标方案。
# Win11 会延迟按 CurrentTheme 把指针打回 Windows_11_dark/light：
#   1) Set-WindowsCursorScheme 会把自定义路径写进 .theme
#   2) 当下立刻套一次，再按 1s / 3s / 8s 补套，盖掉系统的延迟重载

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$config = Get-ThemeConfig
if (-not $config.cursor -or -not $config.cursor.enabled)
{
  Write-ThemeLog 'Apply-Cursors skip: disabled'
  exit 0
}

$now = Get-Date
$schedule = Get-ThemeScheduleTimes -Config $config
$desired = Get-DesiredThemeMode -Now $now -RiseTime $schedule.RiseTime -SetTime $schedule.SetTime
Write-ThemeLog ("Apply-Cursors start: now={0} desired={1}" -f $now.ToString('HH:mm:ss'), $desired)

# 相对脚本启动：0s 立刻、1s、3s、8s。覆盖 Win11 解锁后那一拍默认指针。
$offsets = @(0, 1, 3, 8)
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
