$ErrorActionPreference = 'Stop'

function Get-DshRemoteConfig {
  $configFile = Join-Path $PSScriptRoot "config.toml"
  $config = @{
    server = @{ port = 0; https_port = 443 }
    relay = @{ enabled = $true; port = 3090 }
    watcher = @{ poll_interval = 60; auto_off = $true; probe_timeout = 12 }
    general = @{ show_notification = $true }
  }
  if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { return $config }
  $section = ""
  foreach ($line in (Get-Content -LiteralPath $configFile -Encoding UTF8)) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }
    if ($t -match "^\[([a-zA-Z0-9_\-]+)\]$") {
      $section = $matches[1]
      if (-not $config.ContainsKey($section)) { $config[$section] = @{} }
      continue
    }
    if ($t -match "^([a-zA-Z0-9_\-]+)\s*=\s*(.+)$") {
      $k = $matches[1]
      $vStr = $matches[2].Trim()
      if ($vStr -match "^(`"[^`"]*`"|'[^']*')\s*#") { $vStr = $matches[1] }
      elseif ($vStr -match '^(true|false|-?\d+)\s*#') { $vStr = $matches[1] }
      elseif ($vStr.Contains('#') -and -not $vStr.StartsWith('"') -and -not $vStr.StartsWith("'")) {
        $vStr = ($vStr -split '#')[0].Trim()
      }
      $v = $vStr
      if ($vStr -match '^"(.*)"$' -or $vStr -match "^'(.*)'$") {
        $v = $matches[1] -replace "\\\\", "\"
      }
      elseif ($vStr -eq "true") { $v = $true }
      elseif ($vStr -eq "false") { $v = $false }
      elseif ($vStr -match "^-?\d+$") { $v = [int]$vStr }
      if ($section) { $config[$section][$k] = $v }
    }
  }
  return $config
}

function Get-DshProcessSnapshot {
  # GUI + DSH node 一次取齐，端口探测 / 运行判定 / 状态查询共用，避免同一轮重复扫进程。
  $gui = @()
  $node = @()
  try {
    $foundGui = Get-Process -Name "deepseek-harness-desktop" -ErrorAction SilentlyContinue
    if ($foundGui) { $gui = @($foundGui) }
  } catch {}
  try {
    $foundNode = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like "*deepseek-harness*" }
    if ($foundNode) { $node = @($foundNode) }
  } catch {}
  $guiPids = @($gui | ForEach-Object { $_.Id })
  $nodePids = @($node | ForEach-Object { $_.ProcessId })
  $portNodePids = @($node | Where-Object { $_.CommandLine -like "*--port*" } | ForEach-Object { $_.ProcessId })
  return @{
    Gui = $gui
    Node = $node
    GuiPids = $guiPids
    NodePids = $nodePids
    PortNodePids = $portNodePids
    Running = (($guiPids.Count + $nodePids.Count) -gt 0)
  }
}

function Test-DshProcessRunning {
  param($Snapshot = $null)
  if ($null -eq $Snapshot) { $Snapshot = Get-DshProcessSnapshot }
  return [bool]$Snapshot.Running
}

