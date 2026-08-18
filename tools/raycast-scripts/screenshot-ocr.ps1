#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screenshot OCR
# @raycast.mode silent
# @raycast.timeout 90000
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Screenshot, OCR text, copy to clipboard and show a balloon tip
# @raycast.icon 🧠

# OCR 引擎切换：ocr/config.json 的 "ocr" 字段
#   "system"   （默认）Win+Shift+T 系统文本操作（Windows 11 23H2+），无需 Python
#   "rapidocr" 旧方案：pythonw + RapidOCR（ctypes 注入 Win+Shift+S）

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 读取 OCR 模式配置 ----------
$mode = 'system'
$configPath = Join-Path $PSScriptRoot 'ocr\config.json'
if (Test-Path -LiteralPath $configPath)
{
  try
  {
    $config = Get-Content -Raw -LiteralPath $configPath -Encoding UTF8 | ConvertFrom-Json
    if ($config.ocr)
    {
      $mode = [string]$config.ocr
    }
  } catch
  {
    $mode = 'system'
  }
}

$title = 'OCR 已复制'
$message = '识别完成，文本已复制到剪贴板'

if ($mode -eq 'rapidocr')
{
  # ================= RapidOCR 分支（原方案，保留备用） =================
  $ocrScript = Join-Path $PSScriptRoot 'ocr\ocr.py'
  if (-not (Test-Path -LiteralPath $ocrScript -PathType Leaf))
  {
    throw "OCR script not found: $ocrScript"
  }

  $pythonw = Get-Command pythonw.exe -ErrorAction SilentlyContinue
  if (-not $pythonw)
  {
    $pythonw = Get-Command pyw.exe -ErrorAction SilentlyContinue
  }
  if (-not $pythonw)
  {
    throw 'pythonw.exe / pyw.exe not found on PATH'
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
    $title = 'OCR 失败'
    $message = '识别失败，请重试'
  } elseif (Test-Path -LiteralPath $resultFile)
  {
    $text = [System.IO.File]::ReadAllText($resultFile, [System.Text.Encoding]::UTF8)
    if ($text)
    {
      $message = $text.Replace("`r", ' ').Replace("`n", ' ')
      if ($message.Length -gt 60)
      {
        $message = $message.Substring(0, 60) + '...'
      }
    } else
    {
      $title = 'OCR 未识别到文字'
      $message = '请重新框选更清晰的区域'
    }
  } else
  {
    $title = 'OCR 已取消'
    $message = '未框选截图区域'
  }
  Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue
} else
{
  # ================= 系统文本操作分支（Win+Shift+T） =================
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

  # 记录触发前剪贴板文本，避免误取旧内容
  $beforeText = [Windows.Forms.Clipboard]::GetText()

  # 等待系统文本操作把识别文本写入剪贴板（框选 + 识别，最长 75 秒）
  $text = ''
  $ocrDeadline = (Get-Date).AddSeconds(75)
  while ((Get-Date) -lt $ocrDeadline)
  {
    $candidate = [Windows.Forms.Clipboard]::GetText()
    if ($candidate -and $candidate -ne $beforeText)
    {
      $text = $candidate
      break
    }
    Start-Sleep -Milliseconds 300
  }

  if ($text)
  {
    [Windows.Forms.Clipboard]::SetText($text)
    $message = $text.Replace("`r", ' ').Replace("`n", ' ')
    if ($message.Length -gt 60)
    {
      $message = $message.Substring(0, 60) + '...'
    }
  } else
  {
    $title = 'OCR 未识别到文字'
    $message = '请确认 Win+Shift+T 文本操作可用'
  }
}

# ---------- 托盘气泡：消息泵保持进程存活 ----------
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.BalloonTipTitle = $title
$icon.BalloonTipText = $message
$icon.Visible = $true
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 300
$icon.ShowBalloonTip(5000)
$deadline = (Get-Date).AddSeconds(6)
while ((Get-Date) -lt $deadline)
{
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 100
}
$icon.Dispose()
