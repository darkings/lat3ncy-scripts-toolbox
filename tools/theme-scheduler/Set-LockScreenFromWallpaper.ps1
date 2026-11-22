<#
.SYNOPSIS
  让锁屏背景跟当前桌面壁纸保持一致。

.DESCRIPTION
  Windows 11 已删掉「锁屏与桌面使用同一张图」的原生开关（只剩 Windows 聚焦 / 图片 / 幻灯片），
  这里用官方 WinRT API 直接设置锁屏图片，按用户生效、不需要管理员，也不写 PersonalizationCSP
  （不会把设置页变成「由组织管理」）。

  * 主路径 Windows.System.UserProfile.LockScreen.SetImageStreamAsync：
    自己用普通文件 IO 读图，包成 IRandomAccessStream 交给系统。
    不用 StorageFile.GetFileFromPathAsync——那条路会走 Windows 存储代理的「应用可访问位置」检查，
    从 MSIX 打包应用（Raycast 就是）派生的子进程、或不在代理白名单里的目录会直接
    E_ACCESSDENIED(0x80070005)，报错文案只说「文件不在应用可访问位置」，很难排查。
    普通文件 IO 只受 NTFS 权限约束，读得到就能设，也不需要往磁盘写副本。
  * 兜底路径：原始字节被拒时（实测 16-bit PNG 会让 WinRT 流接口在 ~15s 后抛
    RPC_E_CALL_CANCELED），用 System.Drawing 转成同尺寸 8-bit JPEG 再走同一条流接口。
    正常壁纸不会走这一步，所以没有额外的画质损失。
  * 设置完成后用 LockScreen.GetImageStream()（同步 API）读回当前锁屏图并比对像素尺寸，
    不一致就报错并以非 0 退出——没有这一步，静默失效是无法察觉的。

  由 tools/theme-scheduler 调用（config.toml 的 wallpaper.sync_lock_screen 控制）。
  必须运行在 Windows PowerShell 5.1 下：WinRT 互操作依赖 .NET Framework 的 System.Runtime.WindowsRuntime。
  从 PowerShell 7 启动时会自动改用 powershell.exe 重新执行，两种终端里都能直接调用。

  退出码：0 成功；1 设置失败；2 设置成功但读回校验不通过。

.PARAMETER ImagePath
  指定图片；默认取当前桌面壁纸。

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

	# 内部参数：把本次结果写成 UTF-8 的 key=value 行，供父进程记日志/弹提示。
	# 不去解析子进程的 stdout/stderr——控制台重定向里的中文是按 OEM 代码页编码的，
	# pwsh 7 的父进程按 UTF-8 读会变成乱码。
	[string]$ResultFile
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\ToolboxControls.ps1')
if (-not (Test-ToolboxModuleEnabled -Module theme -RepoRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))) { return }

