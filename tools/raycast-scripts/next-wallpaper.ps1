#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Next Wallpaper
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Switch desktop and lock screen to the next image in the wallpaper pool
# @raycast.icon 🖼️

$ErrorActionPreference = 'Stop'
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
  throw "Desktop changed, but lock screen failed: $([IO.Path]::GetFileName($next))"
}

Show-SystemToast -Title 'Wallpaper and lock screen updated' -Message ([IO.Path]::GetFileName($next)) | Out-Null
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
