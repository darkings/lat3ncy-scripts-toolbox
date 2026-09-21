# Get-DshRemoteStatus.ps1
# 查询当前 DSH 进程 + Tailscale Serve 状态，JSON/人类可读双输出

param([switch]$Json)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DshRemoteUtils.ps1')

$cfg = Get-DshRemoteConfig
$snapshot = Get-DshProcessSnapshot
$portInfo = Get-DshPortInfo -ConfiguredPort ([int]$cfg.server.port) -Snapshot $snapshot
$port = [int]$portInfo.Port
$httpsPort = if ($cfg.server.https_port) { [int]$cfg.server.https_port } else { 443 }
$relayEnabled = $true
if ($null -ne $cfg.relay.enabled) { $relayEnabled = [bool]$cfg.relay.enabled }
$relayPort = if ($cfg.relay.port) { [int]$cfg.relay.port } else { 3090 }
# target_port = Tailscale Serve 应当指向的端口，即对外暴露的那一跳。
# relay 启用时是 relay 的监听端口，否则才是 DSH 自己的端口。
# （此前这里把 target_port 直接赋成 $relayPort，语义上混淆了「relay 监听端口」
#  与「relay 的上游目标」；取决于 relay 是否启用的条件本身是对的，保留。）
$servePort = if ($relayEnabled) { $relayPort } else { $port }

$dshProc = @($snapshot.Gui) | Select-Object -First 1
$nodeProc = @($snapshot.Node) | Select-Object -First 1
$dshRunning = [bool]$snapshot.Running
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
  $serveOn = Test-TailscaleServeOn -Port $servePort -HttpsPort $httpsPort -ServeStatus $rawServe
  $tailscaleOnline = $null -ne $hostname
}
$url = if ($hostname) { "https://$hostname" } else { $null }
if ($hostname -and $httpsPort -ne 443) { $url = "https://$hostname`:$httpsPort" }

# 优先 ScheduledTasks cmdlet；schtasks LIST/V 仅作编码失败时的回退。
$watcherInfo = Get-DshWatcherTaskInfo
$watcherTask = if ($watcherInfo.Exists) { $watcherInfo.Status } else { $null }
$watcherLastRun = $watcherInfo.LastRun

# 核心 bundle 自检：缺失会导致「页面 200 但 /api 404」，值得在状态里直接可见。
$bundleState = Test-DshCoreBundles
$bundleMissing = @($bundleState.Missing | ForEach-Object { $_.Name })

$obj = [ordered]@{
  dsh_running = $dshRunning
  dsh_pid = $dshPid
  port = $port
  listening = $listening
  relay_enabled = $relayEnabled
  relay_port = $relayPort
  relay_pid = if ($relayProc.Count -gt 0) { $relayProc[0].ProcessId } else { $null }
  relay_listening = $relayListening
  # serve_port: Tailscale Serve 的目标端口（relay 启用时是 relay 端口）。
  # target_port: 保留旧字段名，语义同 serve_port，避免破坏已有调用方。
  serve_port = $servePort
  target_port = $servePort
  relay_upstream_port = $port
  tailscale_online = $tailscaleOnline
  hostname = $hostname
  url = $url
  serve_on = $serveOn
  https_port = $httpsPort
  auto_off = [bool]$cfg.watcher.auto_off
  core_bundles_ok = $bundleState.Ok
  core_bundles_missing = $bundleMissing
  watcher_task = $watcherTask
  watcher_last_run = $watcherLastRun
  watcher_mode = 'event-driven (WITHIN 2s + 60s reconcile + filtered node)'
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
if ($bundleState.Unknown) {
  Write-Host "  CoreBundles : unknown (profile package.json not readable)" -ForegroundColor Yellow
} elseif ($bundleState.Ok) {
  Write-Host "  CoreBundles : OK"
} else {
  Write-Host "  CoreBundles : MISSING $($bundleMissing -join ', ')" -ForegroundColor Red
  Write-Host "                -> /api will return 404 until restored; run .\Start-DshRemote.ps1 to link them" -ForegroundColor Yellow
}
$watcherText = if ($watcherTask) {
  if ($watcherLastRun) { "$watcherTask (event-driven, last $watcherLastRun)" } else { "$watcherTask (event-driven)" }
} else {
  "not installed - run .\Install-Watcher.ps1 (auto sudo)"
}
Write-Host "  Watcher     : $watcherText"
Write-Host ""
if ($accessDenied) { Write-Host "  -> Access denied even via sudo. Check sudo config: sudo config / ensure ConsentPromptBehaviorAdmin=0" -ForegroundColor Yellow }
elseif ($dshRunning -and -not $serveOn) { Write-Host "  -> Suggest: .\Start-DshRemote.ps1  (auto sudo, no admin needed)" -ForegroundColor Yellow }
elseif (-not $dshRunning -and $serveOn) { Write-Host "  -> Stale expose, suggest: .\Stop-DshRemote.ps1 or wait for Watcher" -ForegroundColor Yellow }
