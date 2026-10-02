#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Restart AutoHotkey
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Restart the toolbox AutoHotkey main script and the resident IME HUD
# @raycast.icon 🔄

$ErrorActionPreference = 'Stop'
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
$escapedMainScript = [Regex]::Escape($resolvedMainScript)
$toolboxPathPattern = 'lat3ncy-scripts-toolbox[\\/]ahk[\\/]main\.ahk'

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
  @(Get-CimInstance Win32_Process |
      Where-Object {
        $_.Name -like 'AutoHotkey*.exe' -and
        $_.CommandLine -and
        ($_.CommandLine -match $escapedMainScript -or $_.CommandLine -match $toolboxPathPattern)
      })
}

# 常驻 ImeHudWinUi.exe 也要一起结束，否则：
#   1. 它里面跑的是旧 exe 的代码，新的 STATE/MOVE 协议永远进不去；
#   2. 旧进程占着 HWND 和 mutex，新的 exe 只能干等。
# main.ahk 启动时会 Warm() 预热，会自己冷启动新的 HUD，所以这里只管停。
function Stop-ToolboxImeHud
{
  $hudProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ieq 'ImeHudWinUi.exe' })
  foreach ($hud in $hudProcesses)
  {
    try
    {
      Stop-Process -Id $hud.ProcessId -Force -ErrorAction Stop
    }
    catch
    {
      # 权限不足时不要静默：旧 HUD 还在跑，新协议不会生效。
      # 但也不能往 stdout 写：Raycast 会把任何脚本输出当成结果弹自己的通知。
      # 结论由下面的检查统一抛错，再走系统 Toast。
    }
  }
  if ($hudProcesses.Count -gt 0)
  {
    Start-Sleep -Milliseconds 300
  }
  $left = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ieq 'ImeHudWinUi.exe' })
  if ($left.Count -gt 0)
  {
    throw ("ImeHudWinUi.exe 仍在运行（{0}），新协议不会生效。请用管理员权限重跑本脚本。" -f (($left.ProcessId) -join ', '))
  }
}

Stop-ToolboxImeHud

$toolboxProcesses = Get-ToolboxAutoHotkeyProcess

foreach ($process in $toolboxProcesses)
{
  Stop-Process -Id $process.ProcessId -Force
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

$createResult = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
  CommandLine = $commandLine
  CurrentDirectory = $workingDirectory
}

if ($createResult.ReturnValue -ne 0)
{
  throw ("Failed to launch AutoHotkey process. Return code: {0}" -f $createResult.ReturnValue)
}

Start-Sleep -Milliseconds 600
$reloadedProcesses = Get-ToolboxAutoHotkeyProcess

if (-not $reloadedProcesses)
{
  throw 'AutoHotkey main.ahk process was not detected after launch'
}

$processIds = ($reloadedProcesses.ProcessId | Sort-Object -Unique) -join ', '
# silent 会关 Raycast 窗口。成功也走系统 Toast，不再弹共享 HUD / stdout。
Show-SystemToast -Title '✓ AutoHotkey + IME HUD 已重载' -Message ("AHK PID: {0}" -f $processIds) | Out-Null
