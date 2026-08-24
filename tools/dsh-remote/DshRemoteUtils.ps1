$ErrorActionPreference = 'Stop'

function Get-DshRemoteConfig {
  $configFile = Join-Path $PSScriptRoot "config.toml"
  $config = @{
    server = @{ port = 0; https_port = 443 }
    relay = @{ enabled = $true; port = 3090 }
    watcher = @{ poll_interval = 5; auto_off = $true; probe_timeout = 12 }
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

function Get-DshPort {
  param([int]$ConfiguredPort = 0)
  # 1) 配置固定端口优先（显式指定才用，不写死默认）
  if ($ConfiguredPort -gt 0) { return $ConfiguredPort }
  # 2) 读 DSH 真实配置 .store.dat
  $store = Join-Path $env:APPDATA "io.github.hairyf.deepseek-harness-desktop\.store.dat"
  if (Test-Path -LiteralPath $store) {
    try {
      $j = Get-Content -LiteralPath $store -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $p = $j.setting.port
      # 兼容 Int64 / Int32 / string（JSON 数字可能是 Long）
      if ($null -ne $p -and "$p" -match "^\d+$") {
        $pi = [int]"$p"
        if ($pi -gt 0 -and $pi -lt 65535) { return $pi }
      }
    } catch {}
  }
  # 3) 动态探测：查找 deepseek-harness-desktop 或其 node 后端实际监听的端口（完全不写死）
  try {
    $probePids = @()
    $dshProcs = Get-Process -Name "deepseek-harness-desktop" -ErrorAction SilentlyContinue
    if ($dshProcs) { $probePids += $dshProcs.Id }
    # 同时探测 DSH 的 node 后端 (deepseek-harness 下的 node.exe --host 127.0.0.1 --port XXXX)
    try {
      $nodeProcs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*deepseek-harness*" -and $_.CommandLine -like "*--port*" }
      if ($nodeProcs) { $probePids += $nodeProcs.ProcessId }
    } catch {}
    if ($probePids.Count -gt 0) {
      $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $probePids -contains $_.OwningProcess }
      # 优先 127.0.0.1，其次 0.0.0.0，最后任意
      $local = $conns | Where-Object { $_.LocalAddress -eq "127.0.0.1" } | Sort-Object LocalPort | Select-Object -First 1
      if ($local) { return [int]$local.LocalPort }
      $any = $conns | Sort-Object LocalPort | Select-Object -First 1
      if ($any) { return [int]$any.LocalPort }
    }
  } catch {}
  # 4) netstat 兜底（无 Get-NetTCPConnection 权限时）
  try {
    $out = netstat -ano 2>$null | Out-String
    # 找 DSH / node pid 对应的 LISTENING 行
    $probePids = @()
    $dshPids = (Get-Process -Name "deepseek-harness-desktop" -ErrorAction SilentlyContinue).Id
    if ($dshPids) { $probePids += @($dshPids) }
    try {
      $nodePids = (Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*deepseek-harness*" }).ProcessId
      if ($nodePids) { $probePids += @($nodePids) }
    } catch {}
    foreach ($pId in $probePids) {
      if ($out -match "127\.0\.0\.1:(\d+)\s+.*LISTENING\s+$pId") { return [int]$matches[1] }
      if ($out -match "0\.0\.0\.0:(\d+)\s+.*LISTENING\s+$pId") { return [int]$matches[1] }
    }
    # 最后再试常见端口兜底（仅当上面都失败）- 直接探测 3081/3080 是否被监听
    foreach ($p in @(3081, 3080)) {
      if ($out -match ":$p\s+.*LISTENING") { return $p }
    }
  } catch {}
  # 5) Get-NetTCPConnection 全局兜底：直接查 3081/3080 谁在监听（不限制归属进程）
  try {
    foreach ($p in @(3081, 3080)) {
      $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($c) { return [int]$c.LocalPort }
    }
  } catch {}
  # 6) 实在拿不到才回退默认值（避免空值导致 serve 失败）
  return 3081
}

function Get-DshPortSource {
  param([int]$ConfiguredPort = 0)
  if ($ConfiguredPort -gt 0) { return "config.toml:$ConfiguredPort" }
  $store = Join-Path $env:APPDATA "io.github.hairyf.deepseek-harness-desktop\.store.dat"
  if (Test-Path -LiteralPath $store) {
    try {
      $j = Get-Content -LiteralPath $store -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $p = $j.setting.port
      if ($null -ne $p -and "$p" -match "^\d+$" -and [int]"$p" -gt 0) { return ".store.dat:$p" }
    } catch {}
  }
  try {
    $probePids = @()
    $dshProcs = Get-Process -Name "deepseek-harness-desktop" -ErrorAction SilentlyContinue
    if ($dshProcs) { $probePids += $dshProcs.Id }
    try {
      $nodeProcs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*deepseek-harness*" }
      if ($nodeProcs) { $probePids += $nodeProcs.ProcessId }
    } catch {}
    if ($probePids.Count -gt 0) {
      $c = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $probePids -contains $_.OwningProcess } | Where-Object { $_.LocalAddress -eq "127.0.0.1" } | Select-Object -First 1
      if ($c) { return "process:$($c.LocalPort) (pid $($c.OwningProcess))" }
      $any = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $probePids -contains $_.OwningProcess } | Select-Object -First 1
      if ($any) { return "process:$($any.LocalPort) (pid $($any.OwningProcess))" }
    }
    # 全局兜底：看 3081 是否有人监听
    $fallback = Get-NetTCPConnection -LocalPort 3081 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fallback) { return "netstat:3081 (pid $($fallback.OwningProcess))" }
  } catch {}
  return "fallback:3081"
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
  param([int]$Port, [int]$HttpsPort = 443)
  $status = Get-TailscaleServeStatus
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
