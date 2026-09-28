# Update-ThemeSchedule.ps1
# 根据日出/日落时间或固定时间自动调度 Windows 深浅色模式/主题/壁纸切换
# 计划任务:
#   Theme-Schedule-Update  每天 00:10 运行本脚本,更新当天切换时间
#   Theme-Light            日出或指定时间执行(浅色/白天)
#   Theme-Dark             日落或指定时间执行(深色/夜晚)
#   Theme-Apply-Now        用户登录时按当前时间对齐一次

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$config = Get-ThemeConfig
$LightTask = 'Theme-Light'
$DarkTask  = 'Theme-Dark'
$UpdateTask = 'Theme-Schedule-Update'
$ApplyTask = 'Theme-Apply-Now'
$CursorTask = 'Theme-Apply-Cursors'
$LogFile   = Join-Path $PSScriptRoot 'theme-scheduler.log'

function Write-Log
{
  param([string]$Message)
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
  Write-Output $line
  Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue
}

$schedule = Get-ThemeScheduleTimes -Config $config
$riseTime = $schedule.RiseTime
$setTime = $schedule.SetTime
Write-Log ('Schedule mode: {0} source={1} ({2}, {3})' -f $schedule.TriggerMode, $schedule.Source, $riseTime.ToString('HH:mm'), $setTime.ToString('HH:mm'))

# Light/Dark 打开 StartWhenAvailable，让关机错过的日出/日落在开机时补跑；
# 是否真的切换由 Set-Theme-*.ps1 里的 Test-ThemeSwitchWindow 时间窗口决定
$lightScript = Join-Path $PSScriptRoot 'Set-Theme-Light.ps1'
$darkScript = Join-Path $PSScriptRoot 'Set-Theme-Dark.ps1'
$applyScript = Join-Path $PSScriptRoot 'Apply-ThemeNow.ps1'
$cursorScript = Join-Path $PSScriptRoot 'Apply-CursorsNow.ps1'
try
{
  $lightTrigger = New-ScheduledTaskTrigger -Daily -At $riseTime
  Repair-ThemeScheduledTaskWindow -TaskName $LightTask -ScriptPath $lightScript -Trigger $lightTrigger
  Write-Log ("Theme-Light -> {0}: OK" -f $riseTime.ToString('HH:mm'))
}
catch
{
  Write-Log ("Theme-Light -> {0}: FAILED {1}" -f $riseTime.ToString('HH:mm'), $_.Exception.Message)
}

try
{
  $darkTrigger = New-ScheduledTaskTrigger -Daily -At $setTime
  Repair-ThemeScheduledTaskWindow -TaskName $DarkTask -ScriptPath $darkScript -Trigger $darkTrigger
  Write-Log ("Theme-Dark -> {0}: OK" -f $setTime.ToString('HH:mm'))
}
catch
{
  Write-Log ("Theme-Dark -> {0}: FAILED {1}" -f $setTime.ToString('HH:mm'), $_.Exception.Message)
}

try
{
  $updateScript = Join-Path $PSScriptRoot 'Update-ThemeSchedule.ps1'
  Repair-ThemeScheduledTaskWindow -TaskName $UpdateTask -ScriptPath $updateScript
  Write-Log 'Theme-Schedule-Update: OK'
}
catch
{
  Write-Log ("Theme-Schedule-Update: FAILED {0}" -f $_.Exception.Message)
}

try
{
  if (Test-Path -LiteralPath $applyScript -PathType Leaf)
  {
    $applyTrigger = Get-ThemeLogonTrigger
    Repair-ThemeScheduledTaskWindow -TaskName $ApplyTask -ScriptPath $applyScript -Trigger $applyTrigger
    Write-Log 'Theme-Apply-Now: OK'
  }
}
catch
{
  Write-Log ("Theme-Apply-Now: FAILED {0}" -f $_.Exception.Message)
}

try
{
  if (Test-Path -LiteralPath $cursorScript -PathType Leaf)
  {
    $cursorTriggers = Get-ThemeCursorUnlockTriggers
    Ensure-ThemeScheduledTask -TaskName $CursorTask -ScriptPath $cursorScript -Trigger $cursorTriggers
    Write-Log 'Theme-Apply-Cursors: OK'
  }
}
catch
{
  Write-Log ("Theme-Apply-Cursors: FAILED {0}" -f $_.Exception.Message)
}
