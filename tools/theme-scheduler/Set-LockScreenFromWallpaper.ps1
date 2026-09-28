<#
.SYNOPSIS
  让锁屏背景跟当前桌面壁纸保持一致。

.DESCRIPTION
  Windows 11 已删掉「锁屏与桌面使用同一张图」的原生开关（只剩 Windows 聚焦 / 图片 / 幻灯片），
  这里使用官方 WinRT API Windows.System.UserProfile.LockScreen.SetImageFileAsync 直接设置锁屏图片：

    * 按用户生效，不需要管理员，也不会把设置页变成「由组织管理」（那是 PersonalizationCSP 的代价）。
    * 先读取当前桌面壁纸（HKCU\Control Panel\Desktop\Wallpaper，失效时回退 TranscodedWallpaper），
      再复制成带正确扩展名的唯一副本交给锁屏；每次运行文件名都不同（含时间戳与内容哈希前缀），
      避免锁屏影像存储按路径/内容去重导致的「调用成功但锁屏没变」。
    * 设置完成后用 LockScreen.GetImageStream()（同步 API）读回当前锁屏图并比对像素尺寸，
      不一致就报错并以非 0 退出——没有这一步，静默失效是无法察觉的。
    * 旧副本按 KeepCopies 自动清理。

  由 tools/theme-scheduler 调用（config.toml 的 wallpaper.sync_lock_screen 控制）。
  必须运行在 Windows PowerShell 5.1 下：WinRT 互操作依赖 .NET Framework 的 System.Runtime.WindowsRuntime。
  从 PowerShell 7 启动时会自动改用 powershell.exe 重新执行，两种终端里都能直接调用。

.PARAMETER ImagePath
  指定图片；默认取当前桌面壁纸。

.PARAMETER StoreDirectory
  副本存放目录，默认 %LOCALAPPDATA%\Lat3ncy\lockscreen。

.PARAMETER KeepCopies
  目录内保留的副本数量，默认 5，更旧的自动清理。

.EXAMPLE
  .\Set-LockScreenFromWallpaper.ps1
  把锁屏设置成当前桌面壁纸。

.EXAMPLE
  .\Set-LockScreenFromWallpaper.ps1 -ImagePath 'D:\Pictures\a.jpg'
  把锁屏设置成指定图片。
#>
[CmdletBinding()]
param(
	[string]$ImagePath,

	[string]$StoreDirectory = (Join-Path $env:LOCALAPPDATA 'Lat3ncy\lockscreen'),

	[ValidateRange(1, 100)]
	[int]$KeepCopies = 5
)

$ErrorActionPreference = 'Stop'

# --- PowerShell 7 下自动改用 Windows PowerShell 5.1 重新执行 ---
if ($PSVersionTable.PSEdition -eq 'Core')
{
	$winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
	if (!(Test-Path -LiteralPath $winPs)) { throw "找不到 Windows PowerShell 5.1：$winPs" }
	$argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
	if ($ImagePath) { $argList += @('-ImagePath', $ImagePath) }
	if ($StoreDirectory) { $argList += @('-StoreDirectory', $StoreDirectory) }
	$argList += @('-KeepCopies', $KeepCopies)
	& $winPs @argList
	exit $LASTEXITCODE
}

function Get-DesktopWallpaperPath
{
	$value = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper
	if ($value -and (Test-Path -LiteralPath $value -PathType Leaf)) { return $value }
	# 幻灯片模式下 Wallpaper 可能指向不存在的位置，TranscodedWallpaper 始终是"当前这一张"
	$fallback = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
	if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
	return $null
}

function Get-ImageExtension
{
	# TranscodedWallpaper 没有扩展名，按魔数判断真实格式
	param([Parameter(Mandatory = $true)][string]$Path)

	$head = Get-Content -LiteralPath $Path -Encoding Byte -TotalCount 8 -ErrorAction Stop
	if ($head.Length -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xD8) { return '.jpg' }
	if ($head.Length -ge 8 -and $head[0] -eq 0x89 -and $head[1] -eq 0x50) { return '.png' }
	if ($head.Length -ge 2 -and $head[0] -eq 0x42 -and $head[1] -eq 0x4D) { return '.bmp' }
	if ($head.Length -ge 3 -and $head[0] -eq 0x47 -and $head[1] -eq 0x49) { return '.gif' }
	return '.jpg'
}