function Get-DshPortInfo {
  param(
    [int]$ConfiguredPort = 0,
    $Snapshot = $null
  )
  # 一次探测同时给出 Port 与 Source，避免 Get-DshPort / Get-DshPortSource 各扫一遍进程。
  # 端口优先级保持不变：config -> .store.dat -> 进程监听 -> netstat -> 3081/3080 -> 3081。
  if ($ConfiguredPort -gt 0) {
    return @{ Port = $ConfiguredPort; Source = "config.toml:$ConfiguredPort" }
  }

  $store = Join-Path $env:APPDATA "io.github.hairyf.deepseek-harness-desktop\.store.dat"
  if (Test-Path -LiteralPath $store) {
    try {
      $j = Get-Content -LiteralPath $store -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $p = $j.setting.port
      if ($null -ne $p -and "$p" -match "^\d+$") {
        $pi = [int]"$p"
        if ($pi -gt 0 -and $pi -lt 65535) {
          return @{ Port = $pi; Source = ".store.dat:$pi" }
        }
      }
    } catch {}
  }

  if ($null -eq $Snapshot) { $Snapshot = Get-DshProcessSnapshot }
  $tcpPids = @($Snapshot.GuiPids + $Snapshot.PortNodePids)
  $allPids = @($Snapshot.GuiPids + $Snapshot.NodePids)

  try {
    if ($tcpPids.Count -gt 0) {
      $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $tcpPids -contains $_.OwningProcess }
      $local = $conns | Where-Object { $_.LocalAddress -eq "127.0.0.1" } | Sort-Object LocalPort | Select-Object -First 1
      if ($local) {
        return @{ Port = [int]$local.LocalPort; Source = "process:$($local.LocalPort) (pid $($local.OwningProcess))" }
      }
      $any = $conns | Sort-Object LocalPort | Select-Object -First 1
      if ($any) {
        return @{ Port = [int]$any.LocalPort; Source = "process:$($any.LocalPort) (pid $($any.OwningProcess))" }
      }
    }
  } catch {}

  try {
    $out = netstat -ano 2>$null | Out-String
    foreach ($pId in $allPids) {
      if ($out -match "127\.0\.0\.1:(\d+)\s+.*LISTENING\s+$pId") {
        $found = [int]$matches[1]
        return @{ Port = $found; Source = "netstat:$found (pid $pId)" }
      }
      if ($out -match "0\.0\.0\.0:(\d+)\s+.*LISTENING\s+$pId") {
        $found = [int]$matches[1]
        return @{ Port = $found; Source = "netstat:$found (pid $pId)" }
      }
    }
    foreach ($p in @(3081, 3080)) {
      if ($out -match ":$p\s+.*LISTENING") {
        return @{ Port = $p; Source = "netstat:$p" }
      }
    }
  } catch {}

  try {
    foreach ($p in @(3081, 3080)) {
      $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($c) {
        return @{ Port = [int]$c.LocalPort; Source = "netstat:$p (pid $($c.OwningProcess))" }
      }
    }
  } catch {}

  return @{ Port = 3081; Source = "fallback:3081" }
}

function Get-DshPort {
  param([int]$ConfiguredPort = 0)
  $info = Get-DshPortInfo -ConfiguredPort $ConfiguredPort
  return [int]$info.Port
}

function Get-DshPortSource {
  param([int]$ConfiguredPort = 0)
  $info = Get-DshPortInfo -ConfiguredPort $ConfiguredPort
  return [string]$info.Source
}

function Test-IsAdmin {
  try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

function Test-SudoAvailable {
  try { return $null -ne (Get-Command sudo -ErrorAction SilentlyContinue) } catch { return $false }
}

function Resolve-DshNativeCommand {
  param([Parameter(Mandatory = $true)][string]$Name)
  $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  return $Name
}

function Convert-DshProcessArguments {
  param([string[]]$ArgumentList = @())
  $escaped = foreach ($arg in $ArgumentList) {
    $str = [string]$arg
    if ($str -match '[\s"]') {
      '"{0}"' -f ($str -replace '(\\+)"', '$1$1\"' -replace '(\\+)$', '$1$1' -replace '"', '\"')
    } else {
      $str
    }
  }
  return ($escaped -join ' ')
}

function Invoke-DshHiddenProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @()
  )
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  try { $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
  try { $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false) } catch {}
  $startInfo.Arguments = Convert-DshProcessArguments -ArgumentList $ArgumentList

  $process = [Diagnostics.Process]::new()
  try {
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return @{
      Output = [string]($stdout + $stderr)
      ExitCode = [int]$process.ExitCode
    }
  } finally {
    $process.Dispose()
  }
}

function Start-DshHiddenProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @()
  )
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $startInfo.Arguments = Convert-DshProcessArguments -ArgumentList $ArgumentList
  $process = [Diagnostics.Process]::Start($startInfo)
  if ($process) { $process.Dispose() }
}

function Get-DshRelayScriptPath {
  return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dsh-remote-relay.js'))
}

function Get-DshNodeExecutable {
  $cmd = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  # Scheduled tasks may have a narrower PATH than the interactive shell. Use
  # the executable path from the already-running DSH node as a fallback.
  try {
    $node = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like '*deepseek-harness*' } | Select-Object -First 1
    if ($node -and $node.CommandLine -match '"([^\"]+\\node(?:\.exe)?)"') { return $matches[1] }
    if ($node -and $node.ExecutablePath) { return $node.ExecutablePath }
  } catch {}
  return 'node.exe'
}

function Get-DshRelayProcess {
  param(
    [int]$ListenPort = 0,
    [int]$TargetPort = 0
  )
  $scriptPattern = [regex]::Escape((Get-DshRelayScriptPath))
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and $_.CommandLine -match $scriptPattern -and
        ($ListenPort -le 0 -or $_.CommandLine -match "--listen-port\s+$ListenPort(?:\s|$)") -and
        ($TargetPort -le 0 -or $_.CommandLine -match "--target-port\s+$TargetPort(?:\s|$)")
      })
  } catch { return @() }
}

