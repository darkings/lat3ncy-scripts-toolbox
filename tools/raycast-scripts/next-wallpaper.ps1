#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Next Wallpaper
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Switch desktop and lock screen to the next image in the wallpaper pool
# @raycast.icon 🖼️

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\settings.ps1')
if(-not(Test-ToolboxRaycastCommandEnabled -Command 'next-wallpaper')){exit 0}
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { 'Raycast 脚本' }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$themeRoot = Join-Path $repositoryRoot 'tools\theme-scheduler'
$themeUtils = Join-Path $themeRoot 'ThemeUtils.ps1'
if (-not (Test-Path -LiteralPath $themeUtils -PathType Leaf)) {
  throw "Theme utils not found: $themeUtils"
}
. $themeUtils
if(-not(Test-ThemeFeatureEnabled)){return}

$mutex = [System.Threading.Mutex]::new($false, 'Local\lat3ncy-next-wallpaper')
$mutexOwned = $false
try
{
  $mutexOwned = $mutex.WaitOne(10000)
}
catch [System.Threading.AbandonedMutexException]
{
  $mutexOwned = $true
}
if (-not $mutexOwned)
{
  throw 'Another wallpaper change is still running.'
}

try
{
$config = Get-ThemeConfig
$pool = @(Get-WallpaperPool -Config $config)
if ($pool.Count -eq 0) {
  $directory = [string]$config.wallpaper.directory
  if (-not $directory) { $directory = 'wallpaper.directory' }
  throw "No wallpaper images found: $directory"
}

$next = Get-NextWallpaperImage -Config $config -CurrentPath (Get-DesktopWallpaperPath)
if (-not $next -or -not (Test-Path -LiteralPath $next -PathType Leaf)) {
  throw 'No next wallpaper was selected'
}

if (-not (Set-DesktopWallpaper -ImagePath $next)) {
  throw "Desktop wallpaper failed: $next"
}

if (-not (Sync-LockScreenWallpaper -Config $config -ImagePath $next)) {
  # 桌面已经换好了；这里把锁屏失败的真实原因带进 Toast，省得再去翻日志。
  $detail = if ($script:ThemeLockScreenError) { [string]$script:ThemeLockScreenError } else { '' }
  if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) + '…' }
  $suffix = if ($detail) { ' — ' + $detail } else { '' }
  throw "Desktop changed, but lock screen failed: $([IO.Path]::GetFileName($next))$suffix"
}

# 壁纸和锁屏已更换，静默退出不弹 Toast
exit 0
}
finally
{
  if ($mutexOwned)
  {
    try { $mutex.ReleaseMutex() } catch {}
  }
  $mutex.Dispose()
}
