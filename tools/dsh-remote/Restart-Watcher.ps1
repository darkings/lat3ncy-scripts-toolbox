# Restart-Watcher.ps1
# 只结束并重新运行已有的 DSH-Remote-Watcher 任务，让它重新加载当前脚本。
# 不删除任务、不改触发器、不动 Tailscale Serve、不关 relay。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DshRemoteUtils.ps1')

$taskName = 'DSH-Remote-Watcher'
$before = Get-DshWatcherTaskInfo
if (-not $before.Exists) {
  Write-Host "[!!] Task not found: $taskName" -ForegroundColor Red
  Write-Host "     Install first: .\Install-Watcher.ps1" -ForegroundColor Yellow
  exit 1
}

Write-Host "==> Restarting scheduled task: $taskName"
Write-Host "    Before : $($before.Status)  last=$($before.LastRun)"
if ($before.TaskToRun) {
  Write-Host "    TR     : $($before.TaskToRun)"
}

$endOut = (Invoke-DshSchtasks -SchArgs @('/End', '/TN', $taskName)).Output
if ($endOut) { Write-Host $endOut }
Start-Sleep -Milliseconds 800

$runOut = (Invoke-DshSchtasks -SchArgs @('/Run', '/TN', $taskName)).Output
if ($runOut) { Write-Host $runOut }

$deadline = (Get-Date).AddSeconds(8)
$after = $null
do {
  Start-Sleep -Milliseconds 400
  $after = Get-DshWatcherTaskInfo
  if ($after.Exists -and "$($after.Status)" -match 'Running') { break }
} while ((Get-Date) -lt $deadline)

Write-Host "    After  : $($after.Status)  last=$($after.LastRun)"
if (-not $after.Exists) {
  Write-Host "    [!!] Task query failed after restart." -ForegroundColor Yellow
  exit 1
}
if ("$($after.Status)" -match 'Running') {
  Write-Host "    [OK] Watcher task is Running; Serve/relay were not touched." -ForegroundColor Green
  exit 0
}

Write-Host "    [!!] Task exists but state is $($after.Status) (not confirmed Running)." -ForegroundColor Yellow
exit 0
