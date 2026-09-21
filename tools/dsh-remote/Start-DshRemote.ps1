# Start-DshRemote.ps1
# 一键暴露本地 DSH 到 Tailscale 尾网（手机需加入同一 Tailnet）
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-DshRemote.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-DshRemote.ps1 -Port 3081
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-DshRemote.ps1 -Disable
#
# 配置文件: ./config.toml  (server.port=0 表示自动探测)

param(
  [int]$Port = 0,
  [switch]$Disable,
  [switch]$Json,
  [switch]$NoNotify,
  # 只检测核心 bundle 缺失并报告，不自动补建 junction。
  [switch]$SkipBundleRepair
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DshRemoteUtils.ps1')
$cfg = Get-DshRemoteConfig
$httpsPort = if ($cfg.server.https_port) { [int]$cfg.server.https_port } else { 443 }
$relayEnabled = $true
if ($null -ne $cfg.relay.enabled) { $relayEnabled = [bool]$cfg.relay.enabled }
$relayPort = if ($cfg.relay.port) { [int]$cfg.relay.port } else { 3090 }

function Emit([string]$msg, [string]$level = 'info') {
  if ($Json) { return }
  switch ($level) {
    'ok'   { Write-DshOK $msg }
    'warn' { Write-DshWarn $msg }
    'fail' { Write-DshFail $msg }
    default { Write-DshStep $msg }
  }
}

# --- Disable 分支 ---
if ($Disable) {
  Emit 'Disabling Tailscale Serve proxy'
  $r = Invoke-TailscaleServe -ServeArgs "--https=$httpsPort off"
  $out = $r.Output
  if (-not $Json) { $out | Out-Host }
  if ($relayEnabled) {
    $stoppedRelay = Stop-DshRelay -ListenPort $relayPort
    if (-not $Json -and $stoppedRelay -gt 0) { Write-DshOK "Local relay stopped ($stoppedRelay process)." }
  }
  if (-not $NoNotify) { Invoke-DshRemoteNotify -Type 'info' -Text 'Remote closed' }
  if ($out -match "Access is denied") { Emit 'Access denied - elevation failed (sudo not available?)' 'fail'; exit 1 }
  if ($Json) { @{ ok = $true; enabled = $false; message = 'Serve disabled' } | ConvertTo-Json -Compress | Write-Output }
  exit 0
}

# --- 1. Tailscale 必须在线 ---
$tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $tailscale) {
  Emit 'tailscale CLI not found. Install: https://tailscale.com/download' 'fail'
  if ($Json) { @{ ok = $false; error = 'tailscale not found' } | ConvertTo-Json -Compress | Write-Output }
  exit 1
}
Emit 'Checking Tailscale status'
$rStat = Invoke-TailscaleCommand -Arguments "status --json"
$rawStatus = $rStat.Output; $code = $rStat.ExitCode
if ($rawStatus -match "Access is denied") {
  Emit 'tailscale status: Access is denied (elevation via sudo also failed).' 'fail'
  if ($Json) { @{ ok = $false; error = 'access denied'; need_admin = $true } | ConvertTo-Json -Compress | Write-Output }
  exit 1
}
try { $status = $rawStatus | ConvertFrom-Json -ErrorAction Stop } catch {
  Emit "tailscale status --json failed: $($_.Exception.Message) (code $code)" 'fail'
  if ($Json) { @{ ok = $false; error = 'tailscale status failed' } | ConvertTo-Json -Compress | Write-Output }
  exit 1
}
if ($status.BackendState -ne 'Running' -or -not $status.Self.Online) {
  Emit ("Tailscale is not online (state: {0}). Connect Tailscale first." -f $status.BackendState) 'fail'
  if ($Json) { @{ ok = $false; error = 'tailscale offline'; state = $status.BackendState } | ConvertTo-Json -Compress | Write-Output }
  exit 1
}
$hostname = $status.Self.DNSName.TrimEnd('.')
Emit "Tailscale online: $hostname" 'ok'

