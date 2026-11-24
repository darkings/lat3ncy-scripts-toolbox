#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Restart AutoHotkey
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Restart the toolbox AutoHotkey main script and the resident IME HUD
# @raycast.icon 🔄

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\settings.ps1')
if(-not(Test-ToolboxRaycastCommandEnabled -Command 'restart-autohotkey')){exit 0}
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$mainScript = Join-Path $repositoryRoot 'ahk\main.ahk'

if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf))
{
  throw "AutoHotkey entry script not found: $mainScript"
}

$resolvedMainScript = (Resolve-Path -LiteralPath $mainScript).Path
$toolboxStartupRoot = Join-Path $repositoryRoot 'tools\startup'
. (Join-Path $toolboxStartupRoot 'ToolboxProcess.ps1')

function Resolve-AutoHotkeyV2Executable
{
  # 优先标准 v2 安装位置（官方安装程序默认安装到 LOCALAPPDATA），兼容 Raycast 隔离环境
  $localAppData = $env:LOCALAPPDATA
  if (-not $localAppData) {
    try { $localAppData = [Environment]::GetFolderPath('LocalApplicationData') } catch {}
  }
  if ($localAppData)
  {
    $standardV2 = Join-Path $localAppData 'Programs\AutoHotkey\v2'
    foreach ($engineName in @('AutoHotkey64.exe', 'AutoHotkey32.exe'))
    {
      $candidate = Join-Path $standardV2 $engineName
      if (Test-Path -LiteralPath $candidate -PathType Leaf)
      {
        return $candidate
      }
    }
  }

  $command = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue
  if ($command)
  {
    $executable = $command.Source
    $shimFile = [IO.Path]::ChangeExtension($executable, '.shim')
    if (Test-Path -LiteralPath $shimFile)
    {
      try {
        $shimText = Get-Content -Raw -LiteralPath $shimFile
        if ($shimText -match '(?m)^path\s*=\s*"([^"]+)"')
        {
          $shimTarget = $Matches[1]
          if ([IO.Path]::GetFileName($shimTarget) -ieq 'AutoHotkeyUX.exe')
          {
            $installRoot = Split-Path (Split-Path $shimTarget -Parent) -Parent
            $engineName = if ([Environment]::Is64BitOperatingSystem) { 'AutoHotkey64.exe' } else { 'AutoHotkey32.exe' }
            $engine = Join-Path (Join-Path $installRoot 'v2') $engineName
            if (Test-Path -LiteralPath $engine) { return $engine }
          }
          if (Test-Path -LiteralPath $shimTarget) { return $shimTarget }
        }
      } catch {}
    }
    return $executable
  }

  $programFiles = $env:ProgramFiles
  if (-not $programFiles) {
    try { $programFiles = [Environment]::GetFolderPath('ProgramFiles') } catch {}
  }
  if ($programFiles)
  {
    foreach ($candidate in @(
        (Join-Path $programFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $programFiles 'AutoHotkey\v2\AutoHotkey32.exe'),
        (Join-Path $programFiles 'AutoHotkey\v2\AutoHotkey.exe')
      ))
    {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
  }

  # Scoop 兜底：$env:SCOOP 本身就是 Scoop 根目录，$env:USERPROFILE 才需要再拼 scoop；
  # 引擎在 v2\ 子目录下（current\AutoHotkey64.exe 一般不存在）。
  $scoopRoots = @()
  if ($env:SCOOP) { $scoopRoots += $env:SCOOP }
  if ($env:USERPROFILE) { $scoopRoots += (Join-Path $env:USERPROFILE 'scoop') }
  foreach ($scoopRoot in $scoopRoots)
  {
    foreach ($relative in @(
        'apps\autohotkey\current\v2\AutoHotkey64.exe',
        'apps\autohotkey\current\v2\AutoHotkey32.exe',
        'apps\autohotkey\current\AutoHotkey64.exe',
        'apps\autohotkey\current\AutoHotkey32.exe'
      ))
    {
      $candidate = Join-Path $scoopRoot $relative
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
  }

  return $null
}

function Get-ToolboxAutoHotkeyProcess
{
  try {
    $allAhk = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -like 'AutoHotkey*.exe' })
    $cimProcs = @($allAhk |
        Where-Object {
          $_.Name -like 'AutoHotkey*.exe' -and
          $_.CommandLine -and
          (Test-ToolboxMainScriptCommandLine -CommandLine $_.CommandLine -MainScript $resolvedMainScript)
        })
    if ($cimProcs.Count -gt 0) { return $cimProcs }
    if (@($allAhk | Where-Object { -not $_.CommandLine }).Count -eq 0) { return @() }
  } catch {}

  # CIM 不可用时的兜底：绝不按进程名杀进程。
  # 机器上属于其它项目的 AHK 脚本会被一起干掉 —— 这正是 tools/startup/ToolboxProcess.ps1
  # 开头写明的「Matching by process name alone is wrong」。
  # 这里只回答一个能被证据支撑的问题：现在到底有没有任何 AutoHotkey 在跑。
  $named = @(Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessName -like 'AutoHotkey*' })
  if ($named.Count -eq 0) { return @() }

  $markerState = 'unknown'
  try {
    . (Join-Path $toolboxStartupRoot 'ToolboxProcess.ps1')
    $markerState = Get-ToolboxInstanceMarkerState -MainScript $resolvedMainScript
  } catch {}

  throw ("无法读取 AutoHotkey 进程的命令行（CIM 查询被拒绝），无法确认哪个进程属于本仓库的 main.ahk。" +
         "为避免误杀其它 AutoHotkey 脚本，操作已中止：请用管理员权限重跑本脚本。" +
         "（实例标记={0}，AutoHotkey 进程数={1}）" -f $markerState, $named.Count)
}

