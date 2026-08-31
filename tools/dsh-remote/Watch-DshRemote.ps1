# Watch-DshRemote.ps1
# Event-driven + periodic reconcile hybrid watcher
# - Primary: WMI __InstanceCreationEvent / __InstanceDeletionEvent WITHIN 2s (no admin, script sleeps 0 CPU)
# - Fallback: reconcile every 60s + immediate reconcile on start, survives crash/missed events
# - Probe: wait for port Listen before exposing to avoid 502

param(
  [int]$PollInterval = 0,
  [switch]$Once,
  [switch]$NoNotify
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "DshRemoteUtils.ps1")

$cfg = Get-DshRemoteConfig
$portCfg = [int]$cfg.server.port
$httpsPort = if ($cfg.server.https_port) { [int]$cfg.server.https_port } else { 443 }
$relayEnabled = $true
if ($null -ne $cfg.relay.enabled) { $relayEnabled = [bool]$cfg.relay.enabled }
$relayPort = if ($cfg.relay.port) { [int]$cfg.relay.port } else { 3090 }
# 对账周期默认 60s。命令行 / 配置小于 30s 会被抬到至少 30s，避免空转。
$reconcileSec = 60
if ($PollInterval -gt 0) { $reconcileSec = [Math]::Max(30, $PollInterval) }
else {
  $cfgPoll = [int]$cfg.watcher.poll_interval
  if ($cfgPoll -ge 30) { $reconcileSec = $cfgPoll }
}
$autoOff = $true
if ($null -ne $cfg.watcher.auto_off) { $autoOff = [bool]$cfg.watcher.auto_off }
$probeTimeout = if ($cfg.watcher.probe_timeout) { [int]$cfg.watcher.probe_timeout } else { 12 }

# 上次已记录的 relay PID；复用已有进程时不再刷 "Relay ready"。
$script:LastRelayPid = 0
# 本会话是否见过 DSH 在跑。开机残留 Serve 清理不能弹「已关闭」。
$script:SeenDshThisSession = $false
$logFile = Join-Path $PSScriptRoot "watcher.log"
# 超过 5 MB 时轮转为 watcher.log.1，只保留一份旧日志，避免无限追加。
$logMaxBytes = 5MB
function Invoke-WatcherLogRotation {
  try {
    if (-not (Test-Path -LiteralPath $logFile)) { return }
    $item = Get-Item -LiteralPath $logFile
    if ($item.Length -lt $logMaxBytes) { return }
    $rotated = Join-Path $PSScriptRoot "watcher.log.1"
    if (Test-Path -LiteralPath $rotated) {
      Remove-Item -LiteralPath $rotated -Force
    }
    Move-Item -LiteralPath $logFile -Destination $rotated -Force
  } catch {
    # 轮转失败时继续追加，不能让 Watcher 因日志 IO 退出。
  }
}
function Write-Log([string]$msg) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Invoke-WatcherLogRotation
  "[$ts] $msg" | Out-File -LiteralPath $logFile -Append -Encoding UTF8
  Write-Host "[$ts] $msg"
}

