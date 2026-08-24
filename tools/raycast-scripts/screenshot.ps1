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

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

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

Start-Sleep -Milliseconds 700
# Win11 22H2+ 用 ScreenClippingHost / ShellExperienceHost，旧版用 SnippingTool，全部兼容
$snipProc = Get-Process -Name 'SnippingTool','ScreenClippingHost','ShellExperienceHost' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $snipProc)
{
  # 兜底：Win+Shift+S 注入后系统可能还没拉起进程，稍等再查一次
  Start-Sleep -Milliseconds 400
  $snipProc = Get-Process -Name 'SnippingTool','ScreenClippingHost','ShellExperienceHost' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $snipProc)
{
  Show-SystemToast -Title '× 截图失败' -Message '无法打开截图工具' | Out-Null
  exit 1
}

exit 0
