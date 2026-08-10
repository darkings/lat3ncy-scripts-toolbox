#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screenshot
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Take a Snipping Tool screenshot and copy the result to the clipboard
# @raycast.icon 📷

$ErrorActionPreference = 'Stop'

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
  Write-Output 'Snipping Tool window not found. Windows 11 22H2+ is required.'
  exit 1
}

Write-Output 'Screenshot opened: select an area, the result will be copied to the clipboard'
