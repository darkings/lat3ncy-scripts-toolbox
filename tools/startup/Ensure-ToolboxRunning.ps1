# Ensure-ToolboxRunning.ps1
# Watchdog entry for TWO targets:
#   1) ahk/main.ahk                       - start via Start-Toolbox.ps1
#   2) tools/power-policy/PowerPolicy.ps1 - start the PowerPolicy scheduled task
# Called by the Lat3ncyToolbox-Watchdog scheduled task at logon and every 5 minutes.
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
$powerScript = Join-Path $repoRoot 'tools\power-policy\PowerPolicy.ps1'
$powerTask = 'PowerPolicy'
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

# ---------------------------------------------------------------- target 1: AHK

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

# ---------------------------------------------------- target 2: power policy

function Get-PowerPolicyProcess {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -like 'pwsh*' -and $_.CommandLine -and
        $_.CommandLine -match 'PowerPolicy\.ps1' -and $_.CommandLine -match '\-Run'
      })
}

function Test-PowerPolicyAlive {
  return @(Get-PowerPolicyProcess).Count -gt 0
}

# ------------------------------------------------------------------- main

$failures = @()

# --- target 1
if (-not (Test-Path -LiteralPath $mainScript)) {
  Write-StartupLog "watchdog: main.ahk missing, skipped ($mainScript)"
  $failures += 'ahk-missing'
} elseif (Test-ToolboxProcessAlive) {
  # Normal case: stay quiet so the log does not grow every 5 minutes.
} else {
  Write-StartupLog "watchdog: main.ahk not running, starting toolbox"
  try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $startScript *> $null
  } catch {
    Write-StartupLog ("watchdog: Start-Toolbox failed: " + $_.Exception.Message)
    $failures += 'ahk-start-failed'
  }

  $started = $false
  for ($i = 0; $i -lt 10; $i++) {
    if (Test-ToolboxProcessAlive) {
      $after = @(Get-ToolboxAutoHotkeyProcess)
      $ids = if ($after.Count -gt 0) { ($after.ProcessId) -join ', ' } else { 'confirmed-by-process-name' }
      Write-StartupLog ("watchdog: ahk started - PID " + $ids)
      $started = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $started) {
    Write-StartupLog "watchdog: still no main.ahk after start (see the startup: line above)"
    $failures += 'ahk-not-up'
  }
}

# --- target 2
if (-not (Test-Path -LiteralPath $powerScript)) {
  Write-StartupLog "watchdog: PowerPolicy.ps1 missing, skipped ($powerScript)"
} elseif (Test-PowerPolicyAlive) {
  # Normal case: quiet.
} else {
  $task = Get-ScheduledTask -TaskName $powerTask -ErrorAction SilentlyContinue
  if (-not $task) {
    Write-StartupLog "watchdog: task '$powerTask' not registered, skipped (run tools\power-policy\Install-PowerPolicy.ps1)"
  } else {
    Write-StartupLog "watchdog: power policy resident not running, starting task '$powerTask'"
    try {
      Start-ScheduledTask -TaskName $powerTask -ErrorAction Stop
    } catch {
      Write-StartupLog ("watchdog: Start-ScheduledTask '$powerTask' failed: " + $_.Exception.Message)
      $failures += 'power-start-failed'
    }

    $powerUp = $false
    for ($i = 0; $i -lt 15; $i++) {
      if (Test-PowerPolicyAlive) {
        $pids = @(Get-PowerPolicyProcess) | ForEach-Object { $_.ProcessId }
        Write-StartupLog ("watchdog: power policy started - PID " + ($pids -join ', '))
        $powerUp = $true
        break
      }
      Start-Sleep -Seconds 1
    }
    if (-not $powerUp) {
      Write-StartupLog "watchdog: power policy still not running after start"
      $failures += 'power-not-up'
    }
  }
}

if ($failures.Count -gt 0) {
  Write-StartupLog ("watchdog: exit with failures - " + ($failures -join ', '))
  exit 1
}
exit 0
