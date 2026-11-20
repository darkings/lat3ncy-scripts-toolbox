<#
.SYNOPSIS
  登录自启入口：可靠地拉起工具箱 AutoHotkey v2（ahk/main.ahk），并留下可诊断的日志。

.DESCRIPTION
  启动文件夹里的快捷方式应指向本脚本，而不是直接指向 Scoop 的 current 路径。原因：
    * Scoop 的 current 路径会随版本/junction 变化（本机迁移 profile 后 autohotkey 的 current 甚至变成了实目录），
      `scoop update` 期间可能被替换甚至半删除；
    * 启动文件夹的快捷方式一旦目标失效就静默失败，没有任何痕迹；
    * 登录时 shell/磁盘/热键可能尚未就绪，需要重试。
  本脚本按顺序解析引擎（官方安装 -> Scoop shim/UX -> Scoop current\v2 -> Program Files），
  带重试地启动 main.ahk，然后校验进程是否真的存活（包括检查 main.ahk 是否弹出了启动错误框），
  并把每次结果追加到 %LOCALAPPDATA%\lat3ncy-toolbox\startup.log（保留最近 KeepLogLines 行）。
  失败且未指定 -NoToast 时弹系统 Toast，避免"重启后没起来"再次无声发生。

.PARAMETER EnginePath
  仅排错/测试用：强制使用指定引擎，跳过自动解析。
.PARAMETER MaxAttempts
  启动尝试次数，默认 3。
.PARAMETER RetryDelaySeconds
  每次重试间隔秒数，默认 5。
.PARAMETER KeepLogLines
  日志保留行数，默认 300。
.PARAMETER Force
  已在运行时也强制重启。
.PARAMETER NoToast
  失败时不弹 Toast（测试用）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\startup\Start-Toolbox.ps1