function Start-DshRelay {
  param(
    [Parameter(Mandatory = $true)][int]$TargetPort,
    [int]$ListenPort = 3090
  )
  $scriptPath = Get-DshRelayScriptPath
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "DSH relay script not found: $scriptPath"
  }
  if ($ListenPort -eq $TargetPort) {
    throw "DSH relay port and DSH port must be different ($ListenPort)"
  }

  $same = @(Get-DshRelayProcess -ListenPort $ListenPort -TargetPort $TargetPort)
  if ($same.Count -gt 0 -and (Test-DshListening -Port $ListenPort)) { return $same[0] }

  # If DSH changed its dynamic port, retire the old relay before reusing the
  # configured relay port. Only processes launched from this exact script are
  # eligible for cleanup.
  $old = @(Get-DshRelayProcess -ListenPort $ListenPort)
  foreach ($p in $old) {
    try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
  }
  if ($old.Count -gt 0) { Start-Sleep -Milliseconds 250 }

  if (Test-DshListening -Port $ListenPort) {
    throw "Relay port $ListenPort is already occupied by another process"
  }

  $node = Get-DshNodeExecutable
  Start-DshHiddenProcess -FilePath $node -ArgumentList @(
    $scriptPath,
    '--listen-host', '127.0.0.1',
    '--listen-port', "$ListenPort",
    '--target-host', '127.0.0.1',
    '--target-port', "$TargetPort"
  )

  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $deadline) {
    if (Test-DshListening -Port $ListenPort) {
      $started = @(Get-DshRelayProcess -ListenPort $ListenPort -TargetPort $TargetPort)
      if ($started.Count -gt 0) { return $started[0] }
    }
    Start-Sleep -Milliseconds 200
  }
  throw "DSH relay did not start listening on 127.0.0.1:$ListenPort"
}

function Stop-DshRelay {
  param([int]$ListenPort = 0)
  $procs = @(Get-DshRelayProcess -ListenPort $ListenPort)
  foreach ($p in $procs) {
    try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
  }
  if ($procs.Count -gt 0) { Start-Sleep -Milliseconds 250 }
  return $procs.Count
}

function Invoke-DshElevatedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string]$CommandName,
    [string[]]$ArgumentList = @()
  )
  try {
    $direct = Invoke-DshHiddenProcess -FilePath $FilePath -ArgumentList $ArgumentList
  } catch {
    return @{ Output = [string]$_.Exception.Message; ExitCode = 1 }
  }
  if ($direct.Output -match "Access is denied" -and (Test-SudoAvailable)) {
    try {
      $sudo = Resolve-DshNativeCommand "sudo"
      return Invoke-DshHiddenProcess -FilePath $sudo -ArgumentList (@("--inline", $CommandName) + $ArgumentList)
    } catch {
      return @{ Output = [string]$_.Exception.Message; ExitCode = 1 }
    }
  }
  return $direct
}

function Invoke-DshSchtasks {
  param([string[]]$SchArgs)
  $schtasks = Resolve-DshNativeCommand "schtasks"
  return Invoke-DshElevatedProcess -FilePath $schtasks -CommandName "schtasks" -ArgumentList $SchArgs
}

function Get-DshWatcherTaskInfo {
  # 优先 ScheduledTasks cmdlet：不依赖 schtasks 的 OEM 代码页，避免中文系统乱码。
  $taskName = 'DSH-Remote-Watcher'
  $info = @{
    Exists = $false
    Status = $null
    LastRun = $null
    TaskToRun = $null
    Raw = ''
  }

  try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $info.Exists = $true
    $info.Status = [string]$task.State
    try {
      $taskInfo = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
      if ($taskInfo.LastRunTime -and $taskInfo.LastRunTime -gt [datetime]'2000-01-01') {
        $info.LastRun = $taskInfo.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss')
      }
    } catch {}
    $action = @($task.Actions) | Select-Object -First 1
    if ($action) {
      $info.TaskToRun = (([string]$action.Execute + ' ' + [string]$action.Arguments).Trim())
    }
    return $info
  } catch {}

  try {
    $raw = (Invoke-DshSchtasks -SchArgs @('/Query', '/TN', $taskName, '/FO', 'LIST', '/V')).Output
    $info.Raw = [string]$raw
    if ($raw -and $raw -match [regex]::Escape($taskName) -and $raw -notmatch 'ERROR:') {
      $info.Exists = $true
      $info.Status = 'exists'
      # schtasks 在中文系统上字段名常被 UTF-8 误读；日期和 powershell 命令行仍是 ASCII。
      if ($raw -match '(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})') {
        $info.LastRun = $matches[1]
      }
      if ($raw -match 'powershell\.exe[^\r\n]+Watch-DshRemote\.ps1') {
        $info.TaskToRun = $matches[0].Trim()
      }
    }
  } catch {}
  return $info
}

