#Requires -Version 5.1
# 确保官方 OpenRGB 系统服务已在听 6742。已在监听时直接退出，不重启。
# 不再启动项目目录里的 OpenRGB.exe，也不使用 --startminimized（那会强制托盘）。
# 本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按系统 ANSI 误读中文。

param(
    [switch]$Install,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$serviceName = "OpenRGB"
$sdkPort = 6742
$installScript = Join-Path $root "install.ps1"

function Test-SdkListening {
    # 普通用户 Get-NetTCPConnection 常被拒绝；netstat 在中文系统也不输出 LISTENING。
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect("127.0.0.1", $sdkPort, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(400)
        if (-not $ok) {
            return $false
        }
        $client.EndConnect($iar)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        if ($client) {
            try { $client.Close() } catch {}
        }
    }
}

function Get-SdkPid {
    $tcp = Get-NetTCPConnection -LocalPort $sdkPort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($tcp) { return $tcp.OwningProcess }
    return $null
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Elevator {
    if (Get-Command gsudo -ErrorAction SilentlyContinue) { return "gsudo" }
    if (Get-Command sudo -ErrorAction SilentlyContinue) { return "sudo" }
    return $null
}

function Invoke-ElevatedService {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Start", "Stop")][string]$Action
    )
    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $inner = if ($Action -eq "Start") {
        "Start-Service -Name '$serviceName'"
    } else {
        "Stop-Service -Name '$serviceName' -Force"
    }
    if (Test-Admin) {
        if ($Action -eq "Start") {
            Start-Service -Name $serviceName
        } else {
            Stop-Service -Name $serviceName -Force
        }
        return
    }
    $elev = Get-Elevator
    if (-not $elev) {
        throw "需要管理员才能 $Action 服务 $serviceName，且未找到 sudo/gsudo"
    }
    Write-Host "[OpenRGB] elevating via $elev to $Action service..." -ForegroundColor Yellow
    if ($elev -eq "gsudo") {
        & gsudo --inline $powershell -NoProfile -ExecutionPolicy Bypass -Command $inner
    } else {
        & sudo --inline $powershell -NoProfile -ExecutionPolicy Bypass -Command $inner
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Action 服务 $serviceName 失败，exit=$LASTEXITCODE"
    }
}

if ($Install) {
    if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
        Write-Error "not found $installScript"
        exit 1
    }
    if (Test-Admin) {
        & $installScript
        exit $LASTEXITCODE
    }
    $elev = Get-Elevator
    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not $elev) {
        Write-Error "install.ps1 需要管理员，且未找到 sudo/gsudo"
        exit 1
    }
    Write-Host "[OpenRGB] install needs admin, elevating via $elev..." -ForegroundColor Yellow
    if ($elev -eq "gsudo") {
        & gsudo --inline $powershell -NoProfile -ExecutionPolicy Bypass -File $installScript
    } else {
        & sudo --inline $powershell -NoProfile -ExecutionPolicy Bypass -File $installScript
    }
    exit $LASTEXITCODE
}

if ($Stop) {
    $ErrorActionPreference = "Continue"
    try { Invoke-ElevatedService -Action Stop } catch {}
    Get-Process OpenRGB -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "[OpenRGB] service stopped" -ForegroundColor Yellow
    exit 0
}

if (Test-SdkListening) {
    $pidOnPort = Get-SdkPid
    Write-Host "[OpenRGB] SDK already on $sdkPort PID $pidOnPort (reuse, not restarting)" -ForegroundColor Cyan
    exit 0
}

$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Warning "系统服务 $serviceName 不存在。请先管理员运行: $installScript"
    exit 1
}

try {
    Invoke-ElevatedService -Action Start
} catch {
    Write-Warning $_.Exception.Message
    exit 1
}

$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    if (Test-SdkListening) {
        $pidOnPort = Get-SdkPid
        Write-Host "[OpenRGB] SDK ready $sdkPort PID $pidOnPort" -ForegroundColor Green
        exit 0
    }
    Start-Sleep -Milliseconds 400
}

Write-Warning "服务已启动但 $sdkPort 未监听。查看 C:\Program Files\OpenRGB\service_config\logs，不要手动开 OpenRGB 窗口。"
exit 1
