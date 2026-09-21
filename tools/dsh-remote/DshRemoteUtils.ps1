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
  #
  # 注意：Get-CimInstance Win32_Process 在受限环境下可能返回空集（无 WMI 权限 /
  # 服务被裁剪），此时它既不报错也不返回进程——比抛异常更隐蔽。因此这里对它做
  # 可用性判定，不可用时退回 Get-Process，避免「探测一直失败但看起来正常」。
  $gui = @()
  $node = @()
  $cimAvailable = $false
  try {
    $foundGui = Get-Process -Name "deepseek-harness-desktop" -ErrorAction SilentlyContinue
    if ($foundGui) { $gui = @($foundGui) }
  } catch {}
  try {
    $foundNode = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
    if ($foundNode) { $node = @($foundNode); $cimAvailable = $true }
  } catch {}
  if (-not $cimAvailable) {
    # 回退：Get-Process 拿不到 CommandLine，无法按 deepseek-harness 过滤。
    # 不能把所有 node 都当成 DSH —— 机器上常有其它 node 服务在监听自己的端口，
    # 全收进来会让「按 PID 找监听端口」选中无关进程（实测选中过一个跑在 7265
    # 的无关 node）。这里改为只认「监听 3080/3081 的 node」——那是 DSH 的
    # 配置默认端口与占用时的回退端口。
    try {
      $out = netstat -ano 2>$null | Out-String
      $candidatePids = @()
      foreach ($p in @(3080, 3081)) {
        foreach ($m in [regex]::Matches($out, "127\.0\.0\.1:$p\s+\S+\s+LISTENING\s+(\d+)")) {
          $candidatePids += [int]$m.Groups[1].Value
        }
      }
      $candidatePids = @($candidatePids | Select-Object -Unique)
      if ($candidatePids.Count -gt 0) {
        $foundNode = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $candidatePids -contains $_.Id })
        if ($foundNode) { $node = @($foundNode) }
      }
    } catch {}
  }
  $guiPids = @($gui | ForEach-Object { $_.Id })
  $nodePids = @($node | ForEach-Object { if ($_.ProcessId) { $_.ProcessId } else { $_.Id } })
  $portNodePids = @()
  if ($cimAvailable) {
    $portNodePids = @($node | Where-Object { $_.CommandLine -like "*--port*" } | ForEach-Object { $_.ProcessId })
  }
  return @{
    Gui = $gui
    Node = $node
    GuiPids = $guiPids
    NodePids = $nodePids
    PortNodePids = $portNodePids
    CimAvailable = $cimAvailable
    Running = (($guiPids.Count + $nodePids.Count) -gt 0)
  }
}

function Get-DshProfilePaths {
  # web profile 与 dependencies 树的位置。二者都可能随版本迁移，集中一处便于调整。
  $dataHome = Join-Path $env:APPDATA "io.github.hairyf.deepseek-harness-desktop"
  return @{
    DataHome = $dataHome
    Profile = Join-Path $dataHome "data\dsh\profiles\web"
    Deps = Join-Path $dataHome "dependencies\dsh\node_modules"
  }
}

function Split-DshPackageName {
  param([Parameter(Mandatory = $true)][string]$Name)
  # "@scope/pkg" -> @{ Scope='@scope'; Name='pkg'; Rel='@scope\pkg' }
  # "pkg"        -> @{ Scope='';      Name='pkg'; Rel='pkg' }
  $scope = ''
  $bare = $Name
  if ($Name.StartsWith('@')) {
    $idx = $Name.IndexOf('/')
    if ($idx -gt 0) {
      $scope = $Name.Substring(0, $idx)
      $bare = $Name.Substring($idx + 1)
    }
  }
  $rel = if ($scope) { Join-Path $scope $bare } else { $bare }
  return @{ Scope = $scope; Name = $bare; Rel = $rel }
}

function Test-DshProfileBundle {
  param(
    [Parameter(Mandatory = $true)][string]$BundleName,
    $Paths = $null
  )
  # 一个 bundle 算「已就位」= profile 的 node_modules 里能解析到它的 package.json。
  # 注意不能只看 Junction：pnpm 的 hoisted 布局下也可能是真实目录。
  if ($null -eq $Paths) { $Paths = Get-DshProfilePaths }
  $split = Split-DshPackageName -Name $BundleName
  # 逐段 Join-Path：-AdditionalChildPath 在 Windows PowerShell 5.1 上不存在，
  # 三步式拼法在 5.1 与 7+ 上都可用。
  $inProfile = Join-Path (Join-Path $Paths.Profile "node_modules") $split.Rel
  $inDeps = Join-Path $Paths.Deps $split.Rel
  # 用 [pscustomobject] 而非哈希表：哈希表被管道展开时会退化成一串键值对
  # （Format-Table 打出一堆重复的 Name/Present 行），对象不会。
  return [pscustomobject]@{
    Name = $BundleName
    Present = (Test-Path -LiteralPath (Join-Path $inProfile "package.json") -PathType Leaf)
    ProfilePath = $inProfile
    DepsPath = $inDeps
    SourceAvailable = (Test-Path -LiteralPath (Join-Path $inDeps "package.json") -PathType Leaf)
  }
}