function Invoke-TailscaleCommand {
  param([string]$Arguments)
  $tailscale = Resolve-DshNativeCommand "tailscale"
  $tokens = @()
  if ($Arguments) {
    $tokens = [regex]::Split($Arguments.Trim(), "\s+") | Where-Object { $_ }
  }
  return Invoke-DshElevatedProcess -FilePath $tailscale -CommandName "tailscale" -ArgumentList $tokens
}

function Get-TailscaleServeStatus {
  try {
    $r = Invoke-TailscaleCommand -Arguments "serve status"
    $out = $r.Output; $code = $r.ExitCode
    if ($out -match "Access is denied") { return "__ACCESS_DENIED__" }
    if ($code -ne 0 -and -not $out) { return "" }
    return $out
  } catch { return "" }
}

function Test-TailscaleServeOn {
  param(
    [int]$Port,
    [int]$HttpsPort = 443,
    [AllowNull()]
    [object]$ServeStatus = $null
  )
  # $HttpsPort 留给调用方记录/日志；当前 status 文本用 :$Port + proxy 判定。
  $unusedHttpsPort = $HttpsPort
  [void]$unusedHttpsPort
  $status = if ($PSBoundParameters.ContainsKey('ServeStatus')) { [string]$ServeStatus } else { Get-TailscaleServeStatus }
  if (-not $status -or $status -eq "__ACCESS_DENIED__") { return $false }
  return ($status -match [regex]::Escape(":$Port") -and $status -match "proxy")
}

function Get-TailscaleHostname {
  try {
    $r = Invoke-TailscaleCommand -Arguments "status --json"
    $raw = $r.Output; $code = $r.ExitCode
    if ($raw -match "Access is denied") { return "__ACCESS_DENIED__" }
    if (-not $raw -or $code -ne 0) { return $null }
    $j = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($j.Self -and $j.Self.DNSName) { return $j.Self.DNSName.TrimEnd(".") }
  } catch {}
  return $null
}

function Invoke-TailscaleServe {
  param([string]$ServeArgs)
  # Wrapper that auto-elevates via sudo if needed
  $r = Invoke-TailscaleCommand -Arguments "serve $ServeArgs"
  return $r
}

function Test-DshListening {
  param([int]$Port)
  # Try Get-NetTCPConnection first (fast)
  try {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    $ErrorActionPreference = $prev
    if ($null -ne $c) { return $true }
  } catch {}
  # Fallback: netstat (works without admin, slower but reliable)
  try {
    $out = netstat -ano 2>$null | Out-String
    if ($out -match "127\.0\.0\.1:$Port\s+.*LISTENING") { return $true }
    if ($out -match "0\.0\.0\.0:$Port\s+.*LISTENING") { return $true }
    if ($out -match "\]:$Port\s+.*LISTENING") { return $true }
  } catch {}
  return $false
}

function Invoke-DshRemoteNotify {
  param(
    [ValidateSet("success", "info", "error")]
    [string]$Type = "info",
    [string]$Icon = "",
    [string]$Text = ""
  )
  try {
    $cfg2 = Get-DshRemoteConfig
    if ($cfg2.general.show_notification -eq $false) { return }
    $notifyLib = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "raycast-scripts\_lib\notify.ps1"
    if (Test-Path -LiteralPath $notifyLib -PathType Leaf) {
      . $notifyLib
      # 旧调用把 "0" / "*" / "o" 当占位图标，拼进标题会变成「0 提示」。
      $resolvedIcon = switch -Regex ($Icon) {
        '^[✓×○!]$' { $Icon }
        default {
          switch ($Type) {
            "success" { "✓" }
            "error" { "×" }
            default { "○" }
          }
        }
      }
      Show-SystemToast -Title "$resolvedIcon DSH Remote" -Message $Text | Out-Null
    }
  } catch {}
}

function Write-DshStep([string]$Message) { Write-Host "==> $Message" }
function Write-DshOK([string]$Message) { Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-DshWarn([string]$Message) { Write-Host "    [!!] $Message" -ForegroundColor Yellow }
function Write-DshFail([string]$Message) { Write-Host "    [!!] $Message" -ForegroundColor Red }
