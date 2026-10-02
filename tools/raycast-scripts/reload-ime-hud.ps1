#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Reload IME HUD
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Rebuild anchor-locator + WinUI HUD, restart both, keep AHK in sync
# @raycast.icon 🧭

<#
重新部署 IME HUD 整条链路。改了 shared/notify/*.ahk、AnchorLocator.cs 或
tools/ime-hud-winui/*.cs 之后必须跑这个：

  1. 重新编译 shared/notify/anchor-locator.exe（Windows 自带 csc，C# 5）
  2. 重新发布 tools/ime-hud-winui/out/ImeHudWinUi.exe
  3. 结束常驻 ImeHudWinUi.exe —— 否则旧代码一直占着 HWND，新的 STATE/MOVE 都进不去
  4. 重载 ahk/main.ahk

任何一步失败都直接报错退出，不做部分部署。
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$locatorBuild = Join-Path $repositoryRoot 'shared\notify\build-anchor-locator.ps1'
$winUiProject = Join-Path $repositoryRoot 'tools\ime-hud-winui\ImeHudWinUi.csproj'
$winUiOut = Join-Path $repositoryRoot 'tools\ime-hud-winui\out'
$mainScript = Join-Path $repositoryRoot 'ahk\main.ahk'

function Invoke-Step
{
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )
  # No stdout: Raycast treats any output as a script result and shows its own HUD.
  & $Action
  if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0)
  {
    throw "$Name failed with exit code $LASTEXITCODE"
  }
}

# --- 1. anchor-locator.exe ---
Invoke-Step 'build anchor-locator.exe' {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $locatorBuild | Out-Null
}

# --- 2. 结束常驻 HUD ---
# 必须在 publish 之前：正在运行的 exe 会让 publish 的覆盖复制失败。
# 停止 + 重载 AHK 都由 restart-autohotkey.ps1 负责，这里不重复实现。
$hudProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq 'ImeHudWinUi.exe' })
foreach ($process in $hudProcesses)
{
  # No stdout: Raycast shows its own result HUD for any script output.
  Stop-Process -Id $process.ProcessId -Force
}
if ($hudProcesses.Count -gt 0)
{
  Start-Sleep -Milliseconds 400
}

$stillRunning = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq 'ImeHudWinUi.exe' })
if ($stillRunning.Count -gt 0)
{
  throw ("ImeHudWinUi.exe 仍在运行，无法重发布：{0}。请用管理员权限重跑。" -f (($stillRunning.ProcessId) -join ', '))
}

# --- 3. WinUI HUD ---
Invoke-Step 'publish ImeHudWinUi.exe' {
  dotnet publish $winUiProject -c Release -r win-x64 --self-contained false -p:Platform=x64 -o $winUiOut | Out-Null
}

# --- 4. 重载 AHK（restart-autohotkey.ps1 里同时负责结束 HUD 和启动 main.ahk）---
$restartAhk = Join-Path $PSScriptRoot 'restart-autohotkey.ps1'
Invoke-Step 'reload ahk/main.ahk' {
  pwsh -NoProfile -File $restartAhk | Out-Null
}

# main.ahk 启动时会 Warm() 预热 WinUI，给它一点时间建 HWND。
Start-Sleep -Milliseconds 1200
$warm = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'ImeHudWinUi.exe' })
$warmIds = if ($warm.Count -gt 0) { ($warm.ProcessId | Sort-Object -Unique) -join ', ' } else { '未预热（首次 CapsLock 时冷启动）' }

Show-SystemToast -Title '✓ IME HUD 已重载' -Message ("anchor-locator + WinUI 已重建，AHK 已重载；HUD PID: {0}" -f $warmIds) | Out-Null