# Prevent two current-session/task instances from fighting over Tailscale Serve.
# The named mutex is released automatically when the owning PowerShell exits.
$watcherMutex = $null
try {
  $mutexCreatedNew = $false
  $watcherMutex = [Threading.Mutex]::new($false, 'Local\DSH-Remote-Watcher', [ref]$mutexCreatedNew)
  $mutexHeld = $false
  try { $mutexHeld = $watcherMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
  if (-not $mutexHeld) {
    Write-Log 'Watcher already running; duplicate instance exits'
    exit 0
  }
} catch {
  Write-Log "WARN: watcher singleton mutex unavailable: $($_.Exception.Message)"
}

function Sync-RemoteState {
  $snapshot = Get-DshProcessSnapshot
  $portInfo = Get-DshPortInfo -ConfiguredPort $portCfg -Snapshot $snapshot
  $resolvedPort = [int]$portInfo.Port
  $portSource = [string]$portInfo.Source
  $targetPort = if ($relayEnabled) { $relayPort } else { $resolvedPort }
  $dshRunning = Test-DshProcessRunning -Snapshot $snapshot
  # 端口监听也视为运行（强化：即使进程查询受限，只要 3081 在 Listen 就认为 DSH 在线）
  if (-not $dshRunning) {
    try { if (Test-DshListening -Port $resolvedPort) { $dshRunning = $true } } catch {}
  }
  if ($dshRunning) { $script:SeenDshThisSession = $true }
  if ($dshRunning -and $relayEnabled) {
    try {
      $relayProc = Start-DshRelay -TargetPort $resolvedPort -ListenPort $relayPort
      $relayPid = [int]$relayProc.ProcessId
      # 已在跑的 relay 每轮对账都会走到这里，只在 PID 变化时记一条。
      if ($relayPid -ne $script:LastRelayPid) {
        Write-Log "Relay ready: 127.0.0.1:$relayPort -> 127.0.0.1:$resolvedPort (pid $relayPid)"
        $script:LastRelayPid = $relayPid
      }
    } catch {
      Write-Log "FAIL: loopback relay unavailable: $($_.Exception.Message)"
      return
    }
  }
  # Check access: if still denied even after sudo fallback, skip
  $raw = Get-TailscaleServeStatus
  if ($raw -eq "__ACCESS_DENIED__") {
    Write-Log "WARN: tailscaled still Access denied even via sudo - skip (check sudo config)"
    return
  }
  $serveOn = Test-TailscaleServeOn -Port $targetPort -HttpsPort $httpsPort -ServeStatus $raw

  if ($dshRunning -and -not $serveOn) {
    Write-Log "DSH running but Serve OFF -> exposing :$targetPort (source: $portSource, backend :$resolvedPort)"
    $deadline = (Get-Date).AddSeconds($probeTimeout)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
      if (Test-DshListening -Port $resolvedPort) { $ok = $true; break }
      Start-Sleep -Milliseconds 500
    }
    if (-not $ok) {
      Write-Log "WARN: port $resolvedPort not listening after ${probeTimeout}s, still trying serve"
    }
    try {
      $r = Invoke-TailscaleServe -ServeArgs "--yes --bg --https=$httpsPort $targetPort"
      $out = $r.Output
      Write-Log ("tailscale serve on : " + $out.Trim())
      Start-Sleep -Milliseconds 800
      $serveOn = Test-TailscaleServeOn -Port $targetPort -HttpsPort $httpsPort -ServeStatus (Get-TailscaleServeStatus)
      if ($serveOn) {
        $hn = Get-TailscaleHostname
        if ($relayEnabled) {
          Write-Log "OK: Serve ON https://$hn -> relay 127.0.0.1:$targetPort -> DSH 127.0.0.1:$resolvedPort"
        } else {
          Write-Log "OK: Serve ON https://$hn -> 127.0.0.1:$targetPort"
        }
        if (-not $NoNotify) { Invoke-DshRemoteNotify -Type "success" -Text "Remote ready $hn" }
      } else {
        Write-Log "WARN: Serve apply failed, check 'tailscale serve status' output: $out"
      }
    } catch {
      Write-Log "FAIL: tailscale serve on error: $($_.Exception.Message)"
    }
    return
  }

  if (-not $dshRunning -and $serveOn -and $autoOff) {
    $leftover = -not $script:SeenDshThisSession
    if ($leftover) {
      Write-Log "Serve ON but DSH never started this session -> silently disabling leftover expose"
    } else {
      Write-Log "DSH not running but Serve ON -> disabling (auto_off=true)"
    }
    try {
      $r = Invoke-TailscaleServe -ServeArgs "--https=$httpsPort off"
      $out = $r.Output
      Write-Log ("tailscale serve off : " + $out.Trim())
      if ($relayEnabled) {
        $stoppedRelay = Stop-DshRelay -ListenPort $relayPort
        if ($stoppedRelay -gt 0) { Write-Log "Relay stopped ($stoppedRelay process)" }
        $script:LastRelayPid = 0
      }
      # 开机残留 Serve 不是用户关了 DSH，不要弹「已关闭」。
      if (-not $leftover -and -not $NoNotify) {
        Invoke-DshRemoteNotify -Type "info" -Text "DSH closed, remote disconnected"
      }
    } catch {
      Write-Log "FAIL: tailscale serve off error: $($_.Exception.Message)"
    }
    return
  }

  if (-not $dshRunning -and $serveOn -and -not $autoOff) {
    Write-Log "DSH not running but Serve ON (auto_off=false) -> keep exposed"
    return
  }
}

Write-Log "Watcher started pid=$PID (event-driven WITHIN 2s + reconcile ${reconcileSec}s, auto_off=$autoOff) IsAdmin=$(Test-IsAdmin) SudoAvailable=$(Test-SudoAvailable)"
# With sudo inline mode (UAC ConsentPromptBehaviorAdmin=0), non-admin can still manage Serve via sudo
$probeAccess = Get-TailscaleServeStatus
if ($probeAccess -eq "__ACCESS_DENIED__") {
  Write-Log "WARN: Watcher cannot access tailscaled even via sudo (Access is denied). Check sudo/UAC config."
  if ($Once) { exit 1 }
  Write-Log "Will keep retrying each reconcile; install elevated task if needed: sudo .\Install-Watcher.ps1"
}
Sync-RemoteState
if ($Once) { Write-Log "Once mode, exit"; exit 0 }

$createdOk = $false
$deletedOk = $false
$eventJobs = @()

