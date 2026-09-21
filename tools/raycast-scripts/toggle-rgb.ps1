#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Toggle RGB Lights
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Toggle Gigabyte fan + Hi75 lights. Ambient stays running.
# @raycast.icon 💡

# 单切换：只动 %LOCALAPPDATA%\lat3ncy-toolbox\rgb-disabled.flag。
# 关灯不杀 Ambient / 不碰 OpenRGB 服务；开灯也不改主题调度器。
# 本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按系统 ANSI 误读中文。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { 'Raycast 脚本' }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$rgbRoot = Join-Path $repositoryRoot 'tools\rgb'
$ambientPy = Join-Path $rgbRoot 'ambient.py'
$startScript = Join-Path $rgbRoot 'Start-Ambient.ps1'
$stateDir = Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox'
$disabledFlag = Join-Path $stateDir 'rgb-disabled.flag'

function Get-AmbientPythonProcesses {
  # 只认命令行里带 ambient.py 的解释器，避免误杀 hi75.py / --lights-off
  @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match '(?i)[\\/]ambient\.py(\s|"|$)' -and
        $_.CommandLine -notmatch '(?i)--lights-off'
      })
}

function Test-AmbientRunning {
  # 函数输出会被拆管道：1 个进程时变成单个 CimInstance，.Count 是 $null。
  # 必须在调用处再包一层 @()，否则关灯会误走 --lights-off、开灯会误调 Start-Ambient。
  return (@(Get-AmbientPythonProcesses).Count -gt 0)
}

function Get-ToolboxPythonExe {
  # --lights-off 要等退出码，用 python.exe 而不是 pythonw。
  $cmd = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
    return $cmd.Source
  }
  $wcmd = Get-Command pythonw.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($wcmd -and $wcmd.Source) {
    $sibling = Join-Path (Split-Path -LiteralPath $wcmd.Source) 'python.exe'
    if (Test-Path -LiteralPath $sibling) {
      return $sibling
    }
    return $wcmd.Source
  }
  return $null
}

function Invoke-LightsOffOnce {
  # Ambient 没在跑时才调用。已在跑会抢 Hi75 HID。
  if (-not (Test-Path -LiteralPath $ambientPy -PathType Leaf)) {
    throw "missing $ambientPy"
  }
  $python = Get-ToolboxPythonExe
  if (-not $python) {
    throw '未找到 python.exe，无法在 Ambient 未运行时关灯'
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $python
  $psi.Arguments = "-u `"$ambientPy`" --lights-off"
  $psi.WorkingDirectory = $rgbRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  if (-not $proc.Start()) {
    throw "failed to start $python --lights-off"
  }
  if (-not $proc.WaitForExit(8000)) {
    try { $proc.Kill() } catch {}
    throw 'ambient.py --lights-off timed out'
  }
  return ($proc.ExitCode -eq 0)
}

function Show-RgbResult {
  param([Parameter(Mandatory = $true)][string]$Text)
  # 开关灯结果走系统 Toast，不再弹共享 HUD。
  Show-SystemToast -Title "💡 $Text" -Message '' | Out-Null
}

if (-not (Test-Path -LiteralPath $stateDir)) {
  New-Item -ItemType Directory -Path $stateDir | Out-Null
}

$flagExists = Test-Path -LiteralPath $disabledFlag -PathType Leaf

if (-not $flagExists) {
  # 关灯：写 flag，Ambient 主循环下一帧推 Direct 全黑并继续 keepalive。
  Set-Content -LiteralPath $disabledFlag -Value '1' -Encoding ascii
  if (Test-AmbientRunning) {
    Start-Sleep -Milliseconds 250
  } else {
    $ok = $false
    try {
      $ok = Invoke-LightsOffOnce
    } catch {
      Remove-Item -LiteralPath $disabledFlag -Force -ErrorAction SilentlyContinue
      throw
    }
    if (-not $ok) {
      Show-SystemToast -Title '× Toggle RGB Lights 执行失败' -Message '已记下关灯状态，但这次没推上全黑' | Out-Null
      exit 1
    }
  }
  Show-RgbResult -Text 'RGB 灯光已关闭'
  exit 0
}

# 开灯：删 flag。Ambient 在跑则下一帧取色推灯；没在跑则拉起常驻。
Remove-Item -LiteralPath $disabledFlag -Force -ErrorAction SilentlyContinue
if (-not (Test-AmbientRunning)) {
  if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    throw "missing $startScript"
  }
  & $startScript
  if ($LASTEXITCODE -ne 0) {
    throw "Start-Ambient.ps1 exited $LASTEXITCODE"
  }
}
Show-RgbResult -Text 'RGB 灯光已开启'
exit 0
