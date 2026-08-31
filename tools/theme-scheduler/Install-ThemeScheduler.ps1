# Install-ThemeScheduler.ps1
# 一键注册主题调度计划任务（替代 README 手动 schtasks /create 一个个执行）
# 特性：幂等、隐藏无窗口、按 config.toml 自动计算日出日落时间（sun/fixed）

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$LightTask  = 'Theme-Light'
$DarkTask   = 'Theme-Dark'
$UpdateTask = 'Theme-Schedule-Update'

$lightScript  = Join-Path $PSScriptRoot 'Set-Theme-Light.ps1'
$darkScript   = Join-Path $PSScriptRoot 'Set-Theme-Dark.ps1'
$updateScript = Join-Path $PSScriptRoot 'Update-ThemeSchedule.ps1'

foreach ($p in @($lightScript, $darkScript, $updateScript)) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
    Write-Host "[!!] Missing: $p" -ForegroundColor Red
    exit 1
  }
}

$config = Get-ThemeConfig

function Ensure-ThemeTask {
  param([string]$TaskName, [string]$ScriptPath, $Trigger)
  $action = Get-ThemeHiddenAction -ScriptPath $ScriptPath
  $settings = Get-ThemeTaskSettings
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "Update: $TaskName"
    Repair-ThemeScheduledTaskWindow -TaskName $TaskName -ScriptPath $ScriptPath -Trigger $Trigger
  } else {
    Write-Host "Create: $TaskName"
    # New-ScheduledTask 需要至少一个 Trigger，Update 任务用 00:10，其余用 config fallback 先占位，稍后 Update-ThemeSchedule 会纠正为日出日落
    Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings -Trigger $Trigger -Description "Theme Scheduler - $TaskName" | Out-Null
  }
}

# 1) Update 任务固定 00:10
$updateTrigger = New-ScheduledTaskTrigger -Daily -At '00:10'
Ensure-ThemeTask -TaskName $UpdateTask -ScriptPath $updateScript -Trigger $updateTrigger

# 2) Light/Dark 先用 fixed 时间占位（避免 Get-SunTimes 失败导致无 Trigger）
$fallbackLight = if ($config.schedule.fixed_light_time) { $config.schedule.fixed_light_time } else { '07:00' }
$fallbackDark  = if ($config.schedule.fixed_dark_time)  { $config.schedule.fixed_dark_time }  else { '19:00' }
$lightTrigger = New-ScheduledTaskTrigger -Daily -At $fallbackLight
$darkTrigger  = New-ScheduledTaskTrigger -Daily -At $fallbackDark
Ensure-ThemeTask -TaskName $LightTask -ScriptPath $lightScript -Trigger $lightTrigger
Ensure-ThemeTask -TaskName $DarkTask  -ScriptPath $darkScript  -Trigger $darkTrigger

# 3) 立即按 sun/fixed 重新计算并校准 Light/Dark 触发时间（复用现有逻辑）
Write-Host "Calibrating sunrise/sunset..."
& $updateScript
if ($LASTEXITCODE -ne 0) { Write-Host "[warn] Update-ThemeSchedule exit $LASTEXITCODE" -ForegroundColor Yellow }

Write-Host ""
Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
Write-Host " Theme Scheduler installed (hidden, no window)" -ForegroundColor Cyan
Get-ScheduledTask -TaskName $LightTask,$DarkTask,$UpdateTask -ErrorAction SilentlyContinue | Format-Table TaskName,State -AutoSize
Write-Host " Verify: schtasks /query /tn `"Theme-Light`" /fo LIST ; schtasks /query /tn `"Theme-Dark`" /fo LIST" -ForegroundColor Cyan
Write-Host " Manual: schtasks /run /tn `"Theme-Light`"  /  schtasks /run /tn `"Theme-Dark`"  /  schtasks /run /tn `"Theme-Schedule-Update`"" -ForegroundColor Cyan
Write-Host " Log   : Get-Content .\theme-scheduler.log -Tail 20 -Wait" -ForegroundColor Cyan
Write-Host " Remove: .\Uninstall-ThemeScheduler.ps1" -ForegroundColor Cyan
Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
