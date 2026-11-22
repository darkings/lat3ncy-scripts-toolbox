#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Screenshot OCR
# @raycast.mode silent
# @raycast.timeout 90000
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Screenshot, OCR text, copy to clipboard and show a system toast
# @raycast.icon 🧠

# OCR 引擎切换：ocr/config.toml 的顶层 "ocr" 字段
#   "system"   （默认）Win+Shift+T 系统文本操作（Windows 11 23H2+），
#               框选识别复制全部由系统完成，本脚本不弹通知
#   "rapidocr" 旧方案：先打开截图框，再 pythonw + RapidOCR（--no-screenshot），
#               识别后弹系统 Toast。框选不再被 ONNX 冷启动挡住。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')
. (Join-Path $PSScriptRoot 'ocr\OcrHost.ps1')
. (Join-Path $PSScriptRoot '..\ToolboxControls.ps1')
if(-not(Test-ToolboxModuleEnabled -Module ocr -RepoRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))){return}

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  # 已通过系统 Toast 统一提示，避免再触发 Raycast 自带的错误气泡
  exit 0
}

function Invoke-ScreenClip {
  try {
    # 先出系统截图框，避免 PowerShell/Python/模型加载挡住框选。
    # OCR 只复制文字，禁止启动 capture/watch-save.ps1：
    # 自动保存开着时系统仍可能写 png，但本命令不报保存路径。
    Start-Process -FilePath "ms-screenclip:" | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Invoke-WinShiftS {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RapidOcrHotkeySim {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

  [RapidOcrHotkeySim]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)      # Win 按下
  [RapidOcrHotkeySim]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)      # Shift 按下
  [RapidOcrHotkeySim]::keybd_event(0x53, 0, 0, [UIntPtr]::Zero)      # S 按下
  Start-Sleep -Milliseconds 60
  [RapidOcrHotkeySim]::keybd_event(0x53, 0, 0x0002, [UIntPtr]::Zero) # S 抬起
  [RapidOcrHotkeySim]::keybd_event(0x10, 0, 0x0002, [UIntPtr]::Zero) # Shift 抬起
  [RapidOcrHotkeySim]::keybd_event(0x5B, 0, 0x0002, [UIntPtr]::Zero) # Win 抬起
}

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

if ($mode -eq 'rapidocr')
{
  # ================= RapidOCR 分支 =================
  # 必须先出框，再启动 pythonw。ocr.py 用 --no-screenshot，只轮询剪贴板并识别。
  if (-not (Invoke-ScreenClip))
  {
    Invoke-WinShiftS
  }

  $ocrScript = Join-Path $PSScriptRoot 'ocr\ocr.py'
  if (-not (Test-Path -LiteralPath $ocrScript -PathType Leaf))
  {
    Show-SystemToast -Title '× OCR 失败' -Message 'OCR 脚本不存在' | Out-Null
    exit 0
  }

  # Python 解析顺序：
  #   1. venv 声明的同版本基础 pythonw + -I -S/ocr_host.py；依赖仍只用该 venv。
  #      基础宿主避免仓库 Low 标签导致通知 API 失败，不改 ACL/安装包。
  #   2. ocr\.venv314\Scripts\pythonw.exe —— 基础宿主不可用时保留旧入口。
  #      RapidOCR 的 onnxruntime 只有 cp311-cp314 wheel，scoop 全局 Python 是 3.15
  #      时装不上；venv 自带 .gitignore（uv 生成），不入库。
  #   3. 全局 pythonw / pyw —— venv 不存在时兜底（Python ≤3.14 的机器直接可用）。
  $pythonCandidates = @()
  $venvPythonw = Join-Path $PSScriptRoot 'ocr\.venv314\Scripts\pythonw.exe'
  if (Test-Path -LiteralPath $venvPythonw -PathType Leaf)
  {
    $pythonCandidates += $venvPythonw
  }
  $pythonCandidates += Get-Command pythonw.exe -ErrorAction SilentlyContinue
  $pythonCandidates += Get-Command pyw.exe -ErrorAction SilentlyContinue

  $pythonExe = $null
  $hostPrefix = @()
  foreach ($candidate in $pythonCandidates)
  {
    if ($candidate -is [string])
    {
      $pythonExe = $candidate
      break
    }
    if ($candidate -and $candidate.Source)
    {
      $pythonExe = $candidate.Source
      break
    }
  }
  $hostSpec = Get-OcrLaunchSpec -ModuleDirectory (Join-Path $PSScriptRoot 'ocr')
  if ($hostSpec) {
    $pythonExe = $hostSpec.Python
    $ocrScript = $hostSpec.Script
    $hostPrefix = $hostSpec.Prefix
  }
  if (-not $pythonExe)
  {
    Show-SystemToast -Title '× OCR 失败' -Message '未找到 Python 运行环境' | Out-Null
    exit 0
  }

  # Raycast host 对 scriptCommands.runScript 的 IPC 请求有 30s 硬超时
  # （脚本头 @raycast.timeout 90000 管不到这层）；uv venv 冷启动 + RapidOCR
  # 三模型加载实测可超 30s，Raycast UI 会提前弹 "Script execution failed"，
  # 虽然脚本仍在正常跑（2026-11-06 实测：13:46:48 runScript → 13:47:18 超时报错，
  # 截图 13:46:52 已进剪贴板）。
  # 因此这里不等待：pythonw detached 启动，ps1 立即 exit 0；
  # 结果 Toast 由 ocr.py --notify-on-done 自己负责（ocr.py 复用 shared/notify/toast.ps1）。
  # 启动优先级：
  #   1. WMI Win32_Process.Create —— 无句柄继承、不在调用方进程树/Job 里（实测 1.7s 退出）
  #   2. 普通 Start-Process（不加 -WindowStyle）—— 兜底；-WindowStyle 会强制
  #      UseShellExecute=false，pythonw 继承 stdout 管道，Raycast 要等整棵树结束
  #      → 必然 30s 超时（2026-11-06 实测 EXIT/close 40s 不触发）
  # 日志写在仓库内 ocr\.debug.log（MSIX 不虚拟化 Projects 目录，两种上下文都能写）。
  $debugLog = Join-Path $PSScriptRoot 'ocr\.debug.log'
  function Write-OcrDebug([string] $message)
  {
    try
    {
      ('{0} {1}' -f (Get-Date).ToString('HH:mm:ss.fff'), $message) |
        Out-File -FilePath $debugLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
  }

  $resultFile = Join-Path $env:TEMP (
    'lat3ncy-ocr-result-{0}.txt' -f [guid]::NewGuid().ToString('N')
  )
  Write-OcrDebug ('ps1 mode=rapidocr user={0} python={1} result={2}' -f $env:USERNAME, $pythonExe, $resultFile)

  $prefixLine = if ($hostPrefix.Count) { ($hostPrefix -join ' ') + ' ' } else { '' }
  $cmdLine = '"{0}" {1}"{2}" --no-screenshot --result-file "{3}" --notify-on-done' -f $pythonExe, $prefixLine, $ocrScript, $resultFile
  $spawned = $false
  try
  {
    $spawn = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine }
    Write-OcrDebug ('wmi rv={0} pid={1}' -f $spawn.ReturnValue, $spawn.ProcessId)
    $spawned = ($spawn.ReturnValue -eq 0)
  } catch
  {
    Write-OcrDebug ('wmi threw: {0}' -f $_.Exception.Message)
  }

  if (-not $spawned)
  {
    try
    {
      $started = Start-Process -FilePath $pythonExe `
        -ArgumentList ($hostPrefix + @(('"{0}"' -f $ocrScript), '--no-screenshot', '--result-file', ('"{0}"' -f $resultFile), '--notify-on-done')) `
        -PassThru
      Write-OcrDebug ('fallback start-process pid={0}' -f $started.Id)
    } catch
    {
      Write-OcrDebug ('fallback threw: {0}' -f $_.Exception.Message)
      Show-SystemToast -Title '× OCR 失败' -Message ('无法启动 OCR 进程：' + $_.Exception.Message) | Out-Null
    }
  }

  Write-OcrDebug 'ps1 exit'
  exit 0
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

  exit 0
}