# --- 2. 解析端口（动态查询 DSH 真实端口，不写死）---
if ($Port -gt 0) {
  $resolvedPort = $Port
  $portSource = "cli:-Port $Port"
} else {
  $portInfo = Get-DshPortInfo -ConfiguredPort $cfg.server.port
  $resolvedPort = [int]$portInfo.Port
  $portSource = [string]$portInfo.Source
  if ($resolvedPort -le 0) {
    # 端口探测失败不再静默退回 3081：那会让 relay 指向一个没人监听的端口，
    # 最终以 "ECONNREFUSED 127.0.0.1:3081" 的形式把探测失败伪装成网络故障。
    Emit "Could not resolve the local DSH port. Start DSH Desktop first, or set server.port in config.toml." 'fail'
    if ($Json) { @{ ok = $false; error = 'port not resolved'; source = $portSource } | ConvertTo-Json -Compress | Write-Output }
    exit 1
  }
}
$probeTimeout = if ($cfg.watcher.probe_timeout) { [int]$cfg.watcher.probe_timeout } else { 12 }
Emit "Target port: $resolvedPort (source: $portSource, https :$httpsPort)"

# --- 3. 本地 DSH 必须监听 ---
Emit "Checking local service on port $resolvedPort"
$deadline = (Get-Date).AddSeconds($probeTimeout)
$found = $false
while ((Get-Date) -lt $deadline) {
  if (Test-DshListening -Port $resolvedPort) { $found = $true; break }
  Start-Sleep -Milliseconds 600
}
if (-not $found) {
  Emit "Nothing is listening on 127.0.0.1:$resolvedPort. Start DSH Desktop first." 'fail'
  if ($Json) { @{ ok = $false; error = 'port not listening'; port = $resolvedPort } | ConvertTo-Json -Compress | Write-Output }
  exit 1
}
Emit "Service listening on 127.0.0.1:$resolvedPort" 'ok'

# --- 3b. 核心 bundle 自检 ---
# 这是「DSH 在跑、页面 200、但 /api 404」的常见根因：profile 的 node_modules 里
# 缺少核心 bundle（@deepseek-ai/dsh-web-app 负责挂载 /api），通常是插件增删失败
# 触发恢复式卸载后留下的残缺状态。提前拦住，别等跑到最后的 API 探测才报错。
$bundleState = Test-DshCoreBundles
if ($bundleState.Unknown) {
  Emit 'Skipped core bundle check (profile package.json not readable).' 'warn'
} elseif (-not $bundleState.Ok) {
  $names = ($bundleState.Missing | ForEach-Object { $_.Name }) -join ', '
  Emit "Core bundle(s) missing from the web profile: $names" 'warn'
  if ($bundleState.Restorable.Count -gt 0 -and -not $SkipBundleRepair) {
    try {
      $repair = Repair-DshCoreBundles
      if ($repair.Created.Count -gt 0) {
        Emit "Linked missing core bundle(s) from the dependency tree: $($repair.Created -join ', ')" 'ok'
        Emit 'Restart DSH Desktop for the plugin tree to reload, then re-run this script.' 'warn'
      }
      foreach ($f in $repair.Failed) { Emit "Could not link $($f.Name): $($f.Error)" 'fail' }
    } catch {
      Emit "Core bundle repair failed: $($_.Exception.Message)" 'fail'
    }
  }
  if ($bundleState.Unrestorable.Count -gt 0) {
    $un = ($bundleState.Unrestorable | ForEach-Object { $_.Name }) -join ', '
    Emit "Not present in the dependency tree (must be installed, not linked): $un" 'warn'
    Emit 'Run a plugin add/remove in DSH Settings -> Plugins to trigger a profile reinstall.' 'warn'
  }
  $bundleState = Test-DshCoreBundles
  if (-not $bundleState.Ok) {
    Emit 'The /api route will not be mounted until these bundles are restored.' 'fail'
    Emit 'Fix it, then fully quit and restart DSH Desktop before relying on remote access.' 'warn'
  }
} else {
  Emit 'Core bundles present' 'ok'
}

