#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screen Record
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Start a Snipping Tool screen recording and select the area
# @raycast.icon 🎥

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

# 后台监视系统是否把 mp4 写进捕获目录；OCR 入口禁止调用。
function Start-CaptureSaveWatcher {
  param(
    [Parameter(Mandatory = $true)]
    [string] $StartedAt
  )

  $watcher = Join-Path $PSScriptRoot 'capture\watch-save.ps1'
  if (-not (Test-Path -LiteralPath $watcher -PathType Leaf)) {
    return
  }

  # 隐藏启动、不等待：保存通知不能并进下面的 500ms 打开探测。
  # -STA：落盘后写剪贴板必须在单线程单元，否则 Set-Clipboard 可能失败。
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile',
    '-STA',
    '-ExecutionPolicy', 'Bypass',
    '-File', $watcher,
    '-Mode', 'Record',
    '-StartedAt', $StartedAt
  ) | Out-Null
}

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

# 先记下本地时间，再出框，后台用它排除旧文件。
$startedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffffff')

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
  Show-SystemToast -Title '× 录屏失败' -Message '无法打开录屏工具' | Out-Null
  exit 1
}

Start-CaptureSaveWatcher -StartedAt $startedAt
exit 0
