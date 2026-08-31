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

# 打开系统截图框后立刻退出。
# 不再 Add-Type 编译、不再 Sleep 700ms、也不再探测 SnippingTool 进程：
# 那些步骤只会让 Raycast 命令看起来“截取屏幕太慢”，框本身由系统拉起。
function Invoke-ScreenClip {
  try {
    # ms-screenclip: 是 Win10/11 截图工具的公开协议，比模拟 Win+Shift+S 更快更稳。
    Start-Process -FilePath "ms-screenclip:" | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Invoke-WinShiftS {
  # 协议不可用时才编译一次 keybd_event，作为兜底。
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
}

# 后台监视系统是否把 png 写进截图目录；OCR 入口禁止调用。
function Start-CaptureSaveWatcher {
  param(
    [Parameter(Mandatory = $true)]
    [string] $StartedAt
  )

  $watcher = Join-Path $PSScriptRoot 'capture\watch-save.ps1'
  if (-not (Test-Path -LiteralPath $watcher -PathType Leaf)) {
    return
  }

  # 隐藏启动、不等待：不能让 Raycast silent 卡住。
  # -STA：落盘后写剪贴板必须在单线程单元，否则 SetDataObject 会失败。
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile',
    '-STA',
    '-ExecutionPolicy', 'Bypass',
    '-File', $watcher,
    '-Mode', 'Screenshot',
    '-StartedAt', $StartedAt
  ) | Out-Null
}

# 先记下本地时间，再出框，后台用它排除旧文件。
$startedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffffff')

if (-not (Invoke-ScreenClip)) {
  Invoke-WinShiftS
}

Start-CaptureSaveWatcher -StartedAt $startedAt
exit 0
