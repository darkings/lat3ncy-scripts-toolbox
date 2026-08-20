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
  # 优先标准 v2 安装位置（官方安装程序默认安装到 LOCALAPPDATA）
  $standardV2 = Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2'
  foreach ($engineName in @('AutoHotkey64.exe', 'AutoHotkey32.exe'))
  {
    $candidate = Join-Path $standardV2 $engineName
    if (Test-Path -LiteralPath $candidate -PathType Leaf)
    {
      return $candidate
    }
  }
  return (Get-Command AutoHotkey.exe -ErrorAction Stop).Source
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
$shown = Show-ToolboxNotify -Type 'success' -Icon '✓' -Text 'AutoHotkey 已重载'
if (-not $shown)
{
  Write-Output "✓ AutoHotkey 已重载 (PID: $processIds)"
}
