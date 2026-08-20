#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screenshot OCR
# @raycast.mode silent
# @raycast.timeout 90000
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Screenshot, OCR text, copy to clipboard and show a unified HUD
# @raycast.icon 🧠

# OCR 引擎切换：ocr/config.toml 的顶层 "ocr" 字段
#   "system"   （默认）Win+Shift+T 系统文本操作（Windows 11 23H2+），
#               框选识别复制全部由系统完成，本脚本不弹通知
#   "rapidocr" 旧方案：pythonw + RapidOCR（ctypes 注入 Win+Shift+S），识别后弹气泡

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

# ---------- 读取 OCR 模式配置（TOML 顶层键，正则解析） ----------
$mode = 'system'
$configPath = Join-Path $PSScriptRoot 'ocr\config.toml'
if (Test-Path -LiteralPath $configPath)
{
  try
  {
    $configText = Get-Content -Raw -LiteralPath $configPath -Encoding UTF8
    if ($configText -match '(?m)^\s*ocr\s*=\s*"([^"]+)"')
    {
      $mode = $Matches[1]
    }
  } catch
  {
    $mode = 'system'
  }
}

$notificationType = 'success'
$notificationIcon = '✓'
$notificationText = 'OCR 已复制'

if ($mode -eq 'rapidocr')
{
  # ================= RapidOCR 分支（原方案，保留备用） =================
  $ocrScript = Join-Path $PSScriptRoot 'ocr\ocr.py'
  if (-not (Test-Path -LiteralPath $ocrScript -PathType Leaf))
  {
    $shown = Show-ToolboxNotify -Type 'error' -Icon '×' -Text 'OCR 脚本不存在'
    if (-not $shown)
    {
      Write-Output '× OCR 脚本不存在'
    }
    exit 1
  }

  $pythonw = Get-Command pythonw.exe -ErrorAction SilentlyContinue
  if (-not $pythonw)
  {
    $pythonw = Get-Command pyw.exe -ErrorAction SilentlyContinue
  }
  if (-not $pythonw)
  {
    $shown = Show-ToolboxNotify -Type 'error' -Icon '×' -Text '未找到 Python'
    if (-not $shown)
    {
      Write-Output '× 未找到 Python'
    }
    exit 1
  }

  $resultFile = Join-Path $env:TEMP (
    'lat3ncy-ocr-result-{0}.txt' -f [guid]::NewGuid().ToString('N')
  )
  $process = Start-Process -FilePath $pythonw.Source `
    -ArgumentList ('"{0}"' -f $ocrScript), '--result-file', ('"{0}"' -f $resultFile) `
    -PassThru
  $process.WaitForExit(90000) | Out-Null

  if ($process.ExitCode -ne 0)
  {
    $notificationType = 'error'
    $notificationIcon = '×'
    $notificationText = 'OCR 失败'
  } elseif (Test-Path -LiteralPath $resultFile)
  {
    $text = [System.IO.File]::ReadAllText($resultFile, [System.Text.Encoding]::UTF8)
    if (-not $text)
    {
      $notificationType = 'error'
      $notificationIcon = '!'
      $notificationText = '未识别到文字'
    }
  } else
  {
    $notificationType = 'info'
    $notificationIcon = '−'
    $notificationText = 'OCR 已取消'
  }
  Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue
} else
{
  # ================= 系统文本操作分支（Win+Shift+T） =================
  # 仅注入快捷键：框选、识别、复制全部由系统完成，不弹通知。
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SystemHotkeySim {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

  [SystemHotkeySim]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)      # Win 按下
  [SystemHotkeySim]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)      # Shift 按下
  [SystemHotkeySim]::keybd_event(0x54, 0, 0, [UIntPtr]::Zero)      # T 按下
  Start-Sleep -Milliseconds 60
  [SystemHotkeySim]::keybd_event(0x54, 0, 0x0002, [UIntPtr]::Zero) # T 抬起
  [SystemHotkeySim]::keybd_event(0x10, 0, 0x0002, [UIntPtr]::Zero) # Shift 抬起
  [SystemHotkeySim]::keybd_event(0x5B, 0, 0x0002, [UIntPtr]::Zero) # Win 抬起

  # 注入完成即退出（系统接管后续流程）
  exit 0
}

$shown = Show-ToolboxNotify -Type $notificationType -Icon $notificationIcon -Text $notificationText
if (-not $shown)
{
  Write-Output "$notificationIcon $notificationText"
}