function Get-DshProfileBundles {
  param($Paths = $null)
  # 以 profile package.json 的 dsh.profile.bundles 为准——不硬编码包名，
  # 这样 DSH 升级增删核心 bundle 时本自检自动跟随。
  if ($null -eq $Paths) { $Paths = Get-DshProfilePaths }
  $pkgFile = Join-Path $Paths.Profile "package.json"
  if (-not (Test-Path -LiteralPath $pkgFile -PathType Leaf)) { return @() }
  try {
    $j = Get-Content -LiteralPath $pkgFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $bundles = @($j.dsh.profile.bundles) | Where-Object { $_ }
    # 逐个收集到数组，最后一次性输出，避免 ForEach-Object 的流式展开。
    $out = @(foreach ($b in $bundles) { Test-DshProfileBundle -BundleName ([string]$b) -Paths $Paths })
    return $out
  } catch {
    return @()
  }
}

function Test-DshCoreBundles {
  param($Paths = $null)
  # 核心 bundle 缺失是「DSH 在跑但 /api 返回 404」的根因：
  # @deepseek-ai/dsh-web-app 负责挂载 /api 路由，它没加载 → 路由根本没注册。
  # 桌面端日志里的信号是 CORE_PLUGIN_PROFILE_ENTRY_MISSING。
  if ($null -eq $Paths) { $Paths = Get-DshProfilePaths }
  $all = @(Get-DshProfileBundles -Paths $Paths)
  if ($all.Count -eq 0) {
    return @{ Ok = $false; Unknown = $true; Missing = @(); Restorable = @(); Unrestorable = @(); All = @() }
  }
  $missing = @($all | Where-Object { -not $_.Present })
  # 只有「依赖树里存在」的缺失项才可能用 junction 修复；否则必须先装包。
  $restorable = @($missing | Where-Object { $_.SourceAvailable })
  $unrestorable = @($missing | Where-Object { -not $_.SourceAvailable })
  return @{
    Ok = ($missing.Count -eq 0)
    Unknown = $false
    Missing = $missing
    Restorable = $restorable
    Unrestorable = $unrestorable
    All = $all
  }
}

function Repair-DshCoreBundles {
  param(
    [switch]$WhatIf,
    $Paths = $null
  )
  # 为缺失、但依赖树里存在的 bundle 补建 junction。
  # 只做链接，不下载、不改 package.json——把「装包」留给 DSH 自己。
  if ($null -eq $Paths) { $Paths = Get-DshProfilePaths }
  $state = Test-DshCoreBundles -Paths $Paths
  $created = @()
  $failed = @()
  if ($state.Unknown) { return @{ Created = @(); Failed = @(); State = $state } }
  $scopeDir = Join-Path $Paths.Profile "node_modules\@deepseek-ai"
  foreach ($item in $state.Restorable) {
    $split = Split-DshPackageName -Name $item.Name
    $linkPath = $item.ProfilePath
    if ($split.Scope -and -not (Test-Path -LiteralPath $scopeDir)) {
      if (-not $WhatIf) { New-Item -ItemType Directory -Force -Path $scopeDir | Out-Null }
    }
    if ($WhatIf) { $created += $item.Name; continue }
    try {
      New-Item -ItemType Junction -Path $linkPath -Target $item.DepsPath -Force -ErrorAction Stop | Out-Null
      $created += $item.Name
    } catch {
      # 常见原因：权限不足（profile 在 %APPDATA% 下，普通用户可写；但受限沙箱/
      # 只读环境会拒绝），或目标已存在且类型冲突。把原因带上，别只说「失败」。
      $failed += @{ Name = $item.Name; Error = $_.Exception.Message }
    }
  }
  return @{ Created = $created; Failed = $failed; State = $state }
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
  # 端口优先级：config -> .store.dat -> 进程监听 -> netstat -> 3080/3081 探测 -> 报错。
  # 兜底探测顺序是 3080 优先：3080 是 DSH 的配置默认端口，3081 只是 3080 被占用时的
  # 临时回退端口（桌面端日志: "port changed from 3080 to 3081 because ... occupied"）。
  # 探测全失败时不再静默返回一个猜测端口——那会让 relay 去连一个没人监听的端口，
  # 把一个「探测失败」伪装成 ECONNREFUSED 网络故障。
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
    # 注意：变量名不能用 $pId —— PowerShell 变量大小写不敏感，$pId 与只读的
    # 自动变量 $PID 冲突，赋值即抛错；而外层 try/catch 会把它吞掉，导致
    # 整条 netstat 兜底分支静默失效（表现为端口「解析不出来」）。
    foreach ($procId in $allPids) {
      if ($out -match "127\.0\.0\.1:(\d+)\s+.*LISTENING\s+$procId") {
        $found = [int]$matches[1]
        return @{ Port = $found; Source = "netstat:$found (pid $procId)" }
      }
      if ($out -match "0\.0\.0\.0:(\d+)\s+.*LISTENING\s+$procId") {
        $found = [int]$matches[1]
        return @{ Port = $found; Source = "netstat:$found (pid $procId)" }
      }
    }
    foreach ($p in @(3080, 3081)) {
      if ($out -match ":$p\s+.*LISTENING") {
        return @{ Port = $p; Source = "netstat:$p" }
      }
    }
  } catch {}

  try {
    foreach ($p in @(3080, 3081)) {
      $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($c) {
        return @{ Port = [int]$c.LocalPort; Source = "netstat:$p (pid $($c.OwningProcess))" }
      }
    }
  } catch {}

  # 探测全部失败：明确报错，不再猜端口。
  # 返回一个未监听的端口会让 Start/Status/Watcher 三方一致地把
  # "DSH 没在跑 / 端口探测失败" 误报成 relay 上游 ECONNREFUSED。
  return @{ Port = 0; Source = "unresolved"; Error = 'port not resolved' }
}

