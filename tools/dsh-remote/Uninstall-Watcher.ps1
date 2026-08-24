# Uninstall-Watcher.ps1
# 卸载 Watcher 计划任务并可选关闭暴露（自动 sudo）

param([switch]$KeepServe)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'DshRemoteUtils.ps1')
$taskName = "DSH-Remote-Watcher"
$cfg = Get-DshRemoteConfig
$httpsPort = if ($cfg.server.https_port) { [int]$cfg.server.https_port } else { 443 }
$relayEnabled = $true
if ($null -ne $cfg.relay.enabled) { $relayEnabled = [bool]$cfg.relay.enabled }
$relayPort = if ($cfg.relay.port) { [int]$cfg.relay.port } else { 3090 }

Write-Host "==> Removing scheduled task: $taskName"
(Invoke-DshSchtasks -SchArgs @('/End', '/TN', $taskName)).Output | Write-Host
(Invoke-DshSchtasks -SchArgs @('/Delete', '/TN', $taskName, '/F')).Output | Write-Host
try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}

# 杀掉当前会话的 Watcher 进程（仅杀匹配 Watch-DshRemote.ps1 的 powershell）
Write-Host "==> Stopping watcher processes"
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*Watch-DshRemote.ps1*" }
foreach ($p in $procs) {
  Write-Host "    Killing pid $($p.ProcessId): $($p.CommandLine)"
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}
if (-not $procs) { Write-Host "    No watcher process found." }

if (-not $KeepServe) {
  Write-Host "==> Disabling Tailscale Serve"
  $r = Invoke-TailscaleServe -ServeArgs "--https=$httpsPort off"
  $r.Output | Write-Host
  if ($relayEnabled) {
    $stoppedRelay = Stop-DshRelay -ListenPort $relayPort
    if ($stoppedRelay -gt 0) { Write-Host "    Stopped relay process(es): $stoppedRelay" }
  }
} else {
  Write-Host "==> KeepServe set, leaving Tailscale Serve as-is"
}

Write-Host ""
Write-Host "  [OK] Uninstalled." -ForegroundColor Green