# --- PowerShell 7 下自动改用 Windows PowerShell 5.1 重新执行 ---
if ($PSVersionTable.PSEdition -eq 'Core')
{
	$winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
	if (!(Test-Path -LiteralPath $winPs)) { throw "找不到 Windows PowerShell 5.1：$winPs" }
	$argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
	if ($ImagePath) { $argList += @('-ImagePath', $ImagePath) }
	if ($ResultFile) { $argList += @('-ResultFile', $ResultFile) }
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

function Get-ImagePixelSize
{
	param([Parameter(Mandatory = $true)][string]$Path)

	Add-Type -AssemblyName System.Drawing
	$image = [System.Drawing.Image]::FromFile($Path)
	try { return [pscustomobject]@{ Width = $image.Width; Height = $image.Height } }
	finally { $image.Dispose() }
}

function Format-ExceptionChain
{
	# AggregateException / MethodInvocationException 会把真正的 HRESULT 埋在 InnerException 里，
	# 只取 $_.Exception.Message 通常只剩一句「One or more errors occurred.」。
	param([Parameter(Mandatory = $true)][Exception]$Exception)

	$parts = [System.Collections.Generic.List[string]]::new()
	$current = $Exception
	while ($current -and $parts.Count -lt 6)
	{
		$message = ([string]$current.Message -split "`r?`n")[0].Trim()
		if ($message -and -not $parts.Contains($message)) { $parts.Add($message) }
		$current = $current.InnerException
	}
	return ($parts -join ' | ')
}

function Write-LockScreenResult
{
	# 结果文件给父进程用：UTF-8、单行 key=value，避免控制台重定向的代码页问题。
	param(
		[Parameter(Mandatory = $true)][string]$Status,
		[string]$Method = '',
		[string]$Source = '',
		[string]$ErrorText = ''
	)

	if (-not $ResultFile) { return }
	$lines = @(
		('status=' + $Status),
		('method=' + $Method),
		('source=' + ($Source -replace "`r?`n", ' ')),
		('error=' + ($ErrorText -replace "`r?`n", ' '))
	)
	try
	{
		[System.IO.File]::WriteAllLines($ResultFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
	}
	catch { }
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

function Wait-AsyncAction
{
	# 大图（例如 6000x3000）在锁屏影像库里落地要 10s 以上，超时值给足；
	# 外层 tools/theme-scheduler 的进程上限比这里大，超时能先由子进程自己报告。
	param([Parameter(Mandatory)]$Action, [int]$TimeoutMs = 45000)

	$task = $script:asTaskAction.Invoke($null, @($Action))
	if (-not $task.Wait($TimeoutMs)) { throw ('WinRT action timed out after {0}s' -f ($TimeoutMs / 1000)) }
}

[Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
[Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null

function Set-LockScreenImageFromBytes
{
	param([Parameter(Mandatory = $true)][byte[]]$Bytes)

	$stream = New-Object System.IO.MemoryStream
	$randomAccessStream = $null
	try
	{
		$stream.Write($Bytes, 0, $Bytes.Length)
		$stream.Position = 0
		$randomAccessStream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($stream)
		Wait-AsyncAction -Action ([Windows.System.UserProfile.LockScreen]::SetImageStreamAsync($randomAccessStream))
	}
	finally
	{
		if ($randomAccessStream) { $randomAccessStream.Dispose() }
		$stream.Dispose()
	}
}

function Convert-ImageToJpegBytes
{
	# 16-bit PNG 之类 WinRT 流接口不认的像素格式：转成同尺寸 24bpp JPEG 再交出去。
	# 只在上一步失败后调用，普通壁纸不会经过这里。
	param([Parameter(Mandatory = $true)][string]$Path, [int]$Quality = 95)

	Add-Type -AssemblyName System.Drawing
	$image = [System.Drawing.Image]::FromFile($Path)
	try
	{
		$bitmap = New-Object System.Drawing.Bitmap($image.Width, $image.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
		try
		{
			$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
			try
			{
				$graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
				$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
				$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
				$graphics.DrawImage($image, 0, 0, $image.Width, $image.Height)
			}
			finally { $graphics.Dispose() }

			$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
			if (!$codec) { throw '找不到 JPEG 编码器' }
			$encoderParameters = New-Object System.Drawing.Imaging.EncoderParameters(1)
			$encoderParameters.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)
			$jpegStream = New-Object System.IO.MemoryStream
			try
			{
				$bitmap.Save($jpegStream, $codec, $encoderParameters)
				return $jpegStream.ToArray()
			}
			finally { $jpegStream.Dispose() }
		}
		finally { $bitmap.Dispose() }
	}
	finally { $image.Dispose() }
}

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

$sourceSize = Get-ImagePixelSize -Path $source

# --- 设置锁屏：先试原始字节，被拒再转码重试 ---
$method = 'SetImageStreamAsync'
$rawError = $null
try
{
	Set-LockScreenImageFromBytes -Bytes ([System.IO.File]::ReadAllBytes($source))
}
catch
{
	$rawError = Format-ExceptionChain -Exception $_.Exception
	Write-Warning ("原始字节设置锁屏失败，改用 8-bit JPEG 转码后重试：{0}" -f $rawError)
	$method = 'SetImageStreamAsync (JPEG 转码)'
	try
	{
		Set-LockScreenImageFromBytes -Bytes (Convert-ImageToJpegBytes -Path $source)
	}
	catch
	{
		$failure = ("设置锁屏失败（原始字节：{0}；JPEG 转码：{1}）" -f $rawError, (Format-ExceptionChain -Exception $_.Exception))
		Write-LockScreenResult -Status 'failed' -Method $method -Source $source -ErrorText $failure
		Write-Error $failure
		exit 1
	}
}

# --- 读回校验 ---
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) 'lat3ncy-lockscreen-readback.bin'
$applied = $null
try { $applied = Get-LockScreenImageSize -ScratchFile $scratch }
catch { Write-Warning ("无法读回锁屏图进行校验：{0}" -f (Format-ExceptionChain -Exception $_.Exception)) }
finally { Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue }

Write-Host ("桌面壁纸 : {0}" -f $source)
Write-Host ("设置方式 : {0}" -f $method)

if ($null -eq $applied)
{
	Write-LockScreenResult -Status 'ok' -Method $method -Source $source
	Write-Host '锁屏已更新（异步设置已完成，读回校验受当前会话限制已跳过）。' -ForegroundColor Yellow
	exit 0
}

if ($applied.Width -eq $sourceSize.Width -and $applied.Height -eq $sourceSize.Height)
{
	Write-LockScreenResult -Status 'ok' -Method $method -Source $source
	Write-Host ("读回校验 : {0}x{1} 与源一致" -f $applied.Width, $applied.Height) -ForegroundColor Green
	Write-Host '锁屏已更新，按 Win+L 可立即确认。' -ForegroundColor Green
	exit 0
}

$verifyError = ("锁屏读回校验未通过：源 {0}x{1}，读回 {2}x{3}" -f $sourceSize.Width, $sourceSize.Height, $applied.Width, $applied.Height)
Write-LockScreenResult -Status 'verify-failed' -Method $method -Source $source -ErrorText $verifyError
Write-Error $verifyError
exit 2
