#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Reset Navicat Trial
# @raycast.mode compact
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Check current OS and reset Navicat Premium trial period
# @raycast.icon 🔄

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

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
    Show-ToolboxNotify -Type 'error' -Icon '×' -Text "未找到 Windows 重置脚本" | Out-Null
    Write-Output "× 未找到 Windows 重置脚本: $scriptPath"
    exit 1
  }

  try
  {
    & $scriptPath -Force
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
    Show-ToolboxNotify -Type 'error' -Icon '×' -Text "未找到 $osType 重置脚本" | Out-Null
    Write-Output "× 未找到 $osType 重置脚本: $scriptPath"
    exit 1
  }

  try
  {
    bash "$scriptPath"
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
  Show-ToolboxNotify -Type 'error' -Icon '×' -Text '不支持的操作系统' | Out-Null
  Write-Output '× 不支持的操作系统'
  exit 1
}

# ---------- 3. 结果通知与状态反馈 ----------
if ($exitCode -eq 0 -or $null -eq $exitCode)
{
  Show-ToolboxNotify -Type 'success' -Icon '✓' -Text 'Navicat 试用期已重置' | Out-Null
  Write-Output '✓ Navicat 试用期已重置'
}
else
{
  Show-ToolboxNotify -Type 'error' -Icon '×' -Text 'Navicat 试用期重置失败' | Out-Null
  Write-Output ('× Navicat 试用期重置失败' + $(if ($outputMsg) { ": $outputMsg" } else { '' }))
  exit $exitCode
}
