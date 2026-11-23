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
  if($session -and $repositoryRoot){try{Set-ToolboxCaptureResult $repositoryRoot Record $session.id failed launch_failed}catch{}}
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

. (Join-Path $PSScriptRoot 'capture\CaptureSupport.ps1')
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$options=Get-ToolboxCaptureOptions -Mode Record -Repo $repositoryRoot
if(-not $options.Enabled){exit 0}
$session=New-ToolboxCaptureSession -Mode Record -Options $options -Repo $repositoryRoot

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
  Set-ToolboxCaptureResult $repositoryRoot Record $session.id failed launch_failed
  Show-SystemToast -Title '× 录屏失败' -Message '无法打开录屏工具' | Out-Null
  exit 1
}

if($options.CopyToClipboard -or $options.ExtraDirectory){Start-ToolboxCaptureWatcher -Repo $repositoryRoot -Mode Record -SessionId $session.id}
exit 0
