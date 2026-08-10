#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screenshot
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description 触发截图工具（Snipping Tool）截图，结果复制到剪贴板
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
  Write-Output '未检测到截图工具窗口，请确认系统为 Windows 11 22H2+'
  exit 1
}

Write-Output '已打开截图：框选后结果复制到剪贴板，可用智能粘贴保存到目录'
