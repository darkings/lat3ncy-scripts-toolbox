#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Restart AutoHotkey
# @raycast.mode compact
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Restart the toolbox AutoHotkey main script
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

  # Scoop 常见路径兜底
  $scoopRoots = @($env:USERPROFILE, $env:SCOOP)
  foreach ($root in $scoopRoots | Where-Object { $_ })
  {
    foreach ($candidate in @(
        (Join-Path $root 'scoop\apps\autohotkey\current\AutoHotkey64.exe'),
        (Join-Path $root 'scoop\apps\autohotkey\current\AutoHotkey32.exe')
      ))
    {
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
  Write-Output '× 未找到 AutoHotkey'
  exit 1
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
Write-Output "✓ AutoHotkey 已重载 (PID: $processIds)"