# 常驻 ImeHudWinUi.exe 也要一起结束，否则：
#   1. 它里面跑的是旧 exe 的代码，新的 STATE/MOVE 协议永远进不去；
#   2. 旧进程占着 HWND 和 mutex，新的 exe 只能干等。
# main.ahk 启动时会 Warm() 预热，会自己冷启动新的 HUD，所以这里只管停。
function Stop-ToolboxImeHud
{
  Stop-ToolboxOwnedHudProcess -Repo $repositoryRoot
}

# Serialize the mutation window with Deploy-Toolbox and the composite rebuild.
$restartLease=[Threading.Mutex]::new($false,((Get-ToolboxInstanceName $mainScript)+'-Deployment'))
$restartOwned=$false
try {
  try{$restartOwned=$restartLease.WaitOne(0)}catch [Threading.AbandonedMutexException]{$restartOwned=$true}
  if(-not $restartOwned){throw 'Another deployment is running for this checkout'}
$toolboxProcesses = Get-ToolboxAutoHotkeyProcess
Stop-ToolboxImeHud

foreach ($process in $toolboxProcesses)
{
  $targetPid = if ($process.ProcessId) { $process.ProcessId } else { $process.Id }
  Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
}

if ($toolboxProcesses)
{
  Start-Sleep -Milliseconds 200
}

$autoHotkey = Resolve-AutoHotkeyV2Executable
if (-not $autoHotkey)
{
  # 走 trap：系统 Toast 报错，并让 Raycast silent 以非 0 退出。
  throw '未找到 AutoHotkey'
}
$workingDirectory = Split-Path $resolvedMainScript -Parent
$commandLine = '"{0}" "{1}"' -f $autoHotkey, $resolvedMainScript

$started = $false
try
{
  $createResult = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $commandLine
    CurrentDirectory = $workingDirectory
  } -ErrorAction Stop

  if ($createResult.ReturnValue -eq 0)
  {
    $started = $true
  }
}
catch
{
}

if (-not $started)
{
  Start-Process -FilePath $autoHotkey -ArgumentList @($resolvedMainScript) -WorkingDirectory $workingDirectory -ErrorAction Stop
}

Start-Sleep -Milliseconds 600
$reloadedProcesses = @()
try { $reloadedProcesses = @(Get-ToolboxAutoHotkeyProcess) } catch { $reloadedProcesses = @() }

if (-not $reloadedProcesses)
{
  # CIM 可能仍然不可用：实例标记是权威来源，且不依赖 WMI。
  $markerState = 'unknown'
  try {
    . (Join-Path $toolboxStartupRoot 'ToolboxProcess.ps1')
    $markerState = Get-ToolboxInstanceMarkerState -MainScript $resolvedMainScript
  } catch {}
  if ($markerState -ne 'present')
  {
    throw ('AutoHotkey main.ahk was not detected after launch (marker=' + $markerState + ')')
  }
}

$pids = foreach ($p in $reloadedProcesses) { if ($p.ProcessId) { $p.ProcessId } else { $p.Id } }
$processIds = ($pids | Sort-Object -Unique) -join ', '
if (-not $processIds) { $processIds = '已由实例标记确认（CIM 不可用）' }
# silent 会关 Raycast 窗口。成功也走系统 Toast，不再弹共享 HUD / stdout。
Show-SystemToast -Title '✓ AutoHotkey + IME HUD 已重载' -Message ("AHK PID: {0}" -f $processIds) | Out-Null

} finally {if($restartOwned){$restartLease.ReleaseMutex()};$restartLease.Dispose()}
