#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screenshot OCR
# @raycast.mode compact
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description 系统截图后自动 OCR，识别文本复制到剪贴板
# @raycast.icon 🧠

$ErrorActionPreference = 'Stop'

# 注入 Win+Shift+S 打开截图工具框选，随后由 screenshot_ocr.py --clipboard
# 轮询剪贴板中的图片并完成 RapidOCR 识别。
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

$ocrScript = Join-Path $PSScriptRoot 'ocr\screenshot_ocr.py'
if (-not (Test-Path -LiteralPath $ocrScript -PathType Leaf))
{
  throw "OCR script not found: $ocrScript"
}

$pythonw = Get-Command pythonw.exe -ErrorAction SilentlyContinue
if (-not $pythonw)
{
  $pythonw = Get-Command pyw.exe -ErrorAction Stop
}
Start-Process -FilePath $pythonw.Source -ArgumentList ('"{0}"' -f $ocrScript), '--clipboard'

Write-Output '请框选截图区域，识别完成后文本将自动复制到剪贴板'
