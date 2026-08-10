#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screenshot OCR
# @raycast.mode silent
# @raycast.timeout 90000
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Screenshot, OCR text, copy to clipboard and show a balloon tip
# @raycast.icon 🧠

$ErrorActionPreference = 'Stop'

# 注入与识别都在 ocr/ocr.py 内完成（ctypes 注入，避免 PowerShell Add-Type 编译开销），
# 本脚本等待识别结束后用托盘气泡显示结果。
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

$title = 'OCR 已复制'
$message = '识别完成，文本已复制到剪贴板'
if ($process.ExitCode -ne 0)
{
  $title = 'OCR 失败'
  $message = '识别失败，请重试'
} elseif (Test-Path -LiteralPath $resultFile)
{
  # ocr.py 以 UTF-8 无 BOM 写入，PS 5.1 的 Get-Content 默认按 ANSI 解码会乱码，须显式 UTF-8
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

# 托盘气泡：需要消息泵才能显示，用 DoEvents 轮询保持进程存活
Add-Type -AssemblyName System.Windows.Forms
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
