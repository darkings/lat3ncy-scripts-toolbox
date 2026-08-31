#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Reset Navicat Trial
# @raycast.mode silent
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Check current OS and reset Navicat Premium trial period
# @raycast.icon 🔄

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$navicatDir = Join-Path $repositoryRoot 'tools\navicat-refresh'

# ---------- 1. 检测当前操作系统 ----------
$osType = 'Windows'
if ($PSVersionTable.PSVersion.Major -ge 6)
{
  if ($IsMacOS)
  {
    $osType = 'macOS'
  }
  elseif ($IsLinux)
  {
    $osType = 'Linux'
  }
  else
  {
    $osType = 'Windows'
  }
}
else
{
  if ([System.Environment]::OSVersion.Platform -match 'Win')
  {
    $osType = 'Windows'
  }
  elseif ($null -ne (Get-Command 'uname' -ErrorAction SilentlyContinue) -and (uname) -eq 'Darwin')
  {
    $osType = 'macOS'
  }
  elseif ($null -ne (Get-Command 'uname' -ErrorAction SilentlyContinue) -and (uname) -eq 'Linux')
  {
    $osType = 'Linux'
  }
}

$exitCode = 0
$outputMsg = ''

# ---------- 2. 根据系统分发调用对应的脚本 ----------
if ($osType -eq 'Windows')
{
  $scriptPath = Join-Path $navicatDir 'reset_navicat.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf))
  {
    throw "未找到 Windows 重置脚本: $scriptPath"
  }

  try
  {
    # 子脚本大量 Write-Host；不吞掉就会变成 silent 的最后一行，盖住真正的结果提示。
    & $scriptPath -Force *>$null
    $exitCode = $LASTEXITCODE
  }
  catch
  {
    $exitCode = 1
    $outputMsg = $_.Exception.Message
  }
}
elseif ($osType -eq 'macOS' -or $osType -eq 'Linux')
{
  $scriptPath = Join-Path $navicatDir 'reset_navicat.sh'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf))
  {
    throw "未找到 $osType 重置脚本: $scriptPath"
  }

  try
  {
    bash "$scriptPath" *>$null
    $exitCode = $LASTEXITCODE
  }
  catch
  {
    $exitCode = 1
    $outputMsg = $_.Exception.Message
  }
}
else
{
  throw '不支持的操作系统'
}

# ---------- 3. 结果通知与状态反馈 ----------
# silent 关窗后，成功走共享 HUD；失败走系统 Toast。stdout 只作 HUD 失败回退。
if ($exitCode -eq 0 -or $null -eq $exitCode)
{
  $successText = 'Navicat 试用期已重置'
  if (-not (Show-ToolboxNotify -Type success -Icon '✓' -Text $successText -Duration 900))
  {
    Write-Output "✓ $successText"
  }
}
else
{
  $failText = 'Navicat 试用期重置失败' + $(if ($outputMsg) { ": $outputMsg" } else { '' })
  Show-SystemToast -Title '× Reset Navicat Trial 执行失败' -Message $failText | Out-Null
  Write-Output "× $failText"
  exit $exitCode
}