# --- 4. 启动 loopback relay（让 DSH API 通过 trust fence）---
$targetPort = $resolvedPort
if ($relayEnabled) {
  if ($relayPort -eq $resolvedPort) {
    Emit "Relay port cannot equal DSH port ($relayPort)" 'fail'
    if ($Json) { @{ ok = $false; error = 'relay port equals dsh port'; port = $resolvedPort; relay_port = $relayPort } | ConvertTo-Json -Compress | Write-Output }
    exit 1
  }
  try {
    $relayProc = Start-DshRelay -TargetPort $resolvedPort -ListenPort $relayPort
    $targetPort = $relayPort
    Emit "Loopback relay ready: 127.0.0.1:$relayPort -> 127.0.0.1:$resolvedPort (pid $($relayProc.ProcessId))" 'ok'
  } catch {
    Emit "Could not start loopback relay: $($_.Exception.Message)" 'fail'
    if ($Json) { @{ ok = $false; error = 'relay start failed'; detail = $_.Exception.Message; port = $resolvedPort; relay_port = $relayPort } | ConvertTo-Json -Compress | Write-Output }
    exit 1
  }
} else {
  Emit 'Loopback relay disabled; remote DSH API may return 403 unless DSH trusts the public hostname.' 'warn'
}

# --- 5. 幂等配置 Serve ---
Emit 'Checking existing Tailscale Serve config'
$serveStatus = Get-TailscaleServeStatus
$isOn = Test-TailscaleServeOn -Port $targetPort -HttpsPort $httpsPort -ServeStatus $serveStatus
if ($isOn) {
  Emit "Serve already configured for :$targetPort, no change needed." 'ok'
} else {
  if ($relayEnabled) {
    Emit "Applying Tailscale Serve config (https://head:$httpsPort -> relay 127.0.0.1:$targetPort -> DSH 127.0.0.1:$resolvedPort)"
  } else {
    Emit "Applying Tailscale Serve config (https://head:$httpsPort -> 127.0.0.1:$targetPort)"
  }
  $rApply = Invoke-TailscaleServe -ServeArgs "--yes --bg --https=$httpsPort $targetPort"
  $applyOut = $rApply.Output; $code2 = $rApply.ExitCode
  if ($applyOut -match "Access is denied") { Emit 'Access denied - elevation via sudo failed' 'fail'; exit 1 }
  if (-not $Json) { $applyOut | Out-Host }
  # 二次确认
  Start-Sleep -Milliseconds 800
  $serveStatus = Get-TailscaleServeStatus
  $isOn = Test-TailscaleServeOn -Port $targetPort -HttpsPort $httpsPort -ServeStatus $serveStatus
  if (-not $isOn) {
    Emit "Serve apply seems failed. Check 'tailscale serve status'." 'warn'
  }
}

# --- 6. 验证端点 ---
Emit 'Verifying endpoint'
$url = "https://$hostname"
if ($httpsPort -ne 443) { $url = "https://$hostname`:$httpsPort" }
$probeResult = $null
try {
  # 优先用 curl.exe 避免 PowerShell 证书问题
  $curlOut = curl.exe -s -o NUL -w "%{http_code}" $url --max-time 12 2>$null
  if ($curlOut -match '2\d\d') { $probeResult = @{ StatusCode = [int]$curlOut } }
  else {
    # 回退到 Invoke-WebRequest
    $probeResult = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 12 -SkipCertificateCheck -ErrorAction Stop
  }
} catch {
  try { $probeResult = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop } catch {
    Emit "Probe request failed: $($_.Exception.Message)" 'warn'
    Emit "Config is applied, but endpoint did not respond. DSH may still be starting." 'warn'
    if ($Json) {
      @{ ok = $true; enabled = $true; url = $url; port = $resolvedPort; target_port = $targetPort; relay_enabled = $relayEnabled; relay_port = $relayPort; hostname = $hostname; probe = 'failed'; warning = $_.Exception.Message } | ConvertTo-Json -Compress | Write-Output
    } else {
      Write-Host ''
      Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
      Write-Host '  Config applied but probe failed (DSH starting?)' -ForegroundColor Yellow
      Write-Host "  URL : $url" -ForegroundColor Cyan
      Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
    }
    exit 0
  }
}