function Get-ImagePixelSize
{
	param([Parameter(Mandatory = $true)][string]$Path)

	Add-Type -AssemblyName System.Drawing
	$image = [System.Drawing.Image]::FromFile($Path)
	try { return [pscustomobject]@{ Width = $image.Width; Height = $image.Height } }
	finally { $image.Dispose() }
}

# --- WinRT 互操作（仅 5.1 可用）---
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
		$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
		$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
	})[0]
$script:asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
		$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
		$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
	})[0]
if (!$script:asTaskGeneric -or !$script:asTaskAction) { throw 'WinRT 互操作不可用：找不到 AsTask 重载，请确认运行在 Windows PowerShell 5.1 下。' }

function Wait-AsyncOperation
{
	param([Parameter(Mandatory)]$Operation, [Parameter(Mandatory)][Type]$ResultType)

	$task = $script:asTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
	$task.Wait(-1) | Out-Null
	return $task.Result
}

function Wait-AsyncAction
{
	param([Parameter(Mandatory)]$Action)

	$task = $script:asTaskAction.Invoke($null, @($Action))
	$task.Wait(-1) | Out-Null
}

[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
[Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null

function Get-LockScreenImageSize
{
	# GetImageStream() 是同步 API，直接返回 IRandomAccessStream
	param([Parameter(Mandatory = $true)][string]$ScratchFile)

	$stream = [Windows.System.UserProfile.LockScreen]::GetImageStream()
	try
	{
		$netStream = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
		$fileStream = [System.IO.File]::Create($ScratchFile)
		try { $netStream.CopyTo($fileStream) }
		finally { $fileStream.Dispose(); $netStream.Dispose() }
	}
	finally { $stream.Dispose() }

	return (Get-ImagePixelSize -Path $ScratchFile)
}

# --- 解析源图片 ---
$source = if ($ImagePath) { (Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop).Path } else { Get-DesktopWallpaperPath }
if (!$source) { throw '找不到桌面壁纸：HKCU\Control Panel\Desktop\Wallpaper 与 TranscodedWallpaper 都不可用。' }
if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "壁纸文件不存在：$source" }

$extension = Get-ImageExtension -Path $source
$sourceSize = Get-ImagePixelSize -Path $source
$contentHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.Substring(0, 8).ToLowerInvariant()

$null = New-Item -ItemType Directory -Path $StoreDirectory -Force
$baseName = 'wallpaper-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $contentHash
$target = Join-Path $StoreDirectory ($baseName + $extension)
$suffix = 1
while (Test-Path -LiteralPath $target)
{
	$target = Join-Path $StoreDirectory ('{0}-{1}{2}' -f $baseName, $suffix, $extension)
	$suffix++
}
Copy-Item -LiteralPath $source -Destination $target -Force

# --- 设置锁屏 ---
try
{
	$file = Wait-AsyncOperation -Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($target)) -ResultType ([Windows.Storage.StorageFile])
	Wait-AsyncAction -Action ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($file))
}
catch
{
	Write-Error ("设置锁屏失败：{0}" -f $_.Exception.Message)
	exit 1
}

# --- 读回校验 ---
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) 'lat3ncy-lockscreen-readback.bin'
$applied = $null
try { $applied = Get-LockScreenImageSize -ScratchFile $scratch }
catch { Write-Warning ("无法读回锁屏图进行校验：{0}" -f $_.Exception.Message) }
finally { Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue }

# --- 清理旧副本 ---
Get-ChildItem -LiteralPath $StoreDirectory -File -Filter 'wallpaper-*' -ErrorAction SilentlyContinue |
	Sort-Object LastWriteTime -Descending |
	Select-Object -Skip $KeepCopies |
	ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

$sizeKB = [math]::Round((Get-Item -LiteralPath $target).Length / 1KB, 1)

if ($applied -and $applied.Width -eq $sourceSize.Width -and $applied.Height -eq $sourceSize.Height)
{
	Write-Host ("桌面壁纸 : {0}" -f $source)
	Write-Host ("锁屏副本 : {0}  ({1} KB)" -f $target, $sizeKB)
	Write-Host ("读回校验 : {0}x{1} 与源一致" -f $applied.Width, $applied.Height) -ForegroundColor Green
	Write-Host '锁屏已更新，按 Win+L 可立即确认。' -ForegroundColor Green
	exit 0
}

$appliedText = if ($applied) { '{0}x{1}' -f $applied.Width, $applied.Height } else { '读回失败' }
Write-Error ("锁屏读回校验未通过：源 {0}x{1}，读回 {2}" -f $sourceSize.Width, $sourceSize.Height, $appliedText)
exit 1