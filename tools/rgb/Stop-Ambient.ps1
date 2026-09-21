#Requires -Version 5.1
# 结束 RGB Ambient 及其 hi75.exe 子进程。不碰 OpenRGB。
# 本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按系统 ANSI 误读中文。

$ErrorActionPreference = "Continue"

$root = $PSScriptRoot
$taskName = "RGB-Ambient"
# --onedir 产物；顺带兼容旧 --onefile 的 dist\hi75.exe
$hi75Exe = Join-Path $root "dist\hi75\hi75.exe"
$hi75Legacy = Join-Path $root "dist\hi75.exe"
$hi75DistRoot = (Join-Path $root "dist").ToLowerInvariant()
$stateDir = Join-Path $env:LOCALAPPDATA "lat3ncy-toolbox"
$quitFlag = Join-Path $stateDir "rgb-quit.flag"

function Write-AmbientHost {
    param([string]$Message, [string]$Color = "Yellow")
    Write-Host "[ambient] $Message" -ForegroundColor $Color
}

function Stop-MatchingProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][scriptblock]$Match
    )
    $procs = @(Get-CimInstance Win32_Process -Filter $Filter -ErrorAction SilentlyContinue | Where-Object $Match)
    foreach ($p in $procs) {
        Write-AmbientHost "killing pid $($p.ProcessId) $($p.Name)"
        try {
            Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
    return $procs.Count
}

function Get-AmbientPythonProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -match '(?i)[\\/]ambient\.py(\s|"|$)'
        })
}

# 先写退出旗标，让 ambient 的 finally 推 Direct 全黑，再杀进程。
# 直接 Stop-Process 的话键盘会掉回板载彩虹、风扇保持最后一色。
try {
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir | Out-Null
    }
    Set-Content -LiteralPath $quitFlag -Value "1" -Encoding ascii
} catch {
}

$graceDeadline = (Get-Date).AddSeconds(2.5)
while ((Get-Date) -lt $graceDeadline) {
    $still = Get-AmbientPythonProcesses
    if ($still.Count -eq 0) {
        break
    }
    Start-Sleep -Milliseconds 100
}

# 优雅退出失败再强杀。-Wait 的计划任务会随 python 退出而结束
$pyCount = Stop-MatchingProcesses -Filter "Name='python.exe' OR Name='pythonw.exe'" -Match {
    $_.CommandLine -and $_.CommandLine -match '(?i)[\\/]ambient\.py(\s|"|$)'
}

# 旗标没被消费也要删，避免下次启动立刻退出。必须在强杀之后再清。
try {
    if (Test-Path -LiteralPath $quitFlag) {
        Remove-Item -LiteralPath $quitFlag -Force -ErrorAction SilentlyContinue
    }
} catch {
}

# 任务 /End 可能没把 python 的 SIGTERM 送到，hi75.exe 会成孤儿
$hi75Count = 0
$hi75Procs = @(Get-CimInstance Win32_Process -Filter "Name='hi75.exe'" -ErrorAction SilentlyContinue)
foreach ($p in $hi75Procs) {
    $exePath = [string]$p.ExecutablePath
    $cmd = [string]$p.CommandLine
    $exeLower = $exePath.ToLowerInvariant()
    $cmdLower = $cmd.ToLowerInvariant()
    $mine = ($exePath -and (($exePath -ieq $hi75Exe) -or ($exePath -ieq $hi75Legacy))) -or
        ($exeLower -and $exeLower.StartsWith($hi75DistRoot) -and $exeLower.EndsWith('\hi75.exe')) -or
        ($cmdLower -and $cmdLower.Contains('\tools\rgb\dist\') -and $cmdLower.Contains('hi75.exe'))
    if (-not $mine) {
        continue
    }
    Write-AmbientHost "killing hi75 pid $($p.ProcessId)"
    try {
        Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
    } catch {
    }
    $hi75Count++
}

# 再停仍挂起的 Start-Ambient.ps1 -Wait
$psCount = Stop-MatchingProcesses -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -Match {
    $_.CommandLine -and
    $_.CommandLine -like '*Start-Ambient.ps1*' -and
    $_.ProcessId -ne $PID
}

try {
    schtasks /end /tn $taskName 2>$null | Out-Null
} catch {
}

Write-AmbientHost "stopped python=$pyCount hi75=$hi75Count waiter=$psCount" "Green"