$code = if ($probeResult.StatusCode) { [int]$probeResult.StatusCode } else { 200 }
Emit "HTTP $code - $url" 'ok'

# GET 只能证明静态页面可达；workspace 实际依赖 POST /api + WebSocket。
# 这里用 workspace.list 探测 /api 路由是否挂载，但状态码语义要分清：
#   401 = 路由已挂载但本探测未带浏览器会话 cookie —— 这正是健康状态。
#         DSH 自 0.1.2 起对整条 /api 面要求鉴权，而 curl 没有 cookie，
#         所以 401 是「API 正常」的证据，不是失败。
#   403 = Host/Origin 信任围栏拒绝 —— 说明 relay 没生效或 Host 未重写。
#   404 = /api 路由根本没挂载 —— 通常是 DSH 进程启动了但插件树加载不完整
#         （典型原因：端口被占导致 webserver 插件 EADDRINUSE，boot 半途失败）。
#   2xx = 带了有效凭据且调用成功。
$rpcBody = '{"type":"client-request","rpcId":"00000000-0000-4000-8000-000000000001","method":"workspace.list","payload":{}}'
$apiCode = $null
try {
  $apiRaw = curl.exe -s -o NUL -w "%{http_code}" -X POST "$url/api/workspace.list" -H "content-type: application/json" --data-raw $rpcBody --max-time 12 2>$null
  if ($apiRaw -match '^\d{3}$') { $apiCode = [int]$apiRaw }
} catch {}
$apiOk = ($null -ne $apiCode) -and ($apiCode -eq 401 -or $apiCode -eq 403 -or ($apiCode -ge 200 -and $apiCode -lt 300))
if (-not $apiOk) {
  $apiText = if ($null -eq $apiCode) { 'unreachable' } else { "HTTP $apiCode" }
  Emit "Workspace API check failed: $apiText" 'fail'
  switch ($apiCode) {
    404 { Emit 'The /api route is not mounted. DSH is running but its plugin tree did not load fully - restart DSH Desktop (check for EADDRINUSE on the harness port).' 'warn' }
    403 { Emit 'The Host/Origin trust fence rejected the request. Ensure the loopback relay is running (it rewrites Host/Origin), or add the hostname to DSH trustedHosts.' 'warn' }
    default { Emit 'The page is reachable, but the DSH API is not usable. Keep the relay enabled.' 'warn' }
  }
  if ($Json) {
    @{ ok = $false; enabled = $true; url = $url; port = $resolvedPort; target_port = $targetPort; relay_enabled = $relayEnabled; relay_port = $relayPort; hostname = $hostname; http_code = $code; api_code = $apiCode } | ConvertTo-Json -Compress | Write-Output
  }
  exit 1
}
$apiLabel = if ($apiCode -eq 401) { 'HTTP 401 (route mounted; auth expected for cookie-less probe)' } elseif ($apiCode -eq 403) { 'HTTP 403 (route mounted; trust fence active)' } else { "HTTP $apiCode" }
Emit "Workspace API $apiLabel - relay/trust check passed" 'ok'

if (-not $NoNotify) { Invoke-DshRemoteNotify -Type 'success' -Text "Remote ready $hostname" }

if ($Json) {
  @{ ok = $true; enabled = $true; url = $url; port = $resolvedPort; target_port = $targetPort; relay_enabled = $relayEnabled; relay_port = $relayPort; https_port = $httpsPort; hostname = $hostname; http_code = $code; api_code = $apiCode } | ConvertTo-Json -Compress | Write-Output
  exit 0
}

Write-Host ''
Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
Write-Host '  Phone access ready (phone must be connected to Tailscale)' -ForegroundColor Cyan
Write-Host "  URL : $url" -ForegroundColor Cyan
if ($relayEnabled) { Write-Host "  API : relay 127.0.0.1:$relayPort -> DSH 127.0.0.1:$resolvedPort" -ForegroundColor Cyan }
Write-Host "  Off : tailscale serve --https=$httpsPort off  (or .\Start-DshRemote.ps1 -Disable)" -ForegroundColor Cyan
Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
exit 0