function Get-DshPortInfoResolved {
  param(
    [int]$ConfiguredPort = 0,
    $Snapshot = $null
  )
  # Get-DshPortInfo 的严格版本：端口解析不出来就抛异常。
  # 供 Start / Status 这类「必须拿到真实端口」的调用方使用；
  # Watcher 那种「探不到就当作 DSH 没在跑」的场景仍用 Get-DshPortInfo 自行判断 Port -le 0。
  $info = Get-DshPortInfo -ConfiguredPort $ConfiguredPort -Snapshot $Snapshot
  if ([int]$info.Port -le 0) {
    throw "Could not resolve the local DSH port (tried .store.dat, process listeners, netstat, 3080, 3081). Start DSH Desktop first."
  }
  return $info
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
  try {
    if (Get-Command sudo -ErrorAction SilentlyContinue) { return $true }
    return $null -ne (Get-Command gsudo -ErrorAction SilentlyContinue)
  } catch { return $false }
}

function Resolve-DshElevator {
  # 优先 Windows 内置 sudo.exe；否则退回 gsudo（Scoop 安装，本机可用）。
  # 两者参数形态不同：sudo.exe 用 `sudo --inline <cmd> <args...>`；
  # gsudo 用 `gsudo <cmd> <args...>`（默认即为一次性提权执行）。
  $sudo = Get-Command sudo -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($sudo -and $sudo.Source) {
    return @{ Path = $sudo.Source; Prefix = @('--inline'); Name = 'sudo' }
  }
  $gsudo = Get-Command gsudo -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($gsudo -and $gsudo.Source) {
    return @{ Path = $gsudo.Source; Prefix = @(); Name = 'gsudo' }
  }
  return $null
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
    $byCim = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and $_.CommandLine -match $scriptPattern -and
        ($ListenPort -le 0 -or $_.CommandLine -match "--listen-port\s+$ListenPort(?:\s|$)") -and
        ($TargetPort -le 0 -or $_.CommandLine -match "--target-port\s+$TargetPort(?:\s|$)")
      })
    if ($byCim.Count -gt 0) { return $byCim }
  } catch {}

  # CIM 不可用（Win32_Process 返回空集）时的回退：不按命令行匹配，改为
  # 「谁在监听 $ListenPort」反查 PID。虽拿不到 target-port，但对
  # Start-DshRelay 的存活判定和 Stop-DshRelay 的清理已经够用。
  if ($ListenPort -gt 0) {
    try {
      $conn = Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($conn) {
        return @([pscustomobject]@{ ProcessId = [int]$conn.OwningProcess; CommandLine = $null })
      }
    } catch {}
    try {
      $out = netstat -ano 2>$null | Out-String
      $m = [regex]::Match($out, "127\.0\.0\.1:$ListenPort\s+\S+\s+LISTENING\s+(\d+)")
      if (-not $m.Success) { $m = [regex]::Match($out, "0\.0\.0\.0:$ListenPort\s+\S+\s+LISTENING\s+(\d+)") }
      if ($m.Success) {
        return @([pscustomobject]@{ ProcessId = [int]$m.Groups[1].Value; CommandLine = $null })
      }
    } catch {}
  }
  return @()
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
      # 只要端口在 Listen 就算成功。此前额外要求「能按命令行找到该进程」，
      # 在 CIM 不可用的环境下必然失败——relay 明明已就绪却被判为启动失败。
      $started = @(Get-DshRelayProcess -ListenPort $ListenPort -TargetPort $TargetPort)
      if ($started.Count -gt 0) { return $started[0] }
      return [pscustomobject]@{ ProcessId = $null; CommandLine = $null }
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
  if ($direct.Output -match "Access is denied") {
    $elevator = Resolve-DshElevator
    if ($elevator) {
      try {
        return Invoke-DshHiddenProcess -FilePath $elevator.Path `
          -ArgumentList (@($elevator.Prefix) + @($CommandName) + $ArgumentList)
      } catch {
        return @{ Output = [string]$_.Exception.Message; ExitCode = 1 }
      }
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
