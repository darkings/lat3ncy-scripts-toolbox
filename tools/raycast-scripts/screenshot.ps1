#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screenshot
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Take a Snipping Tool screenshot and copy the result to the clipboard
# @raycast.icon 📷

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

# 截图工具没有公开的命令行参数，只能注入系统热键 Win+Shift+S
# （keybd_event 为低层注入，可触发系统注册热键）。
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SystemHotkeySim {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

$VK_LWIN = 0x5B   # 左 Win
$VK_SHIFT = 0x10  # Shift
$VK_S = 0x53      # S
$KEYEVENTF_KEYUP = 0x0002

[SystemHotkeySim]::keybd_event($VK_LWIN, 0, 0, [UIntPtr]::Zero)
[SystemHotkeySim]::keybd_event($VK_SHIFT, 0, 0, [UIntPtr]::Zero)
[SystemHotkeySim]::keybd_event($VK_S, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[SystemHotkeySim]::keybd_event($VK_S, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
[SystemHotkeySim]::keybd_event($VK_SHIFT, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
[SystemHotkeySim]::keybd_event($VK_LWIN, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)

Start-Sleep -Milliseconds 500
if (-not (Get-Process -Name 'SnippingTool' -ErrorAction SilentlyContinue))
{
  $shown = Show-ToolboxNotify -Type 'error' -Icon '×' -Text '无法打开截图工具'
  if (-not $shown)
  {
    Write-Output '× 无法打开截图工具'
  }
  exit 1
}

$shown = Show-ToolboxNotify -Type 'state' -Icon '▣' -Text '截图已打开'
if (-not $shown)
{
  Write-Output '▣ 截图已打开'
}