try {
  $qCreate = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name='deepseek-harness-desktop.exe'"
  $qDelete = "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name='deepseek-harness-desktop.exe'"
  $jobC = Register-WmiEvent -Query $qCreate -SourceIdentifier "DSH_Create" -ErrorAction Stop
  $createdOk = $true
  Write-Log "WMI event registered: __InstanceCreationEvent (deepseek-harness-desktop.exe)"
  $eventJobs += $jobC
} catch {
  Write-Log "WARN: Register __InstanceCreationEvent failed: $($_.Exception.Message) -> fallback to polling"
}
try {
  $qDelete2 = "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name='deepseek-harness-desktop.exe'"
  $jobD = Register-WmiEvent -Query $qDelete2 -SourceIdentifier "DSH_Delete" -ErrorAction Stop
  $deletedOk = $true
  Write-Log "WMI event registered: __InstanceDeletionEvent (deepseek-harness-desktop.exe)"
  $eventJobs += $jobD
} catch {
  Write-Log "WARN: Register __InstanceDeletionEvent failed: $($_.Exception.Message)"
}
# 额外监控 node 后端（避免仅靠 60s 轮询；事件触发后会通过 Sync-RemoteState 的端口/进程双重判定过滤非 DSH 的 node）
try {
  $qNodeCreate = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name='node.exe'"
  $jobNC = Register-WmiEvent -Query $qNodeCreate -SourceIdentifier "DSH_NodeCreate" -ErrorAction Stop
  Write-Log "WMI event registered: __InstanceCreationEvent (node.exe)"
  $eventJobs += $jobNC
} catch {
  Write-Log "WARN: Register node __InstanceCreationEvent failed: $($_.Exception.Message)"
}
try {
  $qNodeDelete = "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name='node.exe'"
  $jobND = Register-WmiEvent -Query $qNodeDelete -SourceIdentifier "DSH_NodeDelete" -ErrorAction Stop
  Write-Log "WMI event registered: __InstanceDeletionEvent (node.exe)"
  $eventJobs += $jobND
} catch {
  Write-Log "WARN: Register node __InstanceDeletionEvent failed: $($_.Exception.Message)"
}

$useFallbackPoll = (-not $createdOk -and -not $deletedOk)
if ($useFallbackPoll) {
  Write-Log "Both WMI events failed, using fallback poll every ${reconcileSec}s"
}

$lastReconcile = Get-Date
try {
  while ($true) {
    $timeoutSec = $reconcileSec - ((Get-Date) - $lastReconcile).TotalSeconds
    if ($timeoutSec -lt 1) { $timeoutSec = 1 }

    if ($useFallbackPoll) {
      Start-Sleep -Seconds ([int]$timeoutSec)
      Write-Log "Reconcile (fallback poll)"
      Sync-RemoteState
      $lastReconcile = Get-Date
      continue
    }

    $ev = Wait-Event -Timeout ([int]$timeoutSec)

    if ($null -ne $ev) {
      $src = $ev.SourceIdentifier
      $toRemove = @(Get-Event | Where-Object { $_.SourceIdentifier -eq $src })
      foreach ($e in $toRemove) { Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue }

      if ($src -eq "DSH_Create") {
        Write-Log "Event: DSH process created"
        Start-Sleep -Milliseconds 1500
        Sync-RemoteState
        $lastReconcile = Get-Date
      } elseif ($src -eq "DSH_Delete") {
        Write-Log "Event: DSH process deleted"
        Start-Sleep -Milliseconds 800
        Sync-RemoteState
        $lastReconcile = Get-Date
      } elseif ($src -eq "DSH_NodeCreate" -or $src -eq "DSH_NodeDelete") {
        # 过滤：仅当 node 事件关联到 DSH 后端时才处理（避免所有 node 都触发）
        $isDshNode = $false
        try {
          $evt = $ev.SourceEventArgs.NewEvent
          if ($evt -and $evt.TargetInstance -and $evt.TargetInstance.CommandLine -like "*deepseek-harness*") { $isDshNode = $true }
          elseif ($evt -and $evt.TargetInstance -and $evt.TargetInstance.CommandLine -like "*dsh*") { $isDshNode = $true }
        } catch {}
        # CommandLine 读不到时忽略这次 node 事件，避免任意 node.exe 都唤醒对账。
        # DSH GUI 事件和 60s 周期对账仍会覆盖 Serve / relay。
        if ($isDshNode) {
          $action = if ($src -eq "DSH_NodeCreate") { "created" } else { "deleted" }
          Write-Log ("Event: DSH node {0}" -f $action)
          Start-Sleep -Milliseconds 1200
          Sync-RemoteState
          $lastReconcile = Get-Date
        }
        # 非 DSH 的 node.exe 启停忽略：不写日志、不对账、不重置 lastReconcile。
        # Serve / relay 仍由 DSH 进程事件和 60s 周期对账覆盖。
      } else {
        Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
        Sync-RemoteState
        $lastReconcile = Get-Date
      }
      if ($ev.EventIdentifier) { Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue }
    } else {
      # 状态未变时 Sync-RemoteState 自己保持安静，这里不再每轮写周期心跳。
      Sync-RemoteState
      $lastReconcile = Get-Date
    }
  }
} finally {
  foreach ($id in @("DSH_Create","DSH_Delete","DSH_NodeCreate","DSH_NodeDelete")) {
    try { Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue } catch {}
    try { Remove-Event -SourceIdentifier $id -ErrorAction SilentlyContinue } catch {}
  }
  foreach ($j in $eventJobs) {
    try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
  }
  Write-Log "Watcher stopped"
}