#>
[CmdletBinding()]
param(
	[string]$EnginePath,

	[ValidateRange(1, 10)]
	[int]$MaxAttempts = 3,

	[ValidateRange(1, 60)]
	[int]$RetryDelaySeconds = 5,

	[ValidateRange(1, 60)]
	[int]$StartupWaitSeconds = 10,

	[ValidateRange(20, 5000)]
	[int]$KeepLogLines = 300,

	[switch]$Force,

	[switch]$NoToast
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$mainScript = Join-Path $repoRoot 'ahk\main.ahk'
$logDirectory = Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox'
$logFile = Join-Path $logDirectory 'startup.log'

. (Join-Path $PSScriptRoot 'ToolboxProcess.ps1')

function Write-StartupLog
{
	param([Parameter(Mandatory = $true)][string]$Message)

	try
	{
		if (!(Test-Path -LiteralPath $logDirectory)) { $null = New-Item -ItemType Directory -Path $logDirectory -Force }
		$line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
		Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
	}
	catch { }
}

function Limit-StartupLog
{
	try
	{
		if (!(Test-Path -LiteralPath $logFile)) { return }
		$lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
		if ($lines.Count -le $KeepLogLines) { return }
		$lines[-$KeepLogLines..-1] | Set-Content -LiteralPath $logFile -Encoding UTF8
	}
	catch { }
}

function Get-ToolboxProcess
{
	return Get-ToolboxProcessSnapshot -MainScript $mainScript
}

function Get-ToolboxStartupErrorDialog
{
	param([int[]]$ProcessIds = @())

	# main.ahk 启动失败时会弹"脚本工具箱启动错误"MsgBox 并阻塞在对话框上，
	# 此时进程仍然存在，只看进程会误判成功。只看本次启动的 PID，
	# 避免把其他 AHK 脚本的错误框当成本工具箱的失败。
	return Get-ToolboxStartupErrorDialogSnapshot -ProcessIds $ProcessIds
}

function Resolve-ToolboxEngine
{
	# 1) 官方安装版（README 推荐路径）
	if ($env:LOCALAPPDATA)
	{
		foreach ($name in 'AutoHotkey64.exe', 'AutoHotkey32.exe')
		{
			$candidate = Join-Path $env:LOCALAPPDATA ('Programs\AutoHotkey\v2\' + $name)
			if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
		}
	}

	# 2) PATH 上的 AutoHotkey.exe（Scoop shim 指向 UX 启动器，需要再回到 v2 引擎）
	$command = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue
	if ($command -and $command.Source)
	{
		$shim = [IO.Path]::ChangeExtension($command.Source, '.shim')
		if (Test-Path -LiteralPath $shim)
		{
			try
			{
				$shimText = Get-Content -Raw -LiteralPath $shim
				if ($shimText -match '(?m)^path\s*=\s*"([^"]+)"')
				{
					$target = $Matches[1]
					if ([IO.Path]::GetFileName($target) -ieq 'AutoHotkeyUX.exe')
					{
						$installRoot = Split-Path (Split-Path $target -Parent) -Parent
						foreach ($name in 'AutoHotkey64.exe', 'AutoHotkey32.exe')
						{
							$candidate = Join-Path (Join-Path $installRoot 'v2') $name
							if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
						}
					}
					if (Test-Path -LiteralPath $target -PathType Leaf) { return $target }
				}
			}
			catch { }
		}
		if (Test-Path -LiteralPath $command.Source -PathType Leaf) { return $command.Source }
	}

	# 3) Scoop 安装目录（current 可能是 junction，也可能是迁移后的实目录）
	$scoopRoots = @()
	if ($env:SCOOP) { $scoopRoots += $env:SCOOP }
	if ($env:USERPROFILE) { $scoopRoots += (Join-Path $env:USERPROFILE 'scoop') }
	foreach ($root in $scoopRoots)
	{
		foreach ($relative in 'apps\autohotkey\current\v2\AutoHotkey64.exe', 'apps\autohotkey\current\AutoHotkey64.exe',
			'apps\autohotkey\current\v2\AutoHotkey32.exe', 'apps\autohotkey\current\AutoHotkey32.exe')
		{
			$candidate = Join-Path $root $relative
			if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
		}
	}

	# 4) Program Files 兜底
	$programFiles = $env:ProgramFiles
	if ($programFiles)
	{
		foreach ($name in 'AutoHotkey64.exe', 'AutoHotkey32.exe')
		{
			$candidate = Join-Path $programFiles ('AutoHotkey\v2\' + $name)
			if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
		}
	}

	return $null
}

function Show-StartupFailure
{
	param([Parameter(Mandatory = $true)][string]$Message)

	if ($NoToast) { return }
	$toast = Join-Path $repoRoot 'shared\notify\toast.ps1'
	if (Test-Path -LiteralPath $toast)
	{
		try { & $toast -Title '× 工具箱未能启动' -Message $Message }
		catch { }
	}
}

Limit-StartupLog
Write-StartupLog ("startup: 触发 (host PID {0})" -f $PID)

if (!(Test-Path -LiteralPath $mainScript -PathType Leaf))
{
	Write-StartupLog ("startup: 失败 - 找不到入口脚本 {0}" -f $mainScript)
	Show-StartupFailure ("找不到入口脚本：{0}" -f $mainScript)
	exit 2
}

$existingSnapshot = Get-ToolboxProcess
$guardAction = Get-StartupGuardAction -Status $existingSnapshot.Status -Force:$Force
if ($guardAction -eq 'query-failed')
{
	# 查询失败时不能当成"没在运行"：main.ahk 是 #SingleInstance Force，
	# 再启动一个会把正在运行的实例替换掉。宁可让看护任务下一轮重试。
	Write-StartupLog ("startup: 失败 - 无法查询工具箱进程状态，未启动以避免重复: {0}" -f $existingSnapshot.ErrorMessage)
	Show-StartupFailure '无法查询工具箱进程状态，已跳过本次启动以避免重复。详情见 %LOCALAPPDATA%\lat3ncy-toolbox\startup.log'
	exit 5
}
if ($guardAction -eq 'skip')
{
	Write-StartupLog ("startup: 已在运行 (PID {0})，跳过" -f ($existingSnapshot.ProcessIds -join ','))
	exit 0
}
if ($guardAction -eq 'force')
{
	$oldIds = $existingSnapshot.ProcessIds -join ','
	foreach ($process in $existingSnapshot.Processes) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
	Start-Sleep -Milliseconds 500
	Write-StartupLog ("startup: -Force 结束旧实例 {0}" -f $oldIds)
}

$engine = if ($EnginePath) { $EnginePath } else { Resolve-ToolboxEngine }
if (!$engine -or !(Test-Path -LiteralPath $engine -PathType Leaf))
{
	Write-StartupLog ("startup: 失败 - 未找到 AutoHotkey v2 引擎 (解析结果={0})" -f $engine)
	Show-StartupFailure '未找到 AutoHotkey v2 引擎：请检查官方安装或 Scoop 的 autohotkey\current 目录'
	exit 3
}
Write-StartupLog ("startup: 引擎 {0} (v{1})" -f $engine, (Get-Item -LiteralPath $engine).VersionInfo.ProductVersion)

$workingDirectory = Split-Path $mainScript -Parent
$attempt = 0
while ($attempt -lt $MaxAttempts)
{
	$attempt++
	$started = $null
	try
	{
		$started = Start-Process -FilePath $engine -ArgumentList (ConvertTo-ToolboxCommandLineArgument $mainScript) -WorkingDirectory $workingDirectory -PassThru
	}
	catch
	{
		Write-StartupLog ("startup: 第 {0} 次启动异常 - {1}" -f $attempt, $_.Exception.Message)
		if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $RetryDelaySeconds }
		continue
	}

	# 轮询等待：登录时 WMI 枚举可能滞后，AHK 也要解析 include/依赖，
	# 单次快照会误判"没起来"。错误框优先判定——它出现时进程仍存在，只看进程会误报成功。
	# 查询失败不等于不存在：持续记录，最终失败时给出查询诊断，不据此再启动。
	$foundSnapshot = New-ToolboxProcessSnapshot -Status 'not-running'
	$dialogSnapshot = New-ToolboxProcessSnapshot -Status 'not-running'
	$queryFailed = $false
	$waitUntil = (Get-Date).AddSeconds($StartupWaitSeconds)
	do
	{
		Start-Sleep -Milliseconds 500
		$dialogSnapshot = Get-ToolboxStartupErrorDialog -ProcessIds @($started.Id)
		if ($dialogSnapshot.Status -eq 'running') { break }
		$foundSnapshot = Get-ToolboxProcess
		if ($foundSnapshot.Status -eq 'running') { break }
		$queryFailed = ($foundSnapshot.Status -eq 'query-failed' -or $dialogSnapshot.Status -eq 'query-failed')
	} while ((Get-Date) -lt $waitUntil)

	if ($dialogSnapshot.Status -eq 'running')
	{
		Write-StartupLog ("startup: 第 {0} 次启动后 main.ahk 弹出启动错误框（等待人工确认），视为失败" -f $attempt)
	}
	elseif ($foundSnapshot.Status -eq 'running')
	{
		Write-StartupLog ("startup: 成功 - PID {0}（第 {1} 次尝试，等待 {2} 秒内出现）" -f ($foundSnapshot.ProcessIds -join ','), $attempt, $StartupWaitSeconds)
		exit 0
	}
	else
	{
		$queryNote = if ($queryFailed) { '；进程查询失败: ' + $foundSnapshot.ErrorMessage } else { '' }
		Write-StartupLog ("startup: 第 {0} 次启动后 {1} 秒内未检测到工具箱进程 (启动 PID {2}){3}" -f $attempt, $StartupWaitSeconds, $started.Id, $queryNote)
	}

	if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $RetryDelaySeconds }
}

Write-StartupLog ("startup: 失败 - {0} 次尝试后仍未正常运行；上方 main.ahk 的启动失败/退出记录会说明原因" -f $MaxAttempts)
Show-StartupFailure ("工具箱未能启动（{0} 次尝试）。日志：%LOCALAPPDATA%\lat3ncy-toolbox\startup.log" -f $MaxAttempts)
exit 4
