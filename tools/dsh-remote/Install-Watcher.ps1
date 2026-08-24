# Install-Watcher.ps1
# 安装事件驱动 Watcher 为开机自启的隐藏计划任务（自动 sudo 提权）

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DshRemoteUtils.ps1')

$taskName = "DSH-Remote-Watcher"
$scriptPath = Join-Path $PSScriptRoot 'Watch-DshRemote.ps1'

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  Write-Host "[!!] Watch-DshRemote.ps1 not found: $scriptPath" -ForegroundColor Red
  exit 1
}

$isAdmin = Test-IsAdmin
$hasSudo = Test-SudoAvailable
if (-not $isAdmin -and -not $hasSudo) {
  Write-Host "[!!] Install requires elevation (no sudo found)." -ForegroundColor Yellow
  Write-Host "     Please run as Administrator or enable Windows sudo (Settings -> Developer -> Sudo -> Inline)" -ForegroundColor Yellow
} elseif (-not $isAdmin -and $hasSudo) {
  Write-Host "[i] Non-admin detected, will auto-elevate via sudo (UAC ConsentPromptBehaviorAdmin=0, no prompt)" -ForegroundColor Cyan
}

$tr = "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
Write-Host "==> Creating scheduled task: $taskName (RL HIGHEST - required for Tailscale)"
Write-Host "    TR: $tr"
Write-Host "    IsAdmin=$isAdmin SudoAvailable=$hasSudo"

function Invoke-SchtasksWithSudo {
  param([string[]]$SchArgs)
  $r = Invoke-DshSchtasks -SchArgs $SchArgs
  if ($r.Output -match "Access is denied") {
    Write-Host "    -> Access denied even via hidden sudo fallback." -ForegroundColor Yellow
  }
  return $r.Output
}

# 清理旧任务（如果存在）
$null = Invoke-SchtasksWithSudo -SchArgs @('/End','/TN',$taskName)
$null = Invoke-SchtasksWithSudo -SchArgs @('/Delete','/TN',$taskName,'/F')

# 创建任务
$createOut = Invoke-SchtasksWithSudo -SchArgs @('/Create','/TN',$taskName,'/TR',$tr,'/SC','ONLOGON','/RL','HIGHEST','/F')
Write-Host $createOut
if ($createOut -match "Access is denied") {
  Write-Host "    [!!] Task creation still Access denied even via sudo. Check UAC/sudo config." -ForegroundColor Red
  exit 1
}

# 验证
$verifyOut = Invoke-SchtasksWithSudo -SchArgs @('/Query','/TN',$taskName,'/FO','LIST')
if ($verifyOut -match [regex]::Escape($taskName)) {
  Write-Host "    [OK] Task created." -ForegroundColor Green
} else {
  Write-Host "    [!!] Task creation may have failed. Output: $verifyOut" -ForegroundColor Yellow
  exit 1
}

# 立即启动一次（不等下次登录）
Write-Host "==> Starting watcher now"
$runOut = Invoke-SchtasksWithSudo -SchArgs @('/Run','/TN',$taskName)
Write-Host $runOut

# 也直接启动一个本次会话的后台进程，方便立即生效（任务的进程是新登录会话的）
try {
  $already = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*Watch-DshRemote.ps1*" }
  if (-not $already) {
    Start-DshHiddenProcess -FilePath "powershell.exe" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
    Write-Host "    [OK] Watcher process launched for current session." -ForegroundColor Green
  } else {
    Write-Host "    [OK] Watcher already running in current session." -ForegroundColor Green
  }
} catch {
  Write-Host "    [!!] Could not launch watcher process: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Watcher installed (event-driven + 60s reconcile, sudo-aware)" -ForegroundColor Cyan
Write-Host "  Task : $taskName (ONLOGON, RL HIGHEST)" -ForegroundColor Cyan
Write-Host "  Check: .\Get-DshRemoteStatus.ps1  or  sudo tailscale serve status" -ForegroundColor Cyan
Write-Host "  Logs : .\watcher.log" -ForegroundColor Cyan
Write-Host "  Uninstall: .\Uninstall-Watcher.ps1  (or sudo .\Uninstall-Watcher.ps1)" -ForegroundColor Cyan
Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
