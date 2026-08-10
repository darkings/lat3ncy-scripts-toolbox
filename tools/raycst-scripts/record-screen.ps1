#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screen Record
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description 触发截图工具（Snipping Tool）屏幕录制，一步直达框选
# @raycast.icon 🎥

$ErrorActionPreference = 'Stop'

# 截图工具的录屏模式没有公开命令行参数，只能注入系统热键 Win+Shift+R
# 直达录制模式（keybd_event 为低层注入，可触发系统注册热键）。
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ScreenRecordKey {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

$VK_LWIN = 0x5B   # 左 Win
$VK_SHIFT = 0x10  # Shift
$VK_R = 0x52      # R
$KEYEVENTF_KEYUP = 0x0002

[ScreenRecordKey]::keybd_event($VK_LWIN, 0, 0, [UIntPtr]::Zero)
[ScreenRecordKey]::keybd_event($VK_SHIFT, 0, 0, [UIntPtr]::Zero)
[ScreenRecordKey]::keybd_event($VK_R, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[ScreenRecordKey]::keybd_event($VK_R, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
[ScreenRecordKey]::keybd_event($VK_SHIFT, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
[ScreenRecordKey]::keybd_event($VK_LWIN, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)

Start-Sleep -Milliseconds 500
if (-not (Get-Process -Name 'SnippingTool' -ErrorAction SilentlyContinue))
{
  Write-Output '未检测到截图工具窗口，请确认系统为 Windows 11 22H2+'
  exit 1
}

Write-Output '屏幕录制已打开：框选区域后开始录制，录制中点击浮窗停止'
