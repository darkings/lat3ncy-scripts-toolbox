#Requires -Version 5.1
# 注册登录常驻任务 RGB-Ambient（当前用户、普通权限、无窗口）。
# 任务直接跑 pythonw.exe ambient.py，不再包一层 powershell.exe。
# powershell -Wait 是 CUI 进程，Win11 默认终端会弹出 Write-Host 那几行。
# 创建任务在本机需要提权；任务本身不 Highest，ambient 只连 6742 + 用户态 HID。
# -Unregister 删除任务并停止进程。
# 本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按系统 ANSI 误读中文。

param(
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"

try {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch {
}

$root = $PSScriptRoot
$taskName = "RGB-Ambient"
$ambientPy = Join-Path $root "ambient.py"
$startScript = Join-Path $root "Start-Ambient.ps1"
$stopScript = Join-Path $root "Stop-Ambient.ps1"
$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Write-AmbientHost {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "[ambient] $Message" -ForegroundColor $Color
}

function Test-AmbientAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AmbientElevator {
    if (Get-Command gsudo -ErrorAction SilentlyContinue) { return "gsudo" }
    if (Get-Command sudo -ErrorAction SilentlyContinue) { return "sudo" }
    return $null
}

function Get-AmbientPythonwExe {
    # 计划任务不继承交互 PATH，必须写入 pythonw 绝对路径。
    $wcmd = Get-Command pythonw.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($wcmd -and $wcmd.Source -and (Test-Path -LiteralPath $wcmd.Source)) {
        return $wcmd.Source
    }
    $cmd = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd -and $cmd.Source) {
        $sibling = Join-Path (Split-Path -LiteralPath $cmd.Source) "pythonw.exe"
        if (Test-Path -LiteralPath $sibling) {
            return $sibling
        }
    }
    return $null
}

function Invoke-AmbientElevatedSelf {
    $self = $PSCommandPath
    if (-not $self) {
        $self = $MyInvocation.MyCommand.Path
    }
    $elev = Get-AmbientElevator
    if (-not $elev) {
        Write-AmbientHost "need admin to register scheduled task; no sudo/gsudo found" "Red"
        exit 1
    }
    Write-AmbientHost "need admin to register scheduled task, elevating via $elev..." "Yellow"
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $self
    )
    if ($Unregister) {
        $argList += "-Unregister"
    }
    if ($elev -eq "gsudo") {
        & gsudo --inline $powershell @argList
        exit $LASTEXITCODE
    }
    & sudo --inline $powershell @argList
    exit $LASTEXITCODE
}

if (-not (Test-AmbientAdmin)) {
    Invoke-AmbientElevatedSelf
}

if ($Unregister) {
    $ErrorActionPreference = "Continue"
    Write-AmbientHost "removing task $taskName"
    try {
        schtasks /end /tn $taskName 2>$null | Out-Null
    } catch {
    }
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-AmbientHost "task removed" "Green"
    } else {
        Write-AmbientHost "task not found" "Yellow"
    }
    if (Test-Path -LiteralPath $stopScript -PathType Leaf) {
        & $stopScript
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $ambientPy -PathType Leaf)) {
    Write-AmbientHost "missing $ambientPy" "Red"
    exit 1
}
if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    Write-AmbientHost "missing $startScript" "Red"
    exit 1
}

$pythonw = Get-AmbientPythonwExe
if (-not $pythonw) {
    Write-AmbientHost "pythonw.exe not found. Install Python or add it to PATH." "Red"
    exit 1
}

# 登录后延迟 15s：等 DWM。OpenRGB SDK 由系统服务提供，不依赖登录任务。
# 直接执行 pythonw：GUI 子系统，不会被 Windows Terminal 接走。
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = "PT15S"

$arguments = "-u `"$ambientPy`""
$action = New-ScheduledTaskAction -Execute $pythonw -Argument $arguments -WorkingDirectory $root
# 任务以当前用户交互会话跑，不要 Highest
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# ExecutionTimeLimit=0 表示不限时；默认 72h 会把常驻进程杀掉
$settings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$description = "RGB Ambient - desktop color to fans and keyboard (pythonw, no console)"

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-AmbientHost "update task $taskName -> $pythonw"
    Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
} else {
    Write-AmbientHost "create task $taskName -> $pythonw"
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $description | Out-Null
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-AmbientHost "task create failed" "Red"
    exit 1
}
Write-AmbientHost "task ready ($($task.State))" "Green"

Write-AmbientHost "starting now"
try {
    schtasks /run /tn $taskName | Out-Null
} catch {
    Write-AmbientHost "schtasks /run failed: $($_.Exception.Message)" "Yellow"
}

Start-Sleep -Seconds 2
$info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
if ($info) {
    Write-AmbientHost "last result=$($info.LastTaskResult) last run=$($info.LastRunTime)"
}

$running = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match '(?i)[\\/]ambient\.py(\s|"|$)' })
if ($running.Count -gt 0) {
    $pids = ($running | ForEach-Object { $_.ProcessId }) -join ", "
    Write-AmbientHost "python running PID $pids" "Green"
} else {
    Write-AmbientHost "python not seen yet; check logs\ambient.err.log" "Yellow"
}

Write-Host ""
Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
Write-Host " RGB Ambient installed (pythonw, at logon +15s)" -ForegroundColor Cyan
Write-Host " Task : $taskName -> $pythonw" -ForegroundColor Cyan
Write-Host " Start: powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\Start-Ambient.ps1" -ForegroundColor Cyan
Write-Host " Stop : powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\Stop-Ambient.ps1" -ForegroundColor Cyan
Write-Host " Log  : Get-Content .\tools\rgb\logs\ambient.out.log -Tail 20 -Wait" -ForegroundColor Cyan
Write-Host " Remove: powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\rgb\Install-Ambient.ps1 -Unregister" -ForegroundColor Cyan
Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
