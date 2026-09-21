# Uninstall-ThemeScheduler.ps1
# 一键移除主题调度计划任务

$ErrorActionPreference = 'Continue'
$tasks = @('Theme-Light','Theme-Dark','Theme-Schedule-Update','Theme-Apply-Now','Theme-Apply-Cursors')
foreach ($t in $tasks) {
  $existing = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
  if ($existing) {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false
    Write-Host "Removed: $t" -ForegroundColor Green
  } else {
    Write-Host "Not found: $t" -ForegroundColor Yellow
  }
}
Write-Host "Done."
