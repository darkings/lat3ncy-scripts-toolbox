# Get-DshRemoteStatus.ps1
# 查询当前 DSH 进程 + Tailscale Serve 状态，JSON/人类可读双输出

param([switch]$Json)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DshRemoteUtils.ps1')

$cfg = Get-DshRemoteConfig
$port = Get-DshPort -ConfiguredPort ([int]$cfg.server.port)
$httpsPort = if ($cfg.server.https_port) { [int]$cfg.server.https_port } else { 443 }
$relayEnabled = $true
if ($null -ne $cfg.relay.enabled) { $relayEnabled = [bool]$cfg.relay.enabled }
$relayPort = if ($cfg.relay.port) { [int]$cfg.relay.port } else { 3090 }
$targetPort = if ($relayEnabled) { $relayPort } else { $port }

$dshProc = Get-Process -Name 'deepseek-harness-desktop' -ErrorAction SilentlyContinue | Select-Object -First 1
$nodeProc = $null
try {
  $nodeProc = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*deepseek-harness*" } | Select-Object -First 1
} catch {}
$dshRunning = ($null -ne $dshProc) -or ($null -ne $nodeProc)
# 端口监听也视为运行中（加强判定，与 Watcher 逻辑一致）
$listening = Test-DshListening -Port $port
if ($listening) { $dshRunning = $true }
$relayProc = if ($relayEnabled) { @(Get-DshRelayProcess -ListenPort $relayPort -TargetPort $port) } else { @() }
$relayListening = $relayEnabled -and (Test-DshListening -Port $relayPort)
$dshPid = if ($dshProc) { $dshProc.Id } elseif ($nodeProc) { $nodeProc.ProcessId } else { $null }
$needAdmin = -not (Test-IsAdmin)
$hasSudo = Test-SudoAvailable
$rawHostname = Get-TailscaleHostname
$rawServe = Get-TailscaleServeStatus
$accessDenied = ($rawHostname -eq "__ACCESS_DENIED__" -or $rawServe -eq "__ACCESS_DENIED__")
if ($accessDenied) { $hostname = $null; $serveOn = $false; $tailscaleOnline = $false }
else {
  $hostname = $rawHostname
  $serveOn = Test-TailscaleServeOn -Port $targetPort -HttpsPort $httpsPort
  $tailscaleOnline = $null -ne $hostname
}
$url = if ($hostname) { "https://$hostname" } else { $null }
if ($hostname -and $httpsPort -ne 443) { $url = "https://$hostname`:$httpsPort" }

# 检查 Watcher 计划任务（带 sudo 回退）
$watcherTask = $null
try {
  $taskRaw = (Invoke-DshSchtasks -SchArgs @('/Query', '/TN', 'DSH-Remote-Watcher', '/FO', 'CSV', '/NH')).Output
  if ($taskRaw -and $taskRaw -notmatch 'ERROR' -and $taskRaw -match "DSH-Remote-Watcher") { $watcherTask = 'exists' }
} catch {}
if (-not $watcherTask) {
  try {
    $t = Get-ScheduledTask -TaskName "DSH-Remote-Watcher" -ErrorAction SilentlyContinue
    if ($t) { $watcherTask = $t.State.ToString() }
  } catch {}
}

$obj = [ordered]@{
  dsh_running = $dshRunning
  dsh_pid = $dshPid
  port = $port
  listening = $listening
  relay_enabled = $relayEnabled
  relay_port = $relayPort
  relay_pid = if ($relayProc.Count -gt 0) { $relayProc[0].ProcessId } else { $null }
  relay_listening = $relayListening
  target_port = $targetPort
  tailscale_online = $tailscaleOnline
  hostname = $hostname
  url = $url
  serve_on = $serveOn
  https_port = $httpsPort
  auto_off = [bool]$cfg.watcher.auto_off
  watcher_task = $watcherTask
  watcher_mode = 'event-driven (WITHIN 2s + 60s reconcile + node)'
  need_admin = $needAdmin
  has_sudo = $hasSudo
  access_denied = $accessDenied
}

if ($Json) {
  $obj | ConvertTo-Json -Depth 3 -Compress | Write-Output
  exit 0
}

Write-Host "DSH Remote Status" -ForegroundColor Cyan
$pidInfo = if ($dshProc) { "(gui pid $($dshProc.Id))" } elseif ($nodeProc) { "(node pid $($nodeProc.ProcessId))" } else { "" }
Write-Host "  DSH running : $dshRunning $pidInfo"
Write-Host "  Port        : $port  (listening=$listening)"
if ($relayEnabled) {
  $relayPidInfo = if ($relayProc.Count -gt 0) { "pid $($relayProc[0].ProcessId)" } else { "not running" }
  Write-Host "  Relay       : 127.0.0.1:$relayPort -> 127.0.0.1:$port ($relayPidInfo, listening=$relayListening)"
}
if ($accessDenied) {
  Write-Host "  Tailscale   : need Administrator (Access is denied) - run as admin" -ForegroundColor Yellow
  Write-Host "  Serve       : unknown (need admin)" -ForegroundColor Yellow
} else {
  Write-Host "  Tailscale   : $(if($tailscaleOnline){"online $hostname"} else {"offline"})"
  Write-Host "  Serve       : $(if($serveOn){"ON  -> $url"} else {"OFF"}) (https :$httpsPort)"
}
Write-Host "  AutoOff     : $($obj.auto_off)  IsAdmin=$(-not $needAdmin) HasSudo=$hasSudo"
Write-Host "  Watcher     : $(if($watcherTask){"$watcherTask (event-driven)"} else {"not installed - run .\Install-Watcher.ps1 (auto sudo)"})"
Write-Host ""
if ($accessDenied) { Write-Host "  -> Access denied even via sudo. Check sudo config: sudo config / ensure ConsentPromptBehaviorAdmin=0" -ForegroundColor Yellow }
elseif ($dshRunning -and -not $serveOn) { Write-Host "  -> Suggest: .\Start-DshRemote.ps1  (auto sudo, no admin needed)" -ForegroundColor Yellow }
elseif (-not $dshRunning -and $serveOn) { Write-Host "  -> Stale expose, suggest: .\Stop-DshRemote.ps1 or wait for Watcher" -ForegroundColor Yellow }
