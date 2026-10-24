# Ensure-ToolboxRunning.ps1
# Watchdog entry: if ahk/main.ahk is not running, start it via Start-Toolbox.ps1.
# Called by the Lat3ncyToolbox-Watchdog scheduled task every 5 minutes.
# Only starts; never kills an already running instance.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less files as ANSI,
# and non-ASCII here would break parsing silently (bit us twice).

param(
  [int]$KeepLogLines = 300
)

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$mainScript = Join-Path $repoRoot 'ahk\main.ahk'
$startScript = Join-Path $repoRoot 'tools\startup\Start-Toolbox.ps1'
$logDirectory = Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox'
$logFile = Join-Path $logDirectory 'startup.log'

function Write-StartupLog {
  param([string]$Message)
  try {
    if (!(Test-Path -LiteralPath $logDirectory)) {
      $null = New-Item -ItemType Directory -Path $logDirectory -Force
    }
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    $lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
    if ($lines.Count -gt $KeepLogLines) {
      $lines[-$KeepLogLines..-1] | Set-Content -LiteralPath $logFile -Encoding UTF8
    }
  } catch {
  }
}

function Get-ToolboxAutoHotkeyProcess {
  $escaped = [Regex]::Escape($mainScript)
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -like 'AutoHotkey*.exe' -and $_.CommandLine -and
        ($_.CommandLine -match $escaped -or $_.CommandLine -match 'lat3ncy-scripts-toolbox[\\/]ahk[\\/]main\.ahk')
      })
}

# CIM can lag right after a process starts; fall back to process name.
function Test-ToolboxProcessAlive {
  if (@(Get-ToolboxAutoHotkeyProcess).Count -gt 0) { return $true }
  return @(Get-Process -Name 'AutoHotkey64', 'AutoHotkey32' -ErrorAction SilentlyContinue).Count -gt 0
}

if (-not (Test-Path -LiteralPath $mainScript)) {
  Write-StartupLog "watchdog: main.ahk missing, skipped ($mainScript)"
  exit 1
}

if (Test-ToolboxProcessAlive) {
  # Normal case: stay quiet so the log does not grow every 5 minutes.
  exit 0
}

Write-StartupLog "watchdog: main.ahk not running, starting toolbox"
try {
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $startScript *> $null
} catch {
  Write-StartupLog ("watchdog: Start-Toolbox failed: " + $_.Exception.Message)
  exit 1
}

for ($i = 0; $i -lt 10; $i++) {
  if (Test-ToolboxProcessAlive) {
    $after = @(Get-ToolboxAutoHotkeyProcess)
    $ids = if ($after.Count -gt 0) { ($after.ProcessId) -join ', ' } else { 'confirmed-by-process-name' }
    Write-StartupLog ("watchdog: started - PID " + $ids)
    exit 0
  }
  Start-Sleep -Seconds 1
}

Write-StartupLog "watchdog: still no main.ahk after start (see the startup: line above)"
exit 1
