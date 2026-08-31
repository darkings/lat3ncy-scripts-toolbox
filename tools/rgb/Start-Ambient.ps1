#Requires -Version 5.1
# 无窗口启动 pythonw ambient.py。
# 不要再拉起 powershell.exe -Wait：CUI waiter 会被 Win11 默认终端显示，
# Write-Host 的 SDK/PID 那几行就是弹窗内容。
# -Wait 仅兼容旧计划任务，行为与默认相同（拉起 pythonw 后立刻返回）。
# 登录常驻请让任务直接执行 pythonw.exe（见 Install-Ambient.ps1）。
# 本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按系统 ANSI 误读中文。

param(
    [switch]$Wait
)

$ErrorActionPreference = "Stop"

# 控制台按 UTF-8 输出，避免 gsudo / powershell 5.1 把中文打成乱码
try {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch {
}

$root = $PSScriptRoot
$ambientPy = Join-Path $root "ambient.py"
$logDir = Join-Path $root "logs"
$outLog = Join-Path $logDir "ambient.out.log"
$errLog = Join-Path $logDir "ambient.err.log"

function Start-HiddenProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$ArgumentList = "",
        [string]$WorkingDirectory = "",
        [switch]$PassThru
    )
    # Start-Process -WindowStyle Hidden 仍会先分配控制台再藏起来，首帧会闪黑框。
    # RedirectStandardOutput/Error 在 5.1 还会再开一个可见终端。
    # UseShellExecute=false + CreateNoWindow 根本不建控制台。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $ArgumentList
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) {
        throw "failed to start $FilePath"
    }
    if ($PassThru) {
        return $proc
    }
}

function Write-AmbientHost {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "[ambient] $Message" -ForegroundColor $Color
}

function Get-AmbientPythonProcesses {
    # 只认命令行里带 ambient.py 的解释器，避免误杀 hi75.py / 其它 python
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match '(?i)[\\/]ambient\.py(\s|"|$)'
        }
}

function Get-AmbientPythonwExe {
    # 计划任务的 PATH 可能没有 Scoop shim，必须解析成绝对路径。
    # 用 pythonw：无控制台窗口；-u 让 print 立刻进日志。
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
        return $cmd.Source
    }
    return $null
}

if (-not (Test-Path -LiteralPath $ambientPy -PathType Leaf)) {
    Write-AmbientHost "missing $ambientPy" "Red"
    exit 1
}

$existing = @(Get-AmbientPythonProcesses)
if ($existing.Count -gt 0) {
    $pids = ($existing | ForEach-Object { $_.ProcessId }) -join ", "
    Write-AmbientHost "already running PID $pids (reuse, not restarting)" "Green"
    exit 0
}

if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$pythonw = Get-AmbientPythonwExe
if (-not $pythonw) {
    Write-AmbientHost "pythonw.exe not found. Install Python or add it to PATH." "Red"
    exit 1
}

# pythonw 本身无控制台。不要 RedirectStandardOutput/Error：
# PowerShell 5.1 一重定向就会再开一个终端窗口。
# 日志改由 ambient.py 在 stdout 为 None 时自己写 logs/ambient.*.log。
# SDK 探测也不再 Write-Host：那几行就是弹窗正文；连不上时 ambient.py 会自己重连。
$env:PYTHONUNBUFFERED = "1"
try {
    $proc = Start-HiddenProcess -FilePath $pythonw `
        -ArgumentList "-u `"$ambientPy`"" `
        -WorkingDirectory $root `
        -PassThru
} catch {
    Write-AmbientHost "start failed: $($_.Exception.Message)" "Red"
    exit 1
}

if (-not $proc) {
    Write-AmbientHost "start returned no process" "Red"
    exit 1
}

# 已有终端里手动跑才回显 PID。
# -Wait 是旧计划任务参数：绝不能 Write-Host / Wait-Process，
# 否则 Win11 默认终端会弹出这几行并一直挂着 powershell.exe。
if (-not $Wait -and $Host.Name -eq "ConsoleHost") {
    Write-AmbientHost "started PID $($proc.Id) pythonw=$pythonw" "Green"
    Write-AmbientHost "stdout $outLog"
    Write-AmbientHost "stderr $errLog"
}

exit 0
