#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Reload IME HUD
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Rebuild anchor-locator + WinUI HUD, restart both, keep AHK in sync
# @raycast.icon 🧭

# Build/test in isolation, then atomically publish HUD + anchor with recovery.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\settings.ps1')
if(-not(Test-ToolboxRaycastCommandEnabled -Command 'reload-ime-hud')){exit 0}
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repositoryRoot 'tools\startup\Deployment.Runtime.ps1')
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Invoke-ToolboxReleaseProcess -Exe $hostExe -TimeoutMs 600000 -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $repositoryRoot 'tools\startup\Rebuild-ToolboxHud.ps1')
)
Show-SystemToast -Title '✓ IME HUD 已重载' -Message '构建与验证通过，HUD 和锚点助手已部署，运行检查正常。' | Out-Null
